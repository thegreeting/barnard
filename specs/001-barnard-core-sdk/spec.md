# Feature Specification: Barnard Core SDK (BLE Sensing Foundation)

**Feature Directory**: `specs/001-barnard-core-sdk`  
**Created**: 2025-12-15  
**Status**: Draft  
**Input**: Redesign the BLE sensing plugin/SDK into a “native core SDK” that can be distributed beyond Flutter (RN / iOS / Android). Barnard’s responsibility is BLE Scan/Advertise and event delivery (main + debug). Domain logic (VC/POAP), server dependencies, and UI are out of scope.

## Assumptions (locked for this feature)

These are fixed assumptions as of 2025-12-16.

- Barnard **parses** the payload and also owns the procedure of generating RPID, advertising it, and sensing it
- The on-wire payload MUST NOT include any device-unique persistent identifier
- We want to record “environmental data” from each receiver’s perspective  
  → Each detection MUST include **RPID (from payload) + RSSI (measured by receiver)**
- “Environment data” here means **receiver-observed facts** (which `rpid` was observed, with which `rssi`, at which time). We do not assume any extra data is sent from the other device.
- OS differences (especially iOS privacy/constraints) must be absorbed while returning decision-useful information to upper layers
- Prototype support is **foreground-only**
- Prototype Scan/Advertise should start with **almost no configuration** (safe defaults)
- **Auto mode** (Scan + Advertise concurrently) is a first-class feature
- `debugEvents` must support both push + pull, be stored in an in-memory buffer (bounded), and be rate-controlled (sampling/aggregation)
- A short debug-only `displayId` (e.g., derived from RPID) is allowed as long as it does not increase tracking risk

### Terminology (do not translate)

To avoid mistranslation, this spec uses these terms consistently.

- **Scan**: detect nearby Advertise (Central role)
- **Advertise**: broadcast payload (Peripheral role)
- **Central / Peripheral**: CoreBluetooth role names
- **GATT**: post-connection communication via Service/Characteristic (`read` / `notify` / `write`)
- **Transport**: the radio layer implementation of Scan/Advertise (BLE / UWB / Thread, etc.). Barnard must be able to swap Transports.

### Decisions (2025-12-16)

- The `rpid + rssi` time series is receiver-observed facts; we do not require data coming from the other device
- High density (future: ~2000 devices) is assumed; default is **connectionless** RPID delivery (no connection)
- On iOS, prefer connectionless; use **GATT fallback** only if needed (goal: Read+Notify, acceptable: Read-only)
- The design is **Transport-agnostic** to allow future non-BLE transports (UWB/Thread)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Developer can Scan and receive detection events (Priority: P1)

As an app / upper-SDK developer, I want to start BLE Scan via Barnard and receive detection events in a convenient structured form. Lack of permission, Bluetooth OFF, and OS limitations should be reported with clear reason codes.

**Why this priority**: This is the foundation of sensing. Without this, higher-level features cannot proceed.

**Independent Test**: On iOS/Android devices, perform Scan start → detect → stop, and confirm both detection events and constraint/error events.

**Acceptance Scenarios**:

1. **Given** Bluetooth ON & permissions OK, **When** Scan starts, **Then** state becomes `scanning` and a `detection` event is emitted when a device is detected
2. **Given** Bluetooth OFF, **When** Scan starts, **Then** a `bluetooth_off`-like constraint/error is emitted and it is clear Scan cannot start (or stops immediately)
3. **Given** missing permissions, **When** Scan starts, **Then** a `permission_denied`-like constraint/error is emitted

---

### User Story 2 - Developer can Advertise (Priority: P1)

As an app / upper-SDK developer, I want to start/stop BLE Advertise via Barnard, sending a payload with an explicit format and version. OS constraints must be surfaced as reason codes.

**Why this priority**: Advertise is the counterpart to Scan and required for a usable sensing foundation.

**Independent Test**: On iOS/Android devices, perform Advertise start → stop and observe state transitions and constraint/error events.

**Acceptance Scenarios**:

1. **Given** Bluetooth ON & permissions OK, **When** Advertise starts, **Then** state becomes `advertising` and returns to `idle` on stop
2. **Given** OS constraints prevent Advertise, **When** Advertise starts, **Then** it fails with a reason code

---

### User Story 3 - Developer can observe internal debug timeline safely (Priority: P2)

As a developer, I want to observe what happens inside Barnard (timeline, state transitions, errors/warnings, raw/parsed detection, metrics) as `debugEvents` to visualize and troubleshoot. The debug stream must not contain secrets/PII.

**Why this priority**: BLE behavior varies by OS constraints; observability is critical for validation and operations.

**Independent Test**: When operating Scan/Advertise, debug events record start/stop/state changes/errors in order. Under high-frequency RSSI, the buffer remains bounded and the stream remains stable (sampling/aggregation).

