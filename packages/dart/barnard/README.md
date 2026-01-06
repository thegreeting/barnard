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

#### Permissions

**Android 12+ (API 31+):**

Add the following to your `AndroidManifest.xml`:

```xml
<!-- BLE permissions for Android 12+ -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />

<!-- Legacy permissions for Android 11 and below -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="28" />

<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
```

**Important:** The `neverForLocation` flag on `BLUETOOTH_SCAN` eliminates the need for location permission on Android 12+. Without this flag, `ACCESS_FINE_LOCATION` is required and users must grant "Precise location" (not just "Approximate") for BLE scanning to work.

#### Runtime Permission Request

With the `neverForLocation` flag, only request Bluetooth permissions at runtime:

```dart
// Android 12+ with neverForLocation flag - no location needed
await [
  Permission.bluetoothScan,
  Permission.bluetoothConnect,
  Permission.bluetoothAdvertise,
].request();
```

#### Scan Filter

The SDK uses a Service UUID filter (`0000B001-0000-1000-8000-00805F9B34FB`) for efficient scanning. This reduces battery consumption and filters out non-Barnard devices at the system level.

**Note:** iOS devices in background mode may not include the Service UUID in advertisement data (moved to "overflow area"). Foreground advertising works reliably.

## Channels

- MethodChannel: `barnard/methods`
- EventChannel: `barnard/events`
- EventChannel: `barnard/debugEvents`
