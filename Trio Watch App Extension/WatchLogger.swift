import Foundation
import os
import WatchConnectivity

/// WatchConnectivity's lists of queued transfers are read with a call that waits on its framework and can hang for
/// minutes when WatchConnectivity stalls: on 9 November from about 13:16 the main thread (`reportBatteryIfChanged`)
/// and both of the watch's cooperative threads (the two log senders) waited there at once, nothing else ran, no
/// sensor reading for 20 minutes, until watchOS killed Trio at 13:36:52 for a screen update it couldn't answer
/// (first tester's crash report, build 732). Those reads now run on this queue alone: a stall holds it, not the main
/// thread and not Swift's thread pool, whose tasks wait for it without holding a thread.
enum WCTransfers {
    static let queue = DispatchQueue(label: "org.nightscout.trio.watch.wc-transfers", qos: .utility)

    /// Work with the transfer lists, off the main thread and the thread pool.
    static func run(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// The same, for a caller that needs the answer: it waits without holding a thread.
    static func read<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

final class WatchLogger: Sendable {
    static let shared = WatchLogger()

    fileprivate struct PendingDrafts {
        var drafts: [WatchLogDraft] = []
        var flushScheduled = false
    }

    private static let flushDelay: Duration = .seconds(5)
    private static let flushCount = 50
    private static let bufferLimit = 2000
    private static let shipInterval: Duration = .seconds(5 * 60)

    private let pending = OSAllocatedUnfairLock(initialState: PendingDrafts())
    private let shipper = WatchLogShipper()
    private let throttle = OSAllocatedUnfairLock(initialState: [String: (state: String, date: Date)]())
    private let osLoggers: [WatchLogEntry.Category: os.Logger] = {
        let subsystem = Bundle.main.bundleIdentifier ?? "Trio Watch"
        return Dictionary(uniqueKeysWithValues: WatchLogEntry.Category.allCases.map {
            ($0, os.Logger(subsystem: subsystem, category: $0.name))
        })
    }()

    private init() {
        Task { [shipper, pending] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.shipInterval)
                await shipper.drain(pending)
                await shipper.ship(onRequest: false)
            }
        }
    }

    func debug(_ category: WatchLogEntry.Category, _ message: String) {
        log(.debug, category, message)
    }

    func info(_ category: WatchLogEntry.Category, _ message: String) {
        log(.info, category, message)
    }

    func warning(_ category: WatchLogEntry.Category, _ message: String, error: Error? = nil) {
        log(.warning, category, Self.message(message, error: error))
    }

    func error(_ category: WatchLogEntry.Category, _ message: String, error: Error? = nil) {
        log(.error, category, Self.message(message, error: error))
    }

    // At most one line per key and interval while the state stays the same
    func shouldLog(_ key: String, state: String = "", every interval: TimeInterval = 30) -> Bool {
        let now = Date()
        return throttle.withLock { last in
            if let previous = last[key], previous.state == state, now.timeIntervalSince(previous.date) < interval {
                return false
            }
            last[key] = (state, now)
            return true
        }
    }

    func didEnterBackground() {
        Task { [shipper, pending] in
            await shipper.drain(pending)
            await shipper.ship(onRequest: false)
        }
    }

    // Requests and acks from the phone; returns false for unrelated messages
    func handlePhoneMessage(_ message: [String: Any]) -> Bool {
        if let ack = message[WatchLogTransfer.ack] as? NSNumber {
            let installID = message[WatchLogTransfer.installID] as? String
            Task { [shipper] in await shipper.acknowledge(ack.uint64Value, installID: installID) }
            return true
        }
        if message[WatchLogTransfer.request] as? Bool == true {
            Task { [shipper, pending] in
                await shipper.drain(pending)
                await shipper.ship(onRequest: true)
            }
            return true
        }
        return false
    }

    func transferFinished(_ transfer: WCSessionFileTransfer, error: Error?) {
        guard let metadata = transfer.file.metadata, metadata[WatchLogTransfer.marker] != nil else { return }
        let url = transfer.file.fileURL
        let firstSeq = (metadata[WatchLogTransfer.firstSeq] as? NSNumber)?.uint64Value ?? 1
        if let error {
            warning(.connectivity, "Log transfer to the phone failed, will retry", error: error)
        }
        Task { [shipper] in await shipper.finished(url, firstSeq: firstSeq, failed: error != nil) }
    }

