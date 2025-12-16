# barnard

Barnard SDK for Flutter/Dart.

This package provides:
- Public API surface (types + interfaces)
- A mock implementation for early integration (no platform BLE yet)

Design goals
- Transport-agnostic API (future BLE/UWB/Thread)
- Receiver-observed facts: `rpid + rssi + timestamp`
- Push + pull: event streams plus bounded in-memory buffers
- Terminology is not translated: Scan / Advertise / Central / Peripheral / GATT / Transport

## Quick start (mock)

```dart
import "package:barnard/barnard.dart";

final barnard = Barnard.mock();
await barnard.startAuto();
```
