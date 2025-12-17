# barnard_poc

Barnard Flutter PoC app (real BLE via GATT-first RPID read).

## Run

```bash
flutter pub get
flutter run
```

## Notes

- iOS requires `NSBluetoothAlwaysUsageDescription` (and typically `NSBluetoothPeripheralUsageDescription`) in `Info.plist`.
- Android requires BLE permissions (Android 12+) and location permission on Android 11 and below.
