# Feature Specification: Flutter UX Prototype (mock-first)

**Feature Directory**: `specs/002-flutter-ux-prototype`  
**Created**: 2025-12-17  
**Status**: Draft  
**Input**: We want a Flutter UX prototype that validates Barnard’s event model and basic developer UX by using `MockBarnard` (no platform BLE Transport yet).

## Problem statement

We have:
- A core Barnard spec (`specs/001-barnard-core-sdk/spec.md`)
- A schema-first v1 contract (`schema/barnard/v1/*`)
- A Dart public API + mock implementation (`packages/dart/barnard`)

But we do not yet have a Flutter UX prototype that makes the contract tangible:
- Can an app developer start/stop Scan/Advertise/Auto and understand state transitions?
- Are Detection/Constraint/Error events easy to visualize and debug?
- Are debugEvents (push + pull) and RSSI samples (pull) usable in practice?
- Is the UX prototype stable and bounded (no runaway memory growth) under a steady stream of detections?

## Goals

- Provide a runnable Flutter app that exercises the Barnard Dart API using **MockBarnard**.
- Validate the UX surface for upper layers:
  - Control flows: `startScan`, `startAdvertise`, `startAuto`, and the corresponding stop operations
  - Observability: `events`, `debugEvents`, `getDebugBuffer()`, `getRssiSamples()`
- Establish a reviewable “Definition of Done” for the UX prototype without reading code.
- Keep the UX prototype stable under a steady event stream (bounded UI state).

## Non-goals

- Real BLE Scan/Advertise implementations (no iOS/Android native code in this UX prototype).
- Background mode support, OS permission flows, or system settings deep links (can be simulated only).
- Server/domain logic, identifiers beyond RPID/displayId, or any app-specific UI/flows.
- Protocol/on-wire encoding decisions beyond what is already described in the core spec.

## Terminology (do not translate)

- **Scan**: detect nearby Advertise (Central role)
- **Advertise**: broadcast payload (Peripheral role)
- **Central / Peripheral**: CoreBluetooth role names
- **GATT**: post-connection communication via Service/Characteristic (`read` / `notify` / `write`)
- **Transport**: the radio layer implementation of Scan/Advertise (BLE / UWB / Thread, etc.)

## Scope and constraints

### Transport and data model scope (mock-first)

- The UX prototype uses the Dart package API at `packages/dart/barnard`.
- The UX prototype uses `MockBarnard` as the `BarnardClient` implementation.
- No device hardware access is required for the UX prototype.

### Security & privacy

- The UX prototype MUST NOT introduce any device-unique persistent identifiers into any on-wire payload formats.
  - Note: this UX prototype does not implement on-wire Transport, but it must not add new on-wire fields or shapes.
- The UX prototype MUST treat `displayId` as debug-only and non-persistent.

### Boundedness

- UI state MUST be bounded:
  - Event list views must cap retained items (e.g., last N events).
  - Debug list views must cap retained items (e.g., last N debug events).
- The UX prototype must not accidentally create unbounded streams/subscriptions (dispose correctly).

## User-facing behavior

### Primary flows

The UX prototype presents a minimal UI with the following sections:

1) **Controls**
   - Buttons:
     - Start/Stop Scan
     - Start/Stop Advertise
     - Start/Stop Auto
   - Optional controls (debug):
     - peer count (affects MockBarnard)
     - tick interval ms (affects MockBarnard)
     - rotation seconds override (affects MockBarnard)
     - minPushIntervalMs override (affects MockBarnard)
     - RSSI buffer max samples override (affects MockBarnard)

2) **State**
   - Display current `BarnardState`:
     - `isScanning` (boolean)
     - `isAdvertising` (boolean)
   - Show the most recent `StateEvent.reasonCode` when available.

3) **Events (live)**
   - Subscribe to `BarnardClient.events`.
   - Display a scrollable list of the most recent events, including:
     - DetectionEvent: timestamp, transport, displayId, rssi, and if present rssiSummary
     - ConstraintEvent: code, message (if any)
     - ErrorEvent: code, message, recoverable (if any)
     - StateEvent: isScanning/isAdvertising + reasonCode (if any)

4) **Debug (live + buffer)**
   - Subscribe to `BarnardClient.debugEvents` (push) and display a scrollable timeline.
   - Provide a “Load debug buffer” action that calls `getDebugBuffer(limit: …)` and shows the returned snapshot.

5) **RSSI samples (pull)**
   - Provide a “Load RSSI samples” action that calls `getRssiSamples(since: …, limit: …)`.
   - Show:
     - count
     - a table/list of the returned samples (timestamp, displayId or rpid base64, rssi, transport)

### Secondary flows (simulated constraints/errors)

Because the UX prototype is mock-first, constraint/error behavior may be simulated via UI toggles or mock configuration.

- When a simulated constraint is enabled and the user starts Scan/Advertise/Auto:
  - Emit a `ConstraintEvent` with a clear `code` and an optional `requiredAction`.
  - Ensure the state reflects partial success correctly (e.g., Scan started but Advertise failed).

## Compatibility

- The UX prototype MUST use the existing Dart public API (`BarnardClient`) without requiring breaking changes.
- If API or schema gaps are discovered during UX prototype implementation:
  - Update `specs/001-barnard-core-sdk/spec.md` and/or `schema/barnard/v1/*` first (schema-first).
  - Prefer additive changes (new optional fields) over breaking changes.

## Success criteria (Definition of Done)

- The Flutter UX prototype app is added under `examples/flutter/barnard_ux_prototype`.
- The app runs on:
  - iOS Simulator
  - Android emulator
- From the UI:
  - Start/Stop Auto produces DetectionEvent updates within a few seconds.
  - State UI reflects `isScanning` / `isAdvertising` changes driven by StateEvent.
  - Debug timeline shows debug events, and buffer pull works.
  - RSSI samples pull works and displays reasonable values.
- The app remains responsive for at least 60 seconds of continuous detections.
- UI state is bounded (no unbounded memory growth in lists).
- Documentation exists explaining how to run the UX prototype.
- CI covers the Flutter example with `flutter analyze` and `flutter test` (even minimal).

## End-to-end example (happy path)

1. Launch the Flutter app.
2. Tap “Start Auto”.
3. The “State” section shows:
   - `isScanning = true`
   - `isAdvertising = true`
4. The “Events” list begins to show `DetectionEvent` rows such as:
   - `transport = ble`
   - `displayId = "a1b2c3d4"`
   - `rssi = -63`
   - `rssiSummary.count >= 1`
5. Tap “Load RSSI samples (last 10)”.
6. The RSSI samples view shows 10 rows with recent timestamps.
7. Tap “Stop Auto”.
8. State returns to:
   - `isScanning = false`
   - `isAdvertising = false`
