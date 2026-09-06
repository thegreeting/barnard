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
  exhaustively over `BarnardEvent`**: a Swift `switch` with no `default`, a
  Kotlin `when` used as an expression, and (with Kotlin 2.2.20, the version the
  published Android library uses) a `when` used as a statement with no `else`
  all stop compiling until the new case is handled. Add a branch for the new
  case, or add `default:` / `else ->`, on both platforms. No wire format,
  stored data, or existing event changed, so it is a recompile, not a
  migration. (barnard#186)
- **`BarnardEvent` gains a second case.** `relayDecision` (Swift) /
  `RelayDecision` (Kotlin) is emitted when the spec 134 density controller
  starts, renews, or stops re-broadcasting a relayed envelope. Same
  source-breaking shape as the case above, including the Kotlin 2.2.20
  statement-`when` behaviour, and the same non-migration: no wire format or
  stored data changed. (barnard#187)

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
- The engine drives `BarnardParticipantRelay` (spec 134). Every
  `RADIO_SELF_VERIFIED` receipt from the receive path is fed to a relay
  instance the engine owns, and when the relay elects an envelope the engine
  serves the raw container on B005 with only `relayHopCount` changed — no
  re-encode and no re-signing. Stopping Scan or Advertise clears the lease, the
  density handles, and the cached envelope. (barnard#187)
- `configureParticipantRelay(...)` enables the relay and is off by default.
  It takes a host-supplied `BarnardRelayVerifier`, because spec 134 requires
  agreement with the authoritative on-chain definition before re-broadcast and
  the SDK has no registry access: a `RADIO_SELF_VERIFIED` receipt alone never
  relays. `advanceParticipantRelay()` runs the relay's decisions at a host's
  scheduled wake-up, and `isRelayServing` reports whether this device is
  currently re-broadcasting. (barnard#187)
- Precedence when a device could serve both: this device's own event-info value
  wins over a relayed container. Spec 134 does not settle the collision and
  this is the conservative reading — an organizer-designated direct source must
  keep serving hop zero rather than demote itself to a forwarder. Documented in
  `specs/122-b005-v2-signed-envelope/DESIGN-NOTES.md` §0.2c. (barnard#187)
- An envelope observed at the hop limit is never re-broadcast, and v1
  `eventInfoHint` traffic never reaches the relay. (barnard#187)
- A device with its own event-info value to serve does not relay at all: it
  neither feeds the relay nor holds a lease, so `isRelayServing` and the
  decision events always describe what a peer reading B005 would actually get.
  (barnard#187)
- Relay lease decisions run in `advanceParticipantRelay()`, not on arrival of
  an observation. Spec 134 decides at 30-second boundaries, and deciding on
  arrival would fix each epoch's decision to the density seen at that epoch's
  first arrival, defeating suppression. (barnard#187)
- The engine drives the relay forward on its own timer while one is
  configured, so a lease ends on time even if the host never calls
  `advanceParticipantRelay()` and no peer ever reads B005. The host-callable
  method remains; hosts that call it themselves should do so at least at the
  30-second decision-boundary cadence. (barnard#187)
- Overflow-marker expiry (barnard#181) is untouched by this change: the
  33rd handle in a density window still saturates without being retained, and
  the relay driving inherits whatever #181 settles. (barnard#187)
- `configureOwnEventInfoEnvelopeV2(container:)` (Swift) /
  `configureOwnEventInfoEnvelopeV2(container)` (Kotlin) supplies a
  pre-encoded, pre-signed B005 v2 container the device serves as its own
  event-info value at hop zero, and clears it when passed `nil`/`null`. The
  host builds the container with `BarnardB005EnvelopeV2.encodeContainer` in
  either authority-direct or delegate mode. The SDK does not sign, re-encode,
  or re-verify it, and it never assigns `REGISTRY_VERIFIED`: it checks only
  that the bytes are a well-formed `0x03` container at hop zero, then serves
  them byte for byte. That shape check is
  `BarnardB005EnvelopeV2.validateStructure`, a new public entry point holding
  every clock-independent structural guard, which `verify` now calls first as
  well — so a host cannot serve a container a receiver would refuse on shape.
  A rejected container throws
  `BarnardOwnEnvelopeV2Error` (Swift) / `BarnardOwnEnvelopeV2Exception`
  (Kotlin) and leaves any previously supplied one in place.
  `ownEventInfoEnvelopeV2` reads back what is set. (barnard#189)
- Serving precedence is now own v2 container, then the v1
  `BarnardEventInfoCodec` payload, then a relayed container. With no v2
  container supplied the v1 payload is served exactly as before, so existing
  consumers see no change. A supplied container counts as an own value for the
  relay's election gate as well as the read chooser: supplying one ends any
  lease this device holds, with decision reason `own_value_precedence`, and
  keeps it from observing or electing while it is set. A supplied container is
  not gated on
  `configureEventInfoServing`, and stopping Advertise does not clear it —
  unlike the relay lease, it is host state the engine was handed rather than
  engine-elected state spec 134 requires be rechecked on resume. `leaveEvent`
  does clear it, since a container is signed for one event and leaving is the
  one call that says this device has left it; `joinEvent` and
  `configureEventInfoServing` leave it in place. Documented in
  `specs/122-b005-v2-signed-envelope/DESIGN-NOTES.md` §0.2d. (barnard#189)
