# Barnard

Barnard is a mobile BLE sensing SDK for applications that need structured,
receiver-observed events from nearby devices.

## Positioning

Barnard is for native iOS and Android, Flutter/Dart, and React Native
applications that need to Scan, Advertise, and consume BLE observations without
making a backend or product-specific domain model part of the SDK.

The repository is organized around a few design principles:

- **Receiver-observed events.** Detections represent what the receiver observed:
  an RPID, RSSI, and timestamp. Higher layers decide how to interpret or store
  those events.
- **GATT-first RPID delivery.** A Peripheral advertises the Barnard service for
  discovery; a Central then connects and reads the RPID through GATT. This keeps
  the discovery advertisement separate from the RPID payload.
- **Schema-first contracts.** Language-agnostic JSON Schema defines shared event,
  configuration, and capability shapes so SDK implementations do not need to
  share runtime code to share a contract.
- **Privacy at the wire boundary.** Barnard's BLE payloads do not contain a
  device-unique persistent identifier. The v2 protocol does not transmit a TEK
  over BLE.
- **Native SDKs alongside framework bindings.** Swift and Android packages let
  native apps use Barnard without a Flutter or React Native runtime, while the
  Flutter/Dart and React Native packages provide framework-specific APIs.

## What is implemented

- The Flutter/Dart and React Native packages expose BLE Scan and Advertise APIs,
  including a GATT-based RPID exchange on iOS and Android.
- The native Swift and Android packages expose first-class platform APIs and are
  built and tested directly in CI. They are the canonical origins for shared
  crypto, signing, and RPID sources; mirror checks verify the Flutter plugin's
  referencing copies byte-for-byte.
- Examples cover mock-driven Dart use, real Flutter BLE use, and minimal native
  iOS and Android integrations. The native Android example also contains a
  two-device test-loop script for a device lab.

## Repository layout

Every top-level directory is listed here. Each entry describes both its contents
and the reason it is kept in the repository.

```text
.
├── .codex/       # Spec Kit prompt files; keep repeatable AI-assisted spec work close to its templates.
├── .github/      # GitHub Actions workflows; verify packages and examples on pull requests and main.
├── .specify/     # Spec Kit constitution, scripts, and templates; make specifications a reviewable source of intent.
├── .vscode/      # Workspace settings and launch configuration; provide a shared local development baseline.
├── examples/     # Runnable integrations; prove each SDK surface in a minimal host application.
├── packages/     # Distributable SDK packages; provide native and framework-specific adoption paths.
├── schema/       # Versioned JSON Schema; define language-agnostic public shapes before implementation details.
├── scripts/      # Repository checks and sync; keep Dart mirrors aligned with native origins.
├── specs/        # Feature specifications; record behavior, boundaries, and privacy decisions independently of code.
└── tools/        # Focused developer utilities; keep one-off protocol and scanner tooling outside SDK packages.
```

### Packages

`packages/` contains the public SDK surfaces. The native packages coexist with
the framework bindings because a host app should be able to adopt Barnard in its
own runtime rather than carry an unrelated framework runtime.

```text
packages/
├── swift/barnard/        # Swift Package Manager library for native iOS apps.
├── android/barnard/      # Gradle library for native Android apps.
├── dart/barnard/         # Flutter plugin and Dart API, including mock and BLE Transport implementations.
└── react-native/barnard/ # React Native package with a TypeScript API and native iOS/Android modules.
```

- `packages/swift/barnard/` is a Swift Package Manager library for iOS 14 and
  later and macOS 12.0 and later. It exists so native iOS and macOS apps can
  use Barnard without a Flutter runtime; its shared Flutter-free sources are the
  canonical Swift origins. See its README for the macOS support scope.
- `packages/android/barnard/` is a Gradle library for Android API 24 and later.
  It exists so native Android apps can use typed Kotlin APIs without a Flutter
  or React Native runtime; its shared Flutter-free sources are the canonical
  Kotlin origins.
- `packages/dart/barnard/` is the Flutter/Dart SDK. It exists for Flutter apps
  that need the shared domain API, a hardware-free `MockBarnard` integration
  path, or the platform BLE Transport. Its referencing Swift and Kotlin copies
  are synchronized from the native origins and checked for byte-for-byte drift.
- `packages/react-native/barnard/` is the React Native SDK. It exists for React
  Native apps that need a TypeScript API over native iOS and Android BLE
  implementations.

### Supporting directories

- `examples/` contains `dart/barnard_demo`, `flutter/barnard_poc`,
  `ios-native`, `android-native`, and `react-native/barnard_demo`. They keep
  integration and platform setup observable without turning a production app
  into a test fixture.
- `schema/` contains versioned Barnard v1 and v2 JSON Schema definitions. It is
  separate from any package so Dart, Swift, Kotlin, and TypeScript consumers can
  share public shapes without sharing an implementation language.
- `specs/` contains the numbered core SDK, Flutter prototype, real BLE, and
  resolvable-ID specifications. It preserves the intended behavior and
  constraints that code alone cannot explain.
- `tools/` currently contains `barnard-scan`, a small scanner utility. Keeping
  it outside `packages/` prevents a focused developer tool from becoming a
  required SDK dependency.
- `scripts/` contains the Swift and Android mirror checks and the native-to-Dart
  sync helper. They make the deliberate shared-source relationship between
  native SDK origins and the Flutter plugin's referencing copies verifiable in
  CI.
- `.github/` contains the Dart and native SDK workflows. It keeps package
  verification in the repository where changes are reviewed.
- `.specify/` contains Spec Kit templates, helper scripts, and the project
  constitution; it keeps the specification workflow repeatable.
- `.codex/` contains the corresponding Spec Kit prompt files for Codex-driven
  work, so the repository's workflow can be invoked consistently.
- `.vscode/` contains shared editor settings and launch configuration, reducing
  local setup differences without imposing an editor at runtime.

## Package quick starts

Choose the package for the host application. Each package README contains its
installation and usage details, plus platform-specific setup where required.

- [Swift / native iOS](packages/swift/barnard/README.md)
- [Android / native Kotlin](packages/android/barnard/README.md)
- [Flutter / Dart](packages/dart/barnard/README.md)
- [React Native](packages/react-native/barnard/README.md)

### Swift Package Manager installation

Add Barnard to the `dependencies` in your package manifest:

```swift
.package(url: "https://github.com/levarac/barnard.git", from: "0.1.0")
```

The repository-root `Package.swift` supports remote consumption. The inner
manifest at `packages/swift/barnard/Package.swift` remains available for
in-repository development, and CI checks that their declarations stay aligned.

## Protocol and privacy references

The [resolvable-ID v2 specification](specs/004-resolvable-id/spec.md) defines
the current GATT service and the RPID wire form. The [schema README](schema/README.md)
explains how the versioned JSON Schema directories relate to SDK contracts.
