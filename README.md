# Barnard

Barnard is a sensing foundation SDK.

It focuses on **Scan/Advertise** and delivering a stable event model (main + debug) for upper layers (e.g., Flutter / React Native), while keeping domain logic and server dependencies out of scope.

## Repository layout

- `specs/` — product and SDK specifications (source of intent)
- `schema/` — language-agnostic **JSON Schemas** (source of truth for event/config/capabilities shapes)
- `packages/`
  - `packages/dart/barnard/` — Flutter plugin package (public API + mock + real BLE Transport)
- `examples/`
  - `examples/dart/barnard_demo/` — demo using the mock implementation
  - `examples/flutter/barnard_poc/` — Flutter PoC app (real BLE via GATT-first RPID read)
- `.github/workflows/` — CI (Flutter analyze/test + demos)

## Dart (Flutter) quick start

From `packages/dart/barnard`:

```bash
flutter pub get
flutter test
```

Run the demo:

```bash
cd examples/dart/barnard_demo
flutter pub get
dart run bin/main.dart
```

Run the Flutter PoC app:

```bash
cd examples/flutter/barnard_poc
flutter pub get
flutter run
```

## Principles

- Detection is based on **receiver-observed facts**: `rpid + rssi + timestamp`
- Cross-language consistency is driven by **JSON Schema** under `schema/barnard/v1`
