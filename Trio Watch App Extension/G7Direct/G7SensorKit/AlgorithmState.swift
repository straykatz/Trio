import Foundation

public enum AlgorithmState: RawRepresentable {
    public typealias RawValue = UInt8

    public enum State: RawValue {
        case stopped = 1
        case warmup = 2
        case excessNoise = 3
        case firstOfTwoBGsNeeded = 4
        case secondOfTwoBGsNeeded = 5
        case ok = 6
        case needsCalibration = 7
        case calibrationError1 = 8
        case calibrationError2 = 9
        case calibrationLinearityFitFailure = 10
        case sensorFailedDuetoCountsAberration = 11
        case sensorFailedDuetoResidualAberration = 12
        case outOfCalibrationDueToOutlier = 13
        case outlierCalibrationRequest = 14
        case sessionExpired = 15
        case sessionFailedDueToUnrecoverableError = 16
        case sessionFailedDueToTransmitterError = 17
        case temporarySensorIssue = 18
        case sensorFailedDueToProgressiveSensorDecline = 19
        case sensorFailedDueToHighCountsAberration = 20
        case sensorFailedDueToLowCountsAberration = 21
        case sensorFailedDueToRestart = 22
        case expired = 24
        case sensorFailed = 25
        // Reported by newer firmware (first seen on Stelo).
        case transmitterFailed = 27
        case sivFailed = 28
        case sessionFailedOutOfRange = 29
        case sessionEnded = 26
    }

    case known(State)
    case unknown(RawValue)

    public init(rawValue: RawValue) {
        guard let state = State(rawValue: rawValue) else {
            self = .unknown(rawValue)
            return
        }

        self = .known(state)
    }

    public var rawValue: RawValue {
        switch self {
        case let .known(state):
            return state.rawValue
        case let .unknown(rawValue):
            return rawValue
        }
    }

    public var sensorFailed: Bool {
        guard case let .known(state) = self else {
            return false
        }

        switch state {
        case .sensorFailed,
             .sensorFailedDuetoCountsAberration,
             .sensorFailedDueToHighCountsAberration,
             .sensorFailedDueToLowCountsAberration,
             .sensorFailedDueToProgressiveSensorDecline,
             .sensorFailedDuetoResidualAberration,
             .sensorFailedDueToRestart,
             .sessionFailedDueToTransmitterError,
             .sessionFailedDueToUnrecoverableError,
             .sessionFailedOutOfRange,
             .sivFailed,
             .transmitterFailed:
            return true
        default:
            return false
        }
    }

    public var isInWarmup: Bool {
        guard case let .known(state) = self else {
            return false
        }

        switch state {
        case .warmup:
            return true
        default:
            return false
        }
    }

    public var hasTemporaryError: Bool {
        guard case let .known(state) = self else {
            return false
        }

        switch state {
        case .temporarySensorIssue:
            return true
        default:
            return false
        }
    }

    public var hasReliableGlucose: Bool {
        guard case let .known(state) = self else {
            return false
        }

        switch state {
        case .ok:
            return true
        default:
            return false
        }
    }
}

extension AlgorithmState: Equatable {
    public static func == (lhs: AlgorithmState, rhs: AlgorithmState) -> Bool {
        switch (lhs, rhs) {
        case let (.known(lhs), .known(rhs)):
            return lhs == rhs
        case let (.unknown(lhs), .unknown(rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

extension AlgorithmState: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .known(state):
            return String(describing: state)
        case let .unknown(value):
            return ".unknown(\(value))"
        }
    }
}
