# Barnard (Swift)

First-class Swift Package Manager library for native iOS apps to adopt the
Barnard protocol without a Flutter runtime dependency (barnard#56).

## Platform support

The package declares iOS 14 and macOS 10.15. The macOS floor is set by
`CBManager.authorization`, which the engine's Bluetooth permission check uses.

macOS is a full real-radio platform: `BarnardEngine` scans as a Central and
advertises as a Peripheral over CoreBluetooth exactly as it does on iOS, and
the whole package builds and tests natively with `swift build` / `swift test`.
Two differences are worth knowing before you ship a macOS host:

- **No background-advertising lifecycle handling.** On iOS the engine observes
  `UIApplication` activation notifications and bounces advertising when the app
  returns to the foreground, because iOS demotes the advertised service UUID
  into the AdvData overflow area while backgrounded (issue #45). macOS does not
  do that, so the observers are absent and advertising simply continues.
- **`openAppSettings()` is a no-op.** macOS has no per-app settings URL. Direct
  the user to System Settings > Privacy & Security > Bluetooth yourself.

Bluetooth permission on macOS is granted per application, and it has to be
granted once to a signed app bundle. On one development Mac a bare unsigned
executable linking this package received no `centralManagerDidUpdateState`
callback at all, so permission never became determinable. That is an
observation from a single machine and the cause is unconfirmed; if you hit it,
run the code from a signed `.app` bundle.

## Installation

Add as a Swift Package dependency (local path shown; publish via a Git tag
once this package is released):

```swift
dependencies: [
    .package(path: "../path/to/packages/swift/barnard")
]
```

Then depend on the `Barnard` product in your app target. The package also
publishes `BarnardCore` for deterministic RPID, ENIN, signing, and policy work
on non-Apple Swift targets. `BarnardCore` uses standard-library byte arrays and
integer Unix time; it does not expose Foundation types.

## Usage

```swift
import Barnard

let engine = BarnardEngine()
engine.onEvent = { event in
  switch event {
  case .detection(let d):
    print("detected rpid=\(d.rpid) rssi=\(d.rssi)")
  default:
    break
  }
}

engine.requestPermissions { status in
  guard status.canScan, status.canAdvertise else { return }
  engine.startAuto()
}
```

For per-event device signing identity (RPID ownership proofs, key binding),
use `BarnardIdentity` — see `Sources/Barnard/BarnardIdentity.swift`.

See `examples/ios-native` for a runnable minimal app.

## Relationship to the Flutter plugin

This package is the **canonical origin** for the shared Swift sources also
shipped inside `packages/dart/barnard/ios/barnard`. The Flutter plugin keeps a
referencing mirror copy because pub.dev packages must be self-contained:

- The platform adapters (`BarnardCrypto.swift`, `Secp256k1.swift`,
  `BarnardSigning.swift`, `BarnardRpidGenerator.swift`,
  `BarnardV2Policy.swift`, `BarnardPlatformDependencies.swift`, and
  `PrivacyInfo.xcprivacy`) are the native origins for byte-for-byte copies in
  the Flutter plugin.
- Every source under `Sources/BarnardCore` is likewise the native origin for
  the corresponding Flutter plugin copy under `Sources/barnard/BarnardCore`.
  `scripts/sync-mirrors.sh` regenerates both groups, and
  `scripts/check-swift-mirror.sh` fails CI if they drift.
- `BarnardEngine.swift` (Flutter-free port of `BarnardBleController`) and
  `BarnardIdentity.swift` (Flutter-free port of `BarnardIdentityController`)
  are native-only files, not mirrored sources. Their Flutter counterparts are
  woven into the method-channel API (`FlutterEventSink`, `FlutterMethodCall`)
  and cannot be copied verbatim. The native files expose the same behavior
  through a Swift-first public API (closures/return values instead of a
  method-channel dispatcher).

**Why keep a mirror copy instead of making the Flutter plugin depend on this
package**: the Flutter plugin ships via a CocoaPods podspec
(`packages/dart/barnard/ios/barnard.podspec`); making a CocoaPods pod depend
on a sibling local SwiftPM package is possible but nontrivial to wire up
safely, and this repo's CI/tooling here has no Flutter/CocoaPods toolchain
to validate that path end-to-end. Synchronizing the pure, dependency-free
sources from this native origin into the Flutter package, with a byte-identical
drift check, is lower-risk for this first slice. Follow-up: evaluate making
`packages/dart/barnard/ios` depend on this package directly once that path is
validated against a real Flutter build.
