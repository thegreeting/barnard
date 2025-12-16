# Barnard Constitution

Barnard is a “sensing foundation SDK” that aims to provide consistent quality and behavior across multiple clients (Flutter / React Native / iOS / Android).

## Core Principles

### I. Native-Core First

- Implement the essential runtime behavior (Scan/Advertise, constraints, event generation, observability) in native iOS/Android SDKs.
- Flutter / React Native are thin wrappers that expose the same conceptual model and event contract.
- Prefer “behavioral consistency” over framework-specific convenience.

### II. Contract First

- Barnard’s primary deliverable is the **event contract** (main + debug).
- Minimize breaking changes; if necessary, handle them via explicit versioning.
- Do not “hide” unclear behavior (OS differences, permissions, background constraints). Surface decision-useful information to upper layers.

### III. Explicit State Machine

- Define Scan/Advertise states clearly (e.g., `idle / scanning / advertising / error`) and provide state transitions as events.
- Prefer APIs that explain “what state we are in and why” over APIs that only return success/failure.

### IV. Observability without PII

- `debugEvents` must be powerful enough for troubleshooting but must not include secrets, PII, or data that meaningfully increases tracking risk.
- Assume event volume can be high; include sampling/aggregation/bounded buffers in the design.
- Provide debug information as data, not UI (visualization belongs to clients).

### V. Responsibility Boundary

- Barnard’s responsibility ends at sensing (Scan/Advertise) and delivering results/constraints/observability events.
- Domain logic (VC issuance/verification, POAP issuance), server dependencies, and UI are out of scope.

### VI. Simple, Portable, Publishable

- Keep dependencies minimal and prefer standard distribution paths (SPM / Maven / pub.dev / npm).
- Ensure prototype work can evolve into a publishable core by locking in boundaries and contracts early.

## Non-Goals / Constraints

- Barnard does not depend on specific server URLs or API specs (apps implement those).
- Barnard alone does not fully solve adversarial radio attacks (relay/spoofing). Document this as a limitation.
- Do not store or expose secrets such as signing keys.

## Quality Gates / Workflow

- Apply changes in order: spec → plan → tasks → implementation.
- Any change that affects the event contract must be reflected in the spec and validated via a sample or test.
- Review debug events for safety (PII/secrets/tracking risk) and for volume control (rate/buffer bounds).

## Governance

- This constitution is the highest-level rule for Barnard decisions; all specs/plans/implementations must follow it.
- Breaking changes or responsibility changes must be documented in the constitution/spec and accompanied by a migration path.

**Version**: 0.1.0 | **Ratified**: 2025-12-15 | **Last Amended**: 2025-12-15
