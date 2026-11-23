# Watch G7 direct (step 1)

The watch connects to the Dexcom G7 itself, in the sensor's **watch** display
slot (the phone keeps its own), so glucose and low/high alerts keep working
when the iPhone is out of reach. Display and alerts only: nothing here doses.

## Files

- `G7SensorKit/`: copied unchanged from LoopKit/G7SensorKit pull request #80
  (Jeremy Barnum's Sport Mode watch support), commit `1353226`. MIT licence,
  © LoopKit Authors. These are the Bluetooth, authentication and crypto layers,
  which need no LoopKit and already run on watchOS there, including the watch
  acquisition design (`G7WatchAcquisition`) and the faster P-256 maths that
  pairing on a watch needs.
  Six changes, marked `Trio:`: `G7WatchAcquisition.restored` keeps a connect restored
  under the central's own identifier instead of cancelling it, except across an app update;
  three missed bursts lodge a fresh connect alongside the scan pass, which the watch rations in
  the background (`lodgeFresh`); `G7WatchAcquisition.connected` holds
  background time from the link-up until the sensor closes it; `G7PeripheralManager.gattErrorHook`, so
  Bluetooth errors reach the watch log; the central's own restore identifier
  in `G7BluetoothManager.makeCentralManager` (untethered mode's G7SensorKit
  framework runs a second central with the original one); and `TimeInterval.swift`
  keeps only what Trio's `TimeInterval+Convenience.swift`, also in the watch
  target, doesn't declare. Re-apply them after copying the files again.
- `WatchG7Session.swift`: the session half of G7SensorKit's `G7Sensor` (direct
  mode), rewritten without LoopKit.
- `WatchG7Messages.swift`: glucose and backfill parsing without LoopKit.
- `WatchG7Reader.swift`: settings, history, alerts, and what the phone sends.
- `WatchG7View.swift`: the third page of the watch app.
- `TrioWatchAppDelegate.swift`: launches the reader at every (also background)
  launch and holds Bluetooth wakes.

## Keeping it current

The copied files are not tied to the phone's G7SensorKit submodule, so changes
to g7-direct on the phone never break the watch build. When the upstream watch
support changes, copy the same files again from the newer commit and check
`WatchG7Session.swift` against `G7Sensor.swift` there.

## Untethered mode

`../Untethered/` (ported from EJM0/Trio `feat/direct-to-watch`) hands the pod and
the G7 to the watch and loops there. It links the real G7SensorKit framework and
uses the same watch display slot on the sensor, so while a session runs (from the
grant to the hand-back) this reader stands aside (`WatchG7Reader.standAside`) and
resumes afterwards, pairing again by itself if the sensor took the other key.

## Credits

- **Jeremy Barnum**: G7SensorKit on the watch ([LoopKit/G7SensorKit#80](https://github.com/LoopKit/G7SensorKit/pull/80)), from which `G7SensorKit/` here is copied, the watch acquisition design and the faster P-256 maths included, and Sport Mode for Loop ([LoopKit/Loop#2545](https://github.com/LoopKit/Loop/pull/2545)), the watch running the loop on its own, which untethered mode builds on.
- **Pete Schwamb**: the fixes from his review of that pull request (a refused rebond drops the key; no start delay).
- **Deniz Cengiz**: the direct G7 connection in Trio's G7SensorKit.
