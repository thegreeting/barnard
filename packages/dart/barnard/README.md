# barnard

Barnard SDK for Flutter/Dart.

This package provides:
- Public API surface (types + interfaces)
- `MockBarnard` for early integration (no hardware)
- Real BLE Transport for Flutter (GATT-first RPID read)

The real BLE Transport implements **Scan / Advertise** with **GATT-first** RPID delivery:
- Advertise is used for discovery (service UUID).
- The receiver (Central) connects and reads a 17-byte payload from a readable characteristic:
  - `[formatVersion:uint8][rpid:16 bytes]`

## Usage

Create a client and subscribe to streams:

```dart
import "package:barnard/barnard_ble.dart";

final client = await BarnardBleClient.create();
await client.startAuto();
```

## Example

Run the Flutter PoC app:

```bash
cd examples/flutter/barnard_poc
flutter pub get
flutter run
```

## Platform notes

### iOS

- Host app must include `NSBluetoothAlwaysUsageDescription` (and typically `NSBluetoothPeripheralUsageDescription`) in `Info.plist`.
- Foreground-only.

### Android

- Android 12+ requires runtime permissions: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`.
- Android 11 and below requires location permission for scanning.

## Channels

- MethodChannel: `barnard/methods`
- EventChannel: `barnard/events`
- EventChannel: `barnard/debugEvents`