**Acceptance Scenarios**:

1. **Given** debug subscription enabled, **When** Scan starts/stops, **Then** `scan_start/scan_stop` and state-transition events are emitted
2. **Given** high-frequency RSSI, **When** debug subscription enabled, **Then** sampling/aggregation and bounded buffering prevents overload

---

### User Story 4 - Core structure supports multiple distribution forms (Priority: P2)

As a maintainer, I want a core SDK structure that can be distributed as iOS (SPM) and Android (Maven/Gradle) while allowing thin wrappers (Flutter/RN) to expose the same contract.

**Why this priority**: This defines the long-term maintainability and portability of the SDK.

**Independent Test**: Add the iOS/Android artifacts into host projects and run minimal Scan/Advertise flows.

**Acceptance Scenarios**:

1. **Given** an iOS host project, **When** the SDK is added via SPM, **Then** a minimal Scan/Advertise sample runs
2. **Given** an Android host project, **When** the SDK is added via Gradle/Maven, **Then** a minimal Scan/Advertise sample runs

---

### Edge Cases

- Repeated `startScan()` calls (idempotent vs error vs restart)
- Permission revoked during Scan (state + events)
- Bluetooth turns OFF mid-session
- Foreground/background transitions (prototype is foreground-only; must be explicit)
- Payload parse failures (raw data returned? parsed null? error vs debug event?)
- Debug event flooding (sampling/aggregation/buffer bounds)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Barnard MUST provide BLE Scan start/stop on iOS/Android
- **FR-002**: Barnard MUST emit structured detection events (timestamp, RSSI, payload raw/parsed, platform metadata)
- **FR-003**: Barnard MUST provide BLE Advertise start/stop
- **FR-004**: Barnard MUST clearly specify Advertise payload format and version
- **FR-005**: Barnard MUST report permission/Bluetooth OFF/OS constraints/unsupported background etc. via reason-coded events
- **FR-006**: Barnard MUST define Scan/Advertise state and notify state transitions
- **FR-007**: Barnard SHOULD provide `debugEvents` (timeline, state transitions, errors/warnings, raw/parsed detection, metrics)
- **FR-008**: `debugEvents` MUST exclude secrets/PII and include rate/buffer controls (sampling/aggregation/bounds)
- **FR-009**: Barnard MUST NOT depend on a specific server URL or API spec
- **FR-010**: Barnard MUST NOT implement VC issuance/verification, POAP issuance, or other domain logic
- **FR-011**: Barnard MUST be structured to allow iOS (SPM) / Android (Maven/Gradle) distribution and thin wrappers (Flutter/RN)
- **FR-012**: Barnard MUST abstract platform constraints while returning decision-useful information to upper layers
- **FR-013**: Barnard MUST generate RPID and include it in Advertise payload; receiver MUST parse it into detection events
- **FR-014**: Barnard MUST provide a first-class Auto mode to start/stop Scan + Advertise together
- **FR-015**: Prototype support MUST be foreground-only and explicitly documented as such
- **FR-016**: `debugEvents` MUST support push (stream) and pull (buffer snapshot)
- **FR-017**: Barnard MAY provide a debug-only `displayId` (short identifier derived from RPID; not increasing tracking risk)
- **FR-018**: Barnard MUST NOT collapse RSSI to an average only; it MUST support time-series sampling/retention (bounded)
- **FR-019**: RPID `rotationSeconds` MUST be adjustable by upper layers for debugging (with safe bounds)
- **FR-020**: Prototype `ScanConfig` / `AdvertiseConfig` MUST be minimal and have safe defaults when omitted
- **FR-021**: Barnard MUST support connection-based data exchange via GATT as an optional fallback (connect/reconnect + minimal Read/Notify/Write)

### Platform Requirements

- **FR-IOS-001**: iOS host apps MUST provide `NSBluetoothAlwaysUsageDescription` (documented requirement)
- **FR-IOS-002**: If background Scan/Advertise is ever supported, host apps MUST provide `UIBackgroundModes` (`bluetooth-central` / `bluetooth-peripheral`) (documented requirement)
- **FR-IOS-003**: iOS implementation SHOULD allow State Restoration (`CBCentralManagerOptionRestoreIdentifierKey` / `CBPeripheralManagerOptionRestoreIdentifierKey`) when needed

### Prototype API Sketch (minimal config)

Prototype prioritizes “works with no config”. Config is primarily for debug overrides.

- `startScan(config?)` / `stopScan()`
- `startAdvertise(config?)` / `stopAdvertise()`
- `startAuto(config?)` / `stopAuto()` (first-class)
- `events` (detection / state / constraint / error)
- `debugEvents` (push) + `getDebugBuffer()` (pull)
- `getRssiSamples({ since?, limit?, rpid? })` (pull; time series)

