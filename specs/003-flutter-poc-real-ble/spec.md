# Feature Specification: Flutter PoC (real BLE MVP)

**Feature Directory**: `specs/003-flutter-poc-real-ble`  
**Created**: 2025-12-17  
**Status**: Draft  
**Input**: Build a Flutter PoC that performs real BLE **Scan/Advertise** (foreground-only) and surfaces Barnard’s event model to Flutter.

## Problem statement

A mock-only Flutter app validates UI wiring but does not validate the actual sensing constraints that matter:
- OS/platform limitations (iOS/Android)
- BLE state transitions and failure modes
- Real detection cadence, RSSI behavior, and performance

We need a minimal real-Transport PoC that can be exercised on real devices to validate feasibility and the event contract.

## Goals

- Implement a minimal BLE **Transport** for iOS and Android that supports:
  - Scan (Central) emitting DetectionEvent with `rpid + rssi + timestamp`
  - Advertise (Peripheral) for discovery + GATT service for reading `rpid` (GATT-first)
  - Auto mode (Scan + Advertise concurrently)
- Expose the Barnard event model to Flutter via a thin wrapper layer.
- Provide clear state/constraint/error reporting for:
  - Bluetooth powered off / unauthorized / unsupported
  - OS limitations that prevent Advertise or Scan
- Keep all buffers bounded (debug + RSSI + UI).

## Decisions (2025-12-17)

- Flutter integration is implemented as a **Flutter plugin** using platform channels.
  - Native platform code owns BLE APIs and emits events.
  - Flutter UI remains Transport-agnostic and consumes Barnard events.
- Prototype scope is **foreground-only**.

## Non-goals

- Background Scan/Advertise.
- Connectionless payload delivery (Service Data / Manufacturer Data) for RPID in MVP.
- Any server integration or domain logic.
- Persisting any device-unique identifiers. 

## Terminology (do not translate)

- **Scan** / **Advertise** / **Central** / **Peripheral** / **GATT** / **Transport**

## Architecture and boundaries

Barnard’s layering from the core spec applies:
- `BarnardCore` (pure logic): RPID generation, payload parsing, sampling, buffers, state transitions
- `Transport` (BLE): OS BLE implementation (iOS CoreBluetooth / Android BLE APIs)
- Flutter wrapper: forwards start/stop/config, streams events/debugEvents, provides pull APIs

This PoC uses:
- A Flutter plugin package for platform code (required for MVP)

The PoC MUST keep Transport-specific logic inside Transport modules, not inside Flutter UI.

### Platform channels (MVP)

Flutter <-> native interface is split into:
- **MethodChannel**: commands and pull APIs
- **EventChannel**: push streams

Recommended channels:
- `barnard/methods`
- `barnard/events` (BarnardEvent stream)
- `barnard/debugEvents` (BarnardDebugEvent stream)

MethodChannel calls (conceptual):
- `getCapabilities() -> BarnardCapabilities`
- `getState() -> BarnardState`
- `startScan(config?) -> void`
- `stopScan() -> void`
- `startAdvertise(config?) -> void`
- `stopAdvertise() -> void`
- `startAuto(config?) -> BarnardStartResult` (optional; can also return void and rely on events)
- `stopAuto() -> void`
- `getDebugBuffer(limit?) -> List<BarnardDebugEvent>`
- `getRssiSamples(since?, limit?, rpidBytes?) -> List<RssiSample>`

Serialization:
- Payloads over channels MUST be JSON-serializable maps/lists.
- Event shapes MUST match `schema/barnard/v1/*.schema.json` logically (timestamp, base64 bytes, enums as strings).

## Payload and privacy constraints

- On-wire payload MUST NOT contain any device-unique persistent identifier.
- RPID generation follows the core spec (rotation window, on-device secret, etc.).
- `displayId` is debug-only and must rotate with RPID.

### GATT RPID delivery (locked for MVP)

The MVP uses GATT to deliver RPID to the receiver:
- Advertise is used only for discovery.
- The receiver (Central) connects and reads the current RPID via a GATT characteristic.

This matches the approach used in the existing iOS sample under `BLE-example` (discover via service UUID, then connect and interact via GATT).

#### Barnard discovery identifiers (MVP constants)

- **Discovery Service UUID (GATT service UUID)**: `0000B001-0000-1000-8000-00805F9B34FB` (128-bit)
- **RPID characteristic UUID**: `0000B002-0000-1000-8000-00805F9B34FB` (128-bit)
- **Local Name (optional)**: `BNRD` (debug/discovery only; not a stable identifier)

#### RPID characteristic value bytes (v1, MVP)

Characteristic value is exactly 17 bytes:
- byte 0: `formatVersion` (uint8). MVP uses `1`.
- bytes 1..16: `rpid` (16 bytes)

No other fields are allowed in MVP.

#### Advertise (Peripheral) for discovery

- MUST include Discovery Service UUID in advertised service UUIDs.
- MAY include Local Name `BNRD`.

#### GATT service and characteristic (Peripheral)

Peripheral exposes a primary service and a readable characteristic:
- Service UUID: Discovery Service UUID
- Characteristic UUID: RPID characteristic UUID
- Properties:
  - MUST support `read`
  - MAY support `notify` (optional for MVP)