    private func log(_ level: WatchLogEntry.Level, _ category: WatchLogEntry.Category, _ message: String) {
        osLoggers[category]?.log(level: level.osLogType, "\(message, privacy: .public)")
        let draft = WatchLogDraft(date: Date(), level: level, category: category, message: message)
        let (flushNow, scheduleDelayed) = pending.withLock { state -> (Bool, Bool) in
            state.drafts.append(draft)
            if state.drafts.count > Self.bufferLimit {
                state.drafts.removeFirst(state.drafts.count - Self.bufferLimit)
            }
            let scheduleDelayed = !state.flushScheduled
            state.flushScheduled = true
            return (state.drafts.count >= Self.flushCount, scheduleDelayed)
        }
        if flushNow {
            Task { [shipper, pending] in await shipper.drain(pending) }
        } else if scheduleDelayed {
            Task { [shipper, pending] in
                try? await Task.sleep(for: Self.flushDelay)
                await shipper.drain(pending)
            }
        }
    }

    private static func message(_ message: String, error: Error?) -> String {
        guard let error else { return message }
        let nsError = error as NSError
        return "\(message) (\(nsError.domain) \(nsError.code): \(nsError.localizedDescription))"
    }
}

private actor WatchLogShipper {
    private static let staleTransfer: TimeInterval = 30 * 60
    private static let osLog = os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trio Watch", category: "WatchLog")

    private var ring: WatchLogRing?
    // Highest seq handed to a file transfer; falls back to the ack on failure or relaunch
    private var sentSeq: UInt64 = 0

    private let outbox = WatchLogRing.defaultDirectory.deletingLastPathComponent()
        .appendingPathComponent("WatchLogOutbox", isDirectory: true)

    private func openRing() async -> WatchLogRing {
        if let ring { return ring }
        let ring = WatchLogRing()
        ring.prune()
        self.ring = ring
        sentSeq = ring.ackedSeq
        await clearOutbox()
        return ring
    }

    func drain(_ pending: OSAllocatedUnfairLock<WatchLogger.PendingDrafts>) async {
        let drafts = pending.withLock { state -> [WatchLogDraft] in
            defer {
                state.drafts.removeAll(keepingCapacity: true)
                state.flushScheduled = false
            }
            return state.drafts
        }
        guard !drafts.isEmpty else { return }
        let ring = await openRing()
        ring.append(drafts)
        ring.prune()
    }

    func ship(onRequest: Bool) async {
        let ring = await openRing()
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else { return }

        // read and cancelled on `WCTransfers.queue`: the list's read can hang
        let cutoff = Date().timeIntervalSince1970 - Self.staleTransfer
        let (outstandingCount, staleCount) = await WCTransfers.read { () -> (Int, Int) in
            let outstanding = WCSession.default.outstandingFileTransfers
                .filter { $0.file.metadata?[WatchLogTransfer.marker] != nil }
            let stale = outstanding.filter { ($0.file.metadata?[WatchLogTransfer.created] as? TimeInterval ?? 0) < cutoff }
            stale.forEach { $0.cancel() }
            return (outstanding.count, stale.count)
        }
        if staleCount > 0 {
            sentSeq = ring.ackedSeq
        } else if outstandingCount > 0, !onRequest {
            return
        }

        // A request resends everything unacknowledged so a lost earlier batch can't leave a gap
        let from = onRequest ? ring.ackedSeq : max(ring.ackedSeq, sentSeq)
        guard ring.lastSeq > from else { return }
        let entries = ring.entries(after: from)
        guard let first = entries.first, let last = entries.last else { return }

        let url = outbox.appendingPathComponent("\(first.seq)-\(last.seq).jsonl")
        do {
            try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
            try WatchLogEntry.jsonLines(entries).write(to: url, options: .atomic)
        } catch {
            Self.osLog.error("Writing watch log batch failed: \(String(describing: error), privacy: .public)")
            return
        }
        let metadata: [String: Any] = [
            WatchLogTransfer.marker: WatchLogTransfer.version,
            WatchLogTransfer.firstSeq: NSNumber(value: first.seq),
            WatchLogTransfer.lastSeq: NSNumber(value: last.seq),
            WatchLogTransfer.watchBuild: Self.build,
            WatchLogTransfer.installID: ring.installID,
            WatchLogTransfer.created: Date().timeIntervalSince1970
        ]
        session.transferFile(url, metadata: metadata)
        sentSeq = last.seq
        Self.osLog.debug("Queued watch log entries \(first.seq)-\(last.seq) for transfer")
    }

    func finished(_ url: URL, firstSeq: UInt64, failed: Bool) {
        try? FileManager.default.removeItem(at: url)
        if failed {
            sentSeq = min(sentSeq, firstSeq - 1)
        }
    }

    func acknowledge(_ seq: UInt64, installID: String?) async {
        let ring = await openRing()
        guard installID == ring.installID else { return }
        ring.acknowledge(seq)
        sentSeq = max(sentSeq, ring.ackedSeq)
    }

    // Batches left over from an earlier launch are rebuilt from the ring
    private func clearOutbox() async {
        let inFlight = await WCTransfers.read {
            Set(WCSession.default.outstandingFileTransfers.map(\.file.fileURL.lastPathComponent))
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        for file in files where !inFlight.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static let build: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()
}

private extension WatchLogEntry.Level {
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }
}

// MARK: - Untethered mode's lines

/// Untethered mode and the watch's own G7 reader write plain lines (`log`). They go to the phone as before the
/// structured log, as text (`UntetheredLineLog`), which the phone files under Watch/Legacy: on 27 October the
/// structured log's file transfers brought one line in a hundred of theirs, and none of the lines that would have
/// said why the watch didn't start by itself.
extension WatchLogger {
    func log(
        _ message: String,
        force: Bool = false,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) async {
        await UntetheredLineLog.shared.log(message, force: force, function: function, file: file, line: line)
    }

    /// Sends what was kept back while the phone was away; `queued` hands it to WatchConnectivity's queue even with the
    /// phone in reach. The structured log goes with it.
    func flushPersistedLogs(queued: Bool = false) async {
        await UntetheredLineLog.shared.flushPersistedLogs(queued: queued)
        didEnterBackground()
    }
}

/// The watch log as it was sent before the structured log, now kept until the phone confirms it has it.
///
/// Every line goes to a file at once (`outbox.txt`). Sending seals that file into parts of at most 48 KB
/// (`outbox-pending/`), each with an id; a sent part waits in `outbox-sent/` until the phone answers with its id
/// (`watchLogsAck`), and only then is it deleted. On 27 October the lines from 19:22 to 20:16 were lost: they had been
/// handed to WatchConnectivity's queue and the file deleted at once, and the watch app update at 20:16 dropped the
/// queue. A part the phone hasn't confirmed and that is no longer in the queue is sent again; the phone skips ids it
/// already has.
actor UntetheredLineLog {
    static let shared = UntetheredLineLog()

    static let payloadKey = "watchLogs"
    static let idKey = "watchLogsID"
    static let ackKey = "watchLogsAck"

    private let flushInterval: TimeInterval = 3 * 60
    private let flushSizeThreshold = 100
    /// a part sent that the phone hasn't confirmed and that WatchConnectivity no longer holds goes again after this
    private let resendAfter: TimeInterval = 10 * 60
    /// parts older than this are dropped, confirmed or not, as are the oldest beyond `maxParts`
    private let keepFor: TimeInterval = 2 * 24 * 60 * 60
    private let maxParts = 150
    private let partBytes = 48000

    private var lastFlush = Date()
    private var outboxLines: Int
    private var outboxBytes: Int
    private var counter = 0

    private let session = WCSession.default
    private var timerTask: Task<Void, Never>?

    private let directory: URL
    private let outbox: URL
    private let pendingDir: URL
    private let sentDir: URL

    private init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("logs", isDirectory: true)
        let outbox = directory.appendingPathComponent("outbox.txt")
        let pendingDir = directory.appendingPathComponent("outbox-pending", isDirectory: true)
        let sentDir = directory.appendingPathComponent("outbox-sent", isDirectory: true)
        for dir in [directory, pendingDir, sentDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var lines = 0
        var bytes = 0
        if let data = try? Data(contentsOf: outbox) {
            bytes = data.count
            lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        self.directory = directory
        self.outbox = outbox
        self.pendingDir = pendingDir
        self.sentDir = sentDir
        outboxLines = lines
        outboxBytes = bytes
        Task {
            await startFlushTimer()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    private func startFlushTimer() async {
        timerTask = Task {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                await flushIfNeeded(force: false)
            }
        }
    }

    func log(
        _ message: String,
        force: Bool = false,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) async {
        let shortFile = (file as NSString).lastPathComponent
        let timestamp = Self.dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(shortFile):\(line)] \(function) → \(message)"
        print(entry)

        append(entry + "\n")
        // hours with the phone away: sealed as they fill, so no part grows past what one transfer takes
        if outboxBytes >= partBytes { sealOutbox() }
        await flushIfNeeded(force: force)
    }

    /// Sends when the phone is in reach and 3 minutes or 100 lines have gathered; with the phone away the lines wait
    /// in the file for `flushPersistedLogs`.
    func flushIfNeeded(force: Bool = false) async {
        let due = force || Date().timeIntervalSince(lastFlush) >= flushInterval || outboxLines >= flushSizeThreshold
        guard due, session.activationState == .activated, session.isReachable else { return }
        await send(queued: false)
    }

    /// Sends everything not yet confirmed; `queued` hands it to WatchConnectivity's queue even with the phone in
    /// reach (a background moment, where an interactive message may not get its answer).
    func flushPersistedLogs(queued: Bool = false) async {
        await send(queued: queued)
    }

    /// WatchConnectivity reported a failed transfer: what isn't confirmed is sent again once the phone is in reach.
    func transferFailed() async {
        guard session.isReachable else { return }
        await send(queued: false)
    }

    /// The phone has these parts.
    func acknowledge(_ ids: [String]) {
        for id in ids where Self.isValidID(id) {
            try? FileManager.default.removeItem(at: sentDir.appendingPathComponent(id + ".txt"))
            try? FileManager.default.removeItem(at: pendingDir.appendingPathComponent(id + ".txt"))
        }
    }

    // MARK: - Files

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: outbox) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: outbox)
        }
        outboxBytes += data.count
        outboxLines += 1
    }

    private func nextID() -> String {
        counter += 1
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        return String(format: "%013lld-%04d-%@", millis, counter % 10000, String(UUID().uuidString.prefix(6)))
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 64 && !id.contains("/") && !id.contains("..")
    }

    /// The file's lines become pending parts; the old files of builds before this one (`watch_log.txt`,
    /// `watch_log_prev.txt`) go first.
    private func sealOutbox() {
        for legacy in ["watch_log_prev.txt", "watch_log.txt"] {
            seal(directory.appendingPathComponent(legacy))
        }
        seal(outbox)
        outboxLines = 0
        outboxBytes = 0
    }

    private func seal(_ file: URL) {
        guard let data = try? Data(contentsOf: file) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for part in Self.parts(of: text, maxBytes: partBytes) {
            try? part.data(using: .utf8)?.write(to: pendingDir.appendingPathComponent(nextID() + ".txt"))
        }
        try? FileManager.default.removeItem(at: file)
    }

    private func files(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Drops parts past `keepFor`, and the oldest beyond `maxParts`, so a watch whose phone stays away can't fill up.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-keepFor)
        var all = files(in: pendingDir) + files(in: sentDir)
        for url in all where Self.modified(url) < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
        all = (files(in: pendingDir) + files(in: sentDir)).sorted { $0.lastPathComponent < $1.lastPathComponent }
        if all.count > maxParts {
            all.prefix(all.count - maxParts).forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    /// Sent parts the phone hasn't confirmed, that WatchConnectivity no longer holds, and that went out over
    /// `resendAfter` ago (a dropped queue, a failed transfer, a lost answer) become pending again.
    private func recoverUnconfirmed() async {
        let key = Self.idKey
        let queued = await WCTransfers.read {
            Set(WCSession.default.outstandingUserInfoTransfers.compactMap { $0.userInfo[key] as? String })
        }
        let cutoff = Date().addingTimeInterval(-resendAfter)
        for url in files(in: sentDir) {
            let id = url.deletingPathExtension().lastPathComponent
            guard !queued.contains(id), Self.modified(url) < cutoff else { continue }
            moveBack(id)
        }
    }

    private func moveBack(_ id: String) {
        let from = sentDir.appendingPathComponent(id + ".txt")
        let to = pendingDir.appendingPathComponent(id + ".txt")
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    // MARK: - Sending

    private func send(queued: Bool) async {
        if session.activationState != .activated {
            session.activate()
            return
        }
        sealOutbox()
        prune()
        if session.isReachable { await recoverUnconfirmed() }
        lastFlush = Date()

        for url in files(in: pendingDir) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            let payload: [String: Any] = [Self.payloadKey: String(decoding: data, as: UTF8.self), Self.idKey: id]

            // sent first, then handed over: an answer that comes back at once finds the file where it looks
            let sent = sentDir.appendingPathComponent(id + ".txt")
            try? FileManager.default.removeItem(at: sent)
            guard (try? FileManager.default.moveItem(at: url, to: sent)) != nil else { continue }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: sent.path)

            if session.isReachable, !queued {
                session.sendMessage(payload, replyHandler: { reply in
                    // a phone on a build before this one answers with nothing, after it has taken the lines
                    let ids = reply[Self.ackKey] as? [String] ?? [id]
                    Task { await self.acknowledge(ids) }
                }, errorHandler: { _ in
                    // not delivered: pending again, for the next send
                    Task { await self.moveBack(id) }
                })
            } else {
                _ = session.transferUserInfo(payload)
            }
        }
    }

    /// WatchConnectivity refuses a payload a little over 64 KB; whole lines, at most `maxBytes` each part.
    static func parts(of log: String, maxBytes: Int = 48000) -> [String] {
        var parts: [String] = []
        var current = ""
        var size = 0
        for line in log.split(separator: "\n") {
            let lineSize = line.utf8.count + 1
            if size > 0, size + lineSize > maxBytes {
                parts.append(current)
                current = ""
                size = 0
            }
            current += line + "\n"
            size += lineSize
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