Example config knobs (conceptual; language-specific mapping):

- `rpid.rotationSeconds` (default: 600, range: 60..3600)
- `rssi.minPushIntervalMs` (default: 1000)
- `rssi.bufferMaxSamples` (default: 20000)

## RPID (Rotating Proximity ID) and Payload (draft)

Barnard MUST NOT include device-unique identifiers in Advertise, but it MUST provide a correlation key (RPID) for near-field sensing.

- **Goal**: Receiver can correlate “same sender within the same time window” while minimizing tracking risk
- **Rotation**: default **10 minutes** (tentative). Upper layers may override for debugging (with safe bounds)
- **Non-goal**: Deriving a stable device identity from RPID (no persistence across windows)

### Recommended generation (tentative)

- Each device stores a local secret `rpidSeed` (random; never sent externally)
- Compute `windowIndex = floor(unixTimeSeconds / rotationSeconds)`
- Compute `rpid = Truncate(HMAC-SHA256(rpidSeed, windowIndex), 16 bytes)`

### Tracking risk minimization

- RPID is derived from an on-device secret; without `rpidSeed` it must not be predictable
- Store `rpidSeed` in storage that is removed on uninstall (avoid stores that may survive uninstall, e.g., iOS Keychain)
- Enforce safe bounds for rotation to avoid excessive battery/CPU (e.g., 60s..3600s)
- Optional: `epochOffsetSeconds` (0..rotationSeconds-1) to desynchronize rotation boundaries across devices

### displayId (debug-only)

- `displayId` is derived one-way from RPID (e.g., first bytes in hex/base32)
- It rotates with RPID and must not become a persistent identifier

### Advertise Payload (logical format)

Barnard’s “payload” is a **logical format**; on-wire encoding may vary by OS, but Barnard must normalize to return `rpid`.

- `formatVersion`: 1 (prototype fixed; returned explicitly to upper layers)
- `rpid`: 16 bytes
- (future) `payloadType` / `flags` / `reserved`

#### iOS on-wire (CoreBluetooth Peripheral)

iOS Advertise fields are constrained, so Barnard should prioritize **connectionless** RPID delivery where possible.

- Advertise (discovery): fixed Service UUID (= Barnard Discovery Service) + fixed short Local Name (e.g., `BNRD`)
- Advertise (rpid): encode `rpid` in allowed fields (e.g., Service UUID or Service Data). Receiver parses Advertise to obtain `rpid`.

Receiver flow: Scan → parse Advertise → obtain `rpid` → emit detection with `rpid + rssi`.

#### iOS: GATT (optional fallback)

If connectionless `rpid` delivery is not possible or not stable enough, Barnard may use a **GATT fallback**.

- Central connects, then obtains `rpid` via GATT
- Target: **Read + Notify** supported; acceptable minimum: **Read-only**
- In high density environments, GATT must be default-off (opt-in) or heavily budgeted (connections become a bottleneck)

#### Android on-wire (tentative)

Android generally allows more freedom than iOS. Prototype should prioritize “the minimal design that works on iOS”, and consider extensions (Service Data / Manufacturer Data) later.

Receiver MUST parse payload and include `rpid + rssi` in detections.

### Payload versioning (tentative)

- `formatVersion` is the boundary for breaking changes
- Unknown `formatVersion` should result in `payloadParsed = null` with `payloadRaw` preserved and an `unsupported_version`-like debug/constraint event

## RSSI sampling and in-memory buffer (draft)

RSSI carries information for “environment data”. Barnard should support both push and pull while keeping the system stable.

### Push (stream): stable under load

- `detection` can be high-frequency; push may sample/aggregate
- Example: per `rpid`, enforce `minPushIntervalMs` (e.g., 500..2000ms) and emit `rssiSummary` (`count/min/max/mean`) instead of raw per-hit RSSI

### Pull (buffer): return time series

- Maintain an in-memory ring buffer of `RssiSample { timestamp, rpid, rssi }`
- Bound by count or memory estimate (e.g., 20,000 samples). Drop oldest on overflow.
- Pull API supports `since` / `limit` (and optionally `rpid` filter)

### Prototype defaults

- Push prioritizes stability (sampling/aggregation allowed)
- Pull retains as much raw data as possible (within bounds)

## Auto mode (Scan + Advertise)

Auto mode is first-class.

- `startAuto()` starts Scan + Advertise concurrently; `stopAuto()` stops both
- Partial success must be representable (e.g., Scan started but Advertise failed with a reason code)
- Prefer representing state orthogonally (`isScanning` / `isAdvertising`) while optionally providing a simplified composite state for upper layers

