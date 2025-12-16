# Barnard

Barnard is a sensing foundation SDK.

It focuses on **Scan/Advertise** and delivering a stable event model (main + debug) for upper layers (e.g., Flutter / React Native), while keeping domain logic and server dependencies out of scope.

## Repository layout

- `specs/` — product and SDK specifications (source of intent)
- `schema/` — language-agnostic **JSON Schemas** (source of truth for event/config/capabilities shapes)
- `packages/`
  - `packages/dart/barnard/` — Dart package for Flutter integration (public API + mock implementation)
- `examples/`
  - `examples/dart/barnard_demo/` — demo using the mock implementation
- `.github/workflows/` — CI (Dart analyze/test + demo smoke run)

## Dart (Flutter) quick start

From `packages/dart/barnard`:

```bash
dart pub get
dart test
```

Run the demo:

```bash
cd examples/dart/barnard_demo
dart pub get
dart run bin/main.dart
```

## Principles

- Detection is based on **receiver-observed facts**: `rpid + rssi + timestamp`
- Cross-language consistency is driven by **JSON Schema** under `schema/barnard/v1`

