# Changelog

Barnard uses whole-monorepo semantic versions: one `vX.Y.Z` tag identifies the
same protocol semantics across the Swift, Kotlin, Dart, and React Native
packages.

This file records the changes a consumer has to act on — breaking changes above
all. It is not the release notes. The GitHub release for a tag is generated from
PRs, resolved issues, and `specs/` changes by
`.github/workflows/release-notes.yml`; the entries here are the input the release
driver draws the drafted summary from (see `RELEASING.md`).

## Unreleased — 0.8.0

### Breaking

- **`BarnardEvent` gains a case.** `eventInfoEnvelopeV2` (Swift) /
  `EventInfoEnvelopeV2` (Kotlin) is emitted when the engine reads a B005 v2
  signed envelope. This is a **source-breaking change for consumers that switch
  exhaustively over `BarnardEvent`**: a Swift `switch` with no `default` and a
  Kotlin `when` used as an expression both stop compiling until the new case is
  handled. No wire format, stored data, or existing event changed, so it is a
  recompile, not a migration. (barnard#186)

### Added

- The engine verifies B005 v2 signed envelopes on the receive path (spec 122).
  A container whose `formatVersion` is `0x03` is passed to
  `BarnardB005EnvelopeV2.verify` with the engine's current ENIN, and the result
  is emitted with the raw container bytes unchanged and the peer handle.
  Verification failures are surfaced to the host rather than dropped. The
  emitted receipt can only be `UNVERIFIED` or `RADIO_SELF_VERIFIED`; the SDK
  never assigns `REGISTRY_VERIFIED`. (barnard#186)
- The v1 `eventInfoHint` path is unchanged and still handles `formatVersion` 1
  traffic.