## iOS constraints and GATT (connectionless first)

iOS constrains what can be encoded in Advertise. Barnard must prioritize connectionless RPID delivery and use GATT fallback only when needed.

### iOS: foreground-only prototype

- Prototype is foreground-only; background requirements are deferred and must be explicit
- Use fixed Service UUID + fixed Local Name for discovery; try to carry `rpid` connectionlessly; otherwise use GATT fallback
- For RSSI time series, Central Scan may require `AllowDuplicates = true`; Barnard must prevent overload via sampling/buffers

### GATT (optional / fallback)

GATT is a fallback for cases where connectionless RPID delivery is impossible/unstable.

- Connect budget knobs: `maxConcurrentConnections`, `cooldownPerPeripheral`, `connectBudgetPerMinute`, `maxConnectQueue`

## Architecture Sketch (Transport-agnostic / clean boundaries)

Barnard must be extensible beyond BLE (e.g., UWB/Thread). The upper layer should not care which Transport is used; it should consume the same contract.

- `BarnardCore` (pure logic): RPID generation, payload parsing, RSSI buffer, sampling, state transitions, debug buffer
- `Transport` (swappable): start/stop Scan/Advertise, emit raw detections to Core
- `PlatformDriver` (OS implementation): iOS CoreBluetooth / Android BLE APIs / future UWB/Thread

Minimal Core input (conceptual):

- `TransportDetection { timestamp, transportKind, rawPayload?, rssi, metadata }`

Minimal Core output:

- `DetectionEvent { timestamp, rpid, rssi, transportKind, displayId?, payloadVersion }`

Transport capabilities (examples):

- `supportsConnectionlessRpid`
- `supportsGattFallback`
- `supportsRssiHighRate`

## Reference Implementation Notes (from a prior iOS prototype)

Notes captured from a prior iOS prototype (described here so the team does not need external references):

- Central uses `scanForPeripherals(withServices: [discoveryServiceUUID], options: ...)` to filter discovery
- Peripheral uses minimal Advertise data (`LocalName` + `ServiceUUIDs`) for discovery
- Central auto-connects on discovery in the prototype; production/high-density should use connect budgeting
- Observe Central/Peripheral state changes (`poweredOn/off/unauthorized/unsupported`) via logs/events
- Background requires `UIBackgroundModes` and `NSBluetoothAlwaysUsageDescription` (deferred for prototype)
- Auto mode starts both Scan and Advertise
- Minimal GATT setup: 128-bit Service + Write/Notify Characteristics (if using GATT fallback). Target: Read+Notify; acceptable: Read-only.

### Key Entities *(include if feature involves data)*

- **BarnardState**: `idle / scanning / advertising / error` (minimal)
- **StateTransition**: `from/to` + reason
- **ScanConfig**: minimal for prototype
- **AdvertiseConfig**: minimal for prototype
- **DetectionEvent**: `timestamp`, `rssi`, `rpid`, `payloadRaw`, `payloadParsed?`, `transportKind`, `sourcePlatform`
- **ConstraintEvent / ErrorEvent**: `code`, `message?`, `recoverability`, `requiredAction?`
- **DebugEvent**: timeline events (start/stop/detection/permission/Bluetooth changes/warnings/errors/metrics)
- **MetricsSnapshot**: counts, last seen, uptime, error counts
- **PayloadFormat**: `name`, `version`, `fields`
- **RPIDConfig**: `rotationSeconds`, etc.
- **RssiSample**: `timestamp`, `rpid`, `rssi`
- **RssiSummary**: `count/min/max/mean`
- **RssiBuffer**: in-memory ring buffer
- **displayId**: derived debug-only short ID

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On iOS/Android devices, Scan start → detect → stop works and detection events can be obtained
- **SC-002**: On iOS/Android devices, Advertise start → stop works and state transitions can be obtained
- **SC-003**: Major failure paths (permission/Bluetooth OFF/OS constraints) emit reason-coded events
- **SC-004**: Debug events provide a stable timeline and state transitions without secrets/PII, under bounded rate/buffer controls
- **SC-005**: Distribution strategy (SPM/Maven + thin wrappers) is agreed as a spec

## Open Questions / Clarifications

- RPID details: concrete seed storage per platform, epochOffset adoption, rotationSeconds bounds
- RSSI sampling defaults: `minPushIntervalMs`, buffer bounds, pull API details
- Auto mode semantics: partial success representation, recovery/retry policy
- iOS connectionless on-wire encoding for `rpid` (which fields are used) and parse rules
- High-density Scan defaults (filters / AllowDuplicates / sampling) to remain stable up to future ~2000 devices
- GATT fallback enablement (default-off vs debug-only) and connection budgeting defaults
- Minimal Transport interface details (input/output contracts + capabilities)