#### Scan -> Connect -> Read flow (Central)

When scanning:
- If Discovery Service UUID is not present: ignore as non-Barnard.
- On discovery:
  - Record receiver-observed `rssi` and `timestamp` from the scan result.
  - Connect to the peripheral (budgeted; see below).
  - Discover the service UUID and the RPID characteristic UUID.
  - Read the characteristic value.
  - If value length != 17: emit DebugEvent (`name=payload_invalid_length`) and ignore.
  - Else:
    - Parse `formatVersion` from byte 0 and `rpid` from bytes 1..16.
    - If `formatVersion` unsupported (not `1` in MVP): emit DebugEvent (`name=payload_unsupported_version`) and ignore.
    - Emit DetectionEvent:
      - `formatVersion` = parsed version
      - `rpid` = base64 encoding of the 16 bytes (schema type `RpidBytes`)
      - `displayId` = first 4 bytes of `rpid` as lowercase hex (debug-only)
      - `rssi` = RSSI observed at discovery time (receiver-observed facts)
      - `payloadRaw` = base64 encoding of the raw 17 bytes (optional, if available)

If the connection/read fails, emit ConstraintEvent/ErrorEvent with a reason code that distinguishes:
- connection failed / timeout
- service not found / characteristic not found
- read failed

#### Connection budgeting (MVP)

GATT does not scale in high-density environments, but it is acceptable for MVP validation.

MVP defaults:
- `maxConcurrentConnections = 1`
- `maxConnectQueue` is bounded
- `cooldownPerPeerSeconds` is non-zero to avoid reconnect storms

#### Android/iOS alignment

Both platforms MUST use the same service UUID, characteristic UUID, and 17-byte characteristic value format so that:
- Android Scan can read iOS Advertise targets via GATT.
- iOS Scan can read Android Advertise targets via GATT.

## User-facing behavior (PoC app)

- A Flutter app can:
  - Start/Stop Scan, Advertise, Auto
  - Observe StateEvent and reason codes
  - Observe DetectionEvent list (including `rpid`, `displayId`, `rssi`, `transport`, `formatVersion`)
  - Observe debugEvents (push + pull buffer)
  - Pull RSSI samples (since/limit)

## Platform requirements (foreground-only)

### iOS

- Host app MUST provide required Info.plist keys (documented in README for the PoC app).
- Advertise constraints MUST be surfaced as ConstraintEvent/ErrorEvent with reason codes (no silent failure).

#### iOS Advertise constraints (CoreBluetooth)

CoreBluetooth imposes strict limits on what iOS can Advertise and how reliably it is discoverable:
- iOS Peripheral advertising only supports `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`.
- Advertising payload size is small; excess Service UUIDs can be moved to an overflow area.
- Background advertising changes behavior: Local Name is not advertised, and all Service UUIDs are placed in the overflow area.
- Advertising is "best effort" and can be throttled when many apps are advertising.

**Impact on Android Scan**
- Android cannot discover iOS service UUIDs when they are placed in the overflow area.
- Therefore, **Android Central will often fail to discover iOS Peripheral when the iOS app is in the background**, even if Android is actively Scanning.

**PoC guidance**
- Keep the iOS app in the foreground during Advertise tests.
- Advertise only the single Barnard Discovery Service UUID to avoid overflow.

### Android

- Required permissions MUST be documented and validated (ConstraintEvent/ErrorEvent on missing permissions).
- Advertise limitations (device does not support, settings disabled, etc.) MUST be surfaced with reason codes.
- Scan SHOULD apply a local filter fallback for iOS foreground advertising:
  - Prefer Discovery Service UUID match when available.
  - If Service UUID is absent, accept `Local Name = BNRD` as a best-effort fallback.
  - Rationale: iOS advertising can omit Service UUIDs due to payload constraints.
- For PoC diagnostics, Android MAY treat any connectable ScanResult as a candidate and confirm via GATT service discovery.

## Success criteria (Definition of Done)

- Real devices:
  - iOS device: Scan and (if supported) Advertise works in foreground; constraints/errors are surfaced otherwise.
  - Android device: Scan and Advertise works in foreground.
  - Two-device test: one Advertise + one Scan yields DetectionEvents with changing RSSI.
- Event contract:
  - DetectionEvent includes `formatVersion`, `rpid` (base64 bytes), `displayId`, `rssi`, `timestamp`, `transport`.
  - State transitions are emitted as StateEvent.
  - Permission/Bluetooth issues are emitted as ConstraintEvent/ErrorEvent with clear codes.
- Stability:
  - Buffers are bounded; the app remains responsive for at least 5 minutes of continuous operation.
- Documentation:
  - Running instructions, required iOS entitlements/Info.plist keys, and Android permissions are documented.

## Test plan (MVP)

- Two-device test matrix:
  - Android Advertise -> iOS Scan
  - iOS Advertise -> Android Scan (if iOS Advertise is feasible for MVP)
- Failure mode checks:
  - Bluetooth OFF: startScan/startAdvertise produces ConstraintEvent (code includes platform state)
  - Permissions denied: startScan/startAdvertise produces ConstraintEvent/ErrorEvent with requiredAction
- Performance sanity:
  - Continuous scan for 5 minutes: bounded memory for event lists and buffers, UI remains responsive
