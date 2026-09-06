# dispatch#11 — B005 participant relay: design notes

> **Not normative. `specs/122-b005-v2-signed-envelope/spec.md` and
> `test-vectors/b005-envelope-v2.txt` are.** This file is the working record of how that
> specification was arrived at: the constraints found in the code, the options weighed, the
> measurements taken, and the work-package plan. Where a wire-format detail here disagrees with the
> specification, the specification wins — several fields were dropped or resized late (a `threshold`
> field, a signer index, the certificate length width, the signature form), and the two signing
> modes and the ratified three-state receiver policy arrived after most of this was drafted. The
> layout and byte-budget tables below have been synchronised; the surrounding prose may still carry
> earlier phrasing.

# Cross-cutting design

Author: sis-dispatch11 (design lead / lane sub-PM). Untracked working document.
Normative inputs: spec 134 (`specs/134-b005-participant-relay/spec.md`, merged to
`origin/main` as 5dc0b87, verified byte-identical to the proposal branch), spec 113
(`specs/113-event-info-discovery/spec.md`), levarac/barnard#122, #128, thegreeting/beid#367,
levarac/parallax Draft 0007 (PR #36, branch `proposal/facilitator-spec`).

Spec 134's decisions are final and are not reopened here: v2 container, 12-ENIN max relay
lifetime as half-open `[validFromEnin, relayExpiresAtEnin)`, verified-but-unjoined devices may
relay, lowest-hop with 5-minute pin, `k=3`, `T=30s`, hop limit 2, 32-handle dedup cap.

---

## 0. The load-bearing finding

beid's hard requirement (levarac/barnard#122, gajumaru4444, 2026-08-20) is offline verification:

> 照合先が無いまま「照合済み」と表示することは、beid では選択肢に入りません。

Parallax Draft 0007 open question 3 chose the opposite for `DelegationCertV1` — a
**registry-dependent** cert carrying `eventId` only — and rejected the self-contained
alternative "at roughly 85 more bytes against the B005 budget", reasoning that "a device that
has fetched the Event Definition already holds both inputs". A walk-up beid device has not
fetched it. That is the gap this lane closes.

It is closable without touching parallax, because **`eventId` is self-certifying**: it commits
to the authority key set. Draft 0007 says so itself ("embed registrar, anchor operator, nonce
and key set so an offline receiver can recompute `eventId` from the certificate alone"), and
Draft 0007 explicitly leaves the B005 carriage decision to barnard#122 ("Carrying it in a B005
TLV is barnard issue 122's decision").

I verified the chain numerically against parallax's own fixture
(`protocol/vectors/positive/event-definition-v1.json`) before designing against it:

```
keySetBytes   = a3 01 01 02 81 5821 02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9 03 01   (42 B)
keySetDigest  = SHA256("levarac:event-key-set-digest:v1\0" || keySetBytes)
              = cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b700          [matches fixture]
EVENT_ID_DOMAIN = keccak256("levarac:event:v1")
              = 5cc16304b6895101b5572dd83bf7bd81b0531d51eac91759f20cf6f2ab9df630
eventId       = keccak256(EVENT_ID_DOMAIN || zero12||registrar20 || zero12||anchorOperator20 || nonce32 || keySetDigest32)
              = 5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195          [matches fixture]
```

Preimage is exactly 160 bytes. Reproduction script:
`scratchpad/verify_eventid.py` (session scratchpad, not committed).

Consequence: a receiver handed `registrar`, `anchorOperator`, `nonce` and the authority key set can
recompute `eventId` with no network. When that recomputation matches the `eventId` inside the
authority-signed DelegationCert, the key set is cryptographically bound to that event identity, the
cert's signature is checkable against it, and the delegate key it designates is authenticated —
all offline. **A net 75 bytes buys registry-free verification** (72 of preimage plus 35 for a
one-key key set, less the 32 saved by not carrying a redundant `eventId`; see a.3).

---

## 0.0 RESOLVED — the relay container takes `formatVersion 0x03`

**Lead ruling, 2026-09-05:** the relay container takes `0x03`; `0x02` stays with the shipped census
format; a one-line errata to spec 134 records it (separate small PR); reported to Ken as
done-unless-vetoed. The two `eventId` derivations are out of this lane — file a barnard issue
describing the divergence with both derivations and the affected lines, label `spec`, move on. The
relay uses the parallax keccak derivation.

The finding that produced that ruling is kept below, because the vectors and both codecs encode this
byte and anyone reading the spec later will ask why it is not `0x02`.

### The collision (as found and verified)

Found by the design gate, then verified independently against `origin/main` and against the tag.

Two accepted specs assign the same B005 wire byte:

- `specs/123-128-adoption-credential-census/spec.md` (§"B005 format version 2") defines `0x02` as
  `formatVersion` followed by four strictly-increasing TLVs (`0x01` display name, `0x02`
  `b004AdoptionScopeHash`, `0x20` AdoptionCredential, `0x21` SignedWindowCensus), 323–386 bytes.
- Spec 134 (accepted 2026-09-04) defines `0x02` as `[formatVersion, relayHopCount,
  signedEnvelopeLength, signedEnvelope]`.

Neither spec mentions the other. The census version is **not a draft** — it is implemented and
released: `packages/swift/barnard/Sources/Barnard/BarnardAdoptionCensus.swift:424` reads
`public static let formatVersion: UInt8 = 2`, with a Kotlin twin and vectors in
`test-vectors/adoption-census-v1.txt`. I confirmed the same line at
`v0.6.0:packages/swift/barnard/Sources/Barnard/BarnardAdoptionCensus.swift:424` — **the tagged
release beid currently pins**.

The failure mode is mutual rejection rather than silent misparse (a relay container hits the census
parser's TLV rules and fails; the reverse also fails), so nothing is corrupted today. But the byte
is claimed twice, and B005 v2 relay cannot ship on `0x02` without one of the two giving way.

There is a second, related collision in the same spec: for its v2, **B004 carries an opaque
`b004AdoptionScopeHash`, "not an EventCodeHash"**, while spec 134 and this envelope require
`eventCodeHash` to equal the B004 value byte-for-byte. And `specs/123-128…` line 117 defines its own
`eventId = SHA-256(authorityKey)`, which is *not* parallax's keccak derivation — so beid would hold
two different notions of `eventId` depending on which path produced it.

**Recommendation: the relay container takes `0x03`, via a one-line errata to spec 134.** Retiring a
`0x02` that is already tagged, vectored and pinned by a consumer is the more expensive path. This is
a maintainer decision, not mine — it touches a ratified spec — and it is the lane's top blocker,
because every vector and both codecs encode this byte. Everything else in the envelope is
independent of it, so the #122 spec text should stay container-version-agnostic until it is
answered, and implementation of the envelope body need not wait.

## 0.1 One spec-134 clause that cannot be satisfied as written — for the lead

Spec 134 receiver step 4 requires "exact `eventId`, `eventCodeHash`, display-name,
validity-window, and signer-authority agreement with that definition", where "that definition"
is the authoritative on-chain definition obtained in step 3.

`EventDefinitionV1` on parallax **`main`** (`protocol/spec/v0.1/event-definition.md`) has 15
labels: the 13 base labels (`version, eventId, registrar, anchorOperator, nonce, keySetDigest,
sequence, previousDefinitionDigest, receiptPublicKey, operatorId, submissionEndpoint, validFrom,
validUntil`) plus label 14 `joinMode` and label 15 `eventCodeHash`, the additive extension from
parallax proposal 0022.

> Correction to an earlier draft of this document. I first read the definition from the PR branch
> `proposal/facilitator-spec`, which predates proposal 0022, and wrote that `eventCodeHash` was
> absent and its agreement check unsatisfiable. **That was wrong** — `eventCodeHash` is label 15
> on `main` and its check is satisfiable. The claim never left this document. Two of the three
> clauses I flagged do stand, below.

Still absent from the definition: **display name** and any **ENIN window** — `validFrom` and
`validUntil` are Unix seconds, and Draft 0007 explicitly "fixes no relation between an ENIN and
Unix time".

The **validity window is checkable after all**, which I had also called unsatisfiable. Parallax
fixes no ENIN-to-time relation, but *barnard* does: spec 004 defines
`ENIN = floor(unixSeconds / eninSeconds)` (default 300, event-scoped, or beacon-slot mode). Given
the ENIN parameters, the envelope's ENIN window and the definition's Unix-seconds window are
comparable. **But a walk-up device does not know those parameters** — it has not joined, and they
are event-scoped. That gap is closed by carrying `eninSeconds` in the envelope; see a.2.

So of the five agreement checks step 4 demands, `eventId`, `eventCodeHash` and signer-authority are
checkable against the definition, and validity-window becomes checkable once the ENIN parameters
travel with the envelope. **Only display-name is unsatisfiable** — the definition simply has no such
field, so the authority's signature over the envelope is its only possible source.

This is not a defect in the design below — it is a spec/parallax mismatch that the lead should
carry back. The design resolves it the only coherent way: **those three fields are authenticated
by the authority's signature over the envelope**, because the authority is their definitive
source, and the registry read (when available) upgrades `eventId` from self-certified to
registered. No behaviour in this lane depends on the unsatisfiable clauses.

## 0.2 Two verification tiers, and what "verified" is allowed to mean

Self-certifying `eventId` plus a valid signature proves: *whoever controls this event's key set
authored these exact name, hash, and window bytes.* It does **not** prove the event is
registered. A fabricated but fully self-consistent event — attacker generates a key set, derives
an `eventId` from it, signs an envelope — passes every offline check. beid has already retracted
two overclaimed badges, so this residual goes in writing rather than in a footnote.

| Tier | Checks | Available offline | beid may show |
|---|---|---|---|
| `authenticated` | container + envelope structure, recomputed `eventId`, cert verified against the bound key set, delegate signature, both ENIN windows, 12-ENIN lifetime bound | yes | "event-authority signature verified" |
| `registered` | the above **plus** a verified anchored `EventDefinitionV1` for this `eventId` | no (needs network) | full 照合済み |

Two wording points that matter, both from the gate:

- **Do not say "organizer".** Neither tier proves that the signer is an organizer of anything; they
  prove control of the event's authority key set. `EventRegistry.register(operator, nonce,
  keySetDigest)` takes `msg.sender` as registrar with no access control, so **registration is
  permissionless** — an attacker with gas registers a fabricated event as easily as a real one.
  `registered` therefore proves existence and `registeredAt`, not legitimacy, and the gap between
  the two tiers is narrower than it looks. A host wanting "organizer" needs a registrar allowlist,
  which it can apply offline because `registrar` is already in the envelope.
- **`registered` means the anchored definition, not a bare registry read.** A registry-existence
  read is weaker than spec 134 step 3 and does not carry `validFrom`/`validUntil` or, for open
  events, `eventCodeHash`. Use parallax's full `verifyEventDefinition` path.

Relay gates on `authenticated`. Gating on `registered` would disable the feature at exactly the
venues it exists for (spec 134's own rationale: "Venues are exactly where connectivity is worst").
Recomputing `eventId` from the preimage *is* obtaining the authority binding that step 3 exists to
establish — and because the authority key set is **immutable per event** (Draft 0007; EventRegistry
is first-wins on `keySetDigest`), there is no rotation or revocation a registry read could reveal
that the recomputation misses.

**But this is a deviation from ratified MUST text, not merely an assumption.** Spec 134 step 3
requires the receiver to "obtain the authoritative on-chain definition", step 6 says "only then
expose the event to host display or relay APIs", and testable scenario 2 requires that an
*unavailable* on-chain definition yield "no verified display, no relay lease". Offline relay
therefore needs an **errata to spec 134**, not a note in an untracked design file. File it in
parallel; do not block implementation on it, since the wire format is unaffected either way.

Residual to write down: spec 134's default selection prefers the lowest hop, so an attacker radio
serving a self-consistent fake at hop 0 displaces a genuine hop-1 relay on nearby *unjoined*
devices for the five-minute pin. Joined devices are unaffected, and the attacker needs a radio at
the venue — which already lets it consume spec 113's GATT queue — so this is contained rather than
new. Gating on `registered` would not prevent it either, given permissionless registration.

**Status: pending maintainer ruling.** The offline-verification MUST is the lead's recommendation
to Ken; Ken asked for it and the answer is outstanding as of 2026-09-05. This design satisfies it,
and the byte budget in a.3 is reported on that basis.

**Assumption stated, not silently taken:** relay and the "verified" display tier gate on
`authenticated`; `registered` is an additive upgrade beid applies when it has connectivity.

What changes if Ken rules the other way — that offline verification is *not* required: the wire
format does not have to change at all, because the `eventId` preimage and key set are also what
make the cert verifiable without a bundle fetch, and dropping them would save only 75 bytes we are
not short of at n=1. What changes is the *gate*: relay and the verified badge would wait on a
registry read, the feature would stop working at exactly the venues spec 134 names as its purpose
("Venues are exactly where connectivity is worst"), and beid#367 would need rescoping. So the
ruling is about behaviour, not bytes — which is worth telling Ken, because it means implementation
of the codec can start now and is not blocked on the answer.

---

## 0.2b Where the verify call happens, and who owns each receiver state

*Recorded when the engine receive path landed (barnard#186, ships in 0.8.0).*

Until 0.8.0 the verifier was unreachable from the radio path: `BarnardB005EnvelopeV2.verify`
existed and was tested, but `BarnardEngine` only ever parsed a B005 read as a v1 hint. A host
cannot close that gap itself, because a host has no GATT access of its own and so never sees the
container bytes.

**The emission boundary.** The engine dispatches on the first byte of the value it reads from the
B005 event-info characteristic:

- `0x01` — the v1 hint. Unchanged: parsed by `BarnardEventInfoCodec`, gated on B004 agreement, and
  emitted as `eventInfoHint` / `EventInfoHint`.
- `0x03` — a spec 122 v2 signed envelope. The engine calls `verify` itself, with its own current
  ENIN, and emits the new `eventInfoEnvelopeV2` / `EventInfoEnvelopeV2` event carrying the receipt,
  the raw container bytes, and the peer handle. The raw bytes are passed through unaltered because
  spec 134 re-broadcast has to preserve the signature byte for byte.

Every `0x03` container is emitted, verified or not. A failed envelope reaches the host rather than
being dropped, so a host can tell "no v2 peer" from "a v2 peer whose envelope did not check out".
The SDK reports *that* verification failed and not *why*: `verify` returns nothing both for a
malformed container and for a bad signature, and the two are deliberately not distinguished at this
boundary.

**Who owns each state.** The emitted receipt is a two-case sum — `radioSelfVerified(envelope)` or
`unverified` — with `receiverState` derived from it. `REGISTRY_VERIFIED` is therefore not
representable on anything the SDK emits, rather than merely never assigned. That tier belongs to
the host and only after the host has itself performed an authenticated registry read against the
pinned block (§0.2 and spec 122's "Receiver policy"). `BarnardB005EnvelopeV2.registryAgreement`
stays a pure comparison and still never changes a state.

**Retry-budget treatment.** A read that returned a container is a successful GATT attempt, whatever
the verification outcome, and it consumes one of that peer's two session attempts exactly as a
valid v1 hint does. Verification failure is not radio unavailability: marking the peer semantically
unavailable would instead bar every further read of it for the rest of the discovery session,
including one whose envelope becomes valid in a later ENIN.

**Testability.** Neither `CBPeripheral` nor `BluetoothGatt` can be constructed in a unit test, so
the characteristic-read handling was lifted into an internal `processEventInfoValue` on both
engines; the platform callback reduces to that call plus connection teardown. It takes the current
ENIN as a parameter, which the tests need anyway: the vendored conformance envelopes sit at ENIN
~6.0e6 and no wall clock reachable by CI produces one.

Driving the participant relay from these receipts is separate work, tracked in barnard#187; this
boundary only delivers them.

---

## (a) The #122 envelope v2 wire format and verification path

### a.1 Container (fixed by spec 134, restated for makers)

```
off  size  field                   rule
0    1     formatVersion           exactly 0x03  (0x02 belongs to the shipped census format)
1    1     relayHopCount           0 direct; 1..2 relay
2    2     signedEnvelopeLength    big-endian, ends at the value boundary
4    N     signedEnvelope          copied byte-for-byte by relays
```
Total complete value ≤ 512 bytes. Only `relayHopCount` is mutable, and only to
`min(observed hop) + 1`.

### a.2 Signed envelope (this is what #122 defines)

Fixed-offset layout. No TLVs, no unknown-field skipping: the signature covers every byte, so an
ignorable field would be a footgun, and a future shape gets a new `envelopeVersion`. Integers are
unsigned big-endian.

Ratified 2026-09-05: parallax Draft 0007 Q7 makes the `DelegationCertV1` part of the committed
public record, and Q8 was ratified as option (a) — the delegate device signs with its per-event key.
The cert's bytes are fixed by the Draft 0007 CDDL; #122 defines only the framing.

**There are two signing modes** (lead ruling, confirmed 2026-09-05):

| `certLength` | Mode | Envelope signed by | Cert |
|---|---|---|---|
| `0` | authority-direct | `authorityKeys[signerIndex]` | absent |
| `> 0` | delegate | the cert's `delegatePublicKey` | present, byte-identical to the bundle copy |

Authority-direct exists because an organizer-operated beacon needs no delegation to speak for its
own event. It is also what makes the byte budget comfortable: it removes 222 bytes, so the
multi-key limitation in a.3 disappears entirely for that mode. Delegate mode is what a venue or
staff device uses, and there the cert MUST be present and byte-identical — the relay copies the
whole envelope verbatim, so those bytes reach the bundle unchanged and a verifier can compare the
two copies without re-encoding either.

```
off        size   field                 rule
0          1      envelopeVersion       exactly 0x01
1          20     registrar             EVM address, eventId preimage
21         20     anchorOperator        EVM address, eventId preimage
41         32     nonce                 eventId preimage
73         1      authorityKeyCount n   1..8
74         33*n   authorityKeys[n]      compressed secp256k1, strictly ascending, unique
A          1      joinMode              0x00 open, 0x01 gated
A+1        2      eninSeconds           non-zero; fixedLength ENIN mode pinned for envelope v1
A+3        4      validFromEnin
A+7        4      validThroughEnin
A+11       4      relayExpiresAtEnin
A+15       1      maxRelayHops          exactly 0x02
A+16       8      eventCodeHash
A+24       1      displayNameLength L   1..64
A+25       L      eventDisplayName      NFC UTF-8
A+25+L     1      certLength C          0 = authority-direct, > 0 = delegate
A+26+L     C      delegationCert        COSE_Sign1, byte-identical to the bundle copy
A+26+L+C   65     signature             r||s||v, low-S, v in {0,1}
```
where `A = 74 + 33n`, and total envelope length `= 165 + 33n + L + C`.

No `threshold` field (EventKeySetV1 pins it to 1) and no signer index (recovery does not take a
candidate key as input, so membership is tested for free; the certificate signer is identified by
its COSE `kid`).

`eninSeconds` closes a verifier gap that is easy to miss: every ENIN field in this envelope is
meaningless without the event's ENIN parameters, spec 004 makes those **event-scoped**, and a
walk-up device has not joined and therefore does not have them. Without this field a receiver can
only assume the 300-second default — which happens to be what beid runs today, so the bug would
hide until the first event that configures something else. Two bytes buys the check instead. ENIN
mode is pinned to `fixedLength` for envelope v1; a beacon-slot event needs envelope v2.

**There is deliberately no `eventId` field.** In both modes the receiver *computes* it from
`registrar`/`anchorOperator`/`nonce`/`keySetDigest`; that computation is its definition, not a claim
to be checked. In delegate mode the cert also carries `eventId`, and the two must agree — that
agreement is what ties the cert to this body. A plaintext copy in the envelope would be 32 redundant
bytes a verifier has to compare anyway, and as a.3 shows those 32 bytes are the difference between
fitting and not fitting in delegate mode.

Everything from offset 0 up to (excluding) `signature` is the to-be-signed region (`tbs`), so the
delegate's signature covers the cert bytes too — that is what binds this cert to this body and
stops a valid cert for event X being pasted onto a body for event Y.

```
sigDigest = SHA256("barnard:b005-event-info:v1\0" || tbs)
signature = ECDSA-secp256k1(sigDigest) by the cert's delegatePublicKey, low-S, compact 64 B
```

Domain separation follows parallax's convention (colon-separated, NUL-terminated).
`authoritySignerIndex` bounds cert-verification cost to one recovery instead of `n`, which matters
because CLAUDE.md records barnard's BigInteger secp256k1 math as ~9x slower at `-Onone`.

`joinMode` is carried because it gates the free binding in a.4 step 5b, and because beid's shipped
v1.0 rule already refuses to join anything that is not `joinMode = open`. An `unspecified`
join mode has no encoding here: a definition that does not state one is not open-discoverable, so
it must not be broadcast as a relayable envelope at all.

### a.3 Byte budget against the real limits — measured, and it is now tight

The cert size is measured, not estimated: parallax's positive vector
`protocol/vectors/positive/delegation-cert-v1.json` has `signedDelegationCertHex` at
**C = 222 bytes** (payload 88, `Sig_structure` 166, compact signature 64).

Envelope length is `165 + 33n + L + C`. Caps: envelope ≤ 508, complete container ≤ 512.

**Delegate mode** (`C = 222`) is the tight one:

| Case | Envelope | Container | Against 508 |
|---|---:|---:|---|
| n=1, L=64 (max display name) | **484** | 488 | fits, 24 spare |
| n=1, L=18 (spec 113 Vector 1) | **438** | 442 | measured, vector 2 |
| n=2, L=64 | **517** | 521 | **over by 9** |
| n=2, L=55 | 508 | 512 | exactly at the cap |

**Authority-direct mode** (`C = 0`) has room to spare:

| Case | Envelope | Container | Against 508 |
|---|---:|---:|---|
| n=1, L=64 | 262 | 266 | fits, 246 spare |
| n=1, L=58 | **256** | 260 | measured, vector 1 |
| n=8, L=64 | 493 | 497 | fits, 15 spare |

So the multi-key limitation is **mode-specific**, which is worth stating precisely rather than as a
blanket restriction: authority-direct supports up to eight authority keys at full display-name
length; delegate mode supports exactly one, because a 222-byte cert plus a second 33-byte key
overruns by 11. `authorityKeyCount` is therefore specified as `1..8`, with the length arithmetic
rejecting whatever does not fit — no separate rule needed.

The effective **minimum** envelope is 199 bytes (direct, n=1, L=1); the smallest delegate-mode
envelope is 421. Either way spec 134's stated `signedEnvelopeLength` range of `1..508` is far wider
than this format can produce, so the #122 spec states the real floor rather than inheriting it.

Two things follow, and both are reportable facts rather than choices I made quietly.

1. **It fits only because the redundant `eventId` copy is gone.** Carrying it costs 32 bytes and
   the worst case becomes 516 — over the 508 envelope cap by 8. Reading `eventId` from the signed
   cert instead is what buys the fit, and it is also the stronger construction.
2. **v1 supports exactly one authority key at full display-name length.** A two-key key set needs
   a display name of 55 bytes or less; four keys do not fit at all. `EventKeySetV1` allows a
   non-empty sorted array with threshold 1, so multi-key sets are legal in parallax and simply do
   not fit through a 512-byte GATT value alongside a 222-byte cert.

Per the lead's instruction I am **not** dropping fields to make room. The lane's assumption is
n=1, stated here and in the brief; if real events use multi-key authority sets, the choices are a
shorter display-name cap for those events, a smaller cert profile in parallax, or moving event-info
to a second characteristic — all of which touch ratified decisions and are the lead's to escalate.

The #82 census headroom that spec 113 reserved TLV `0x10` for is now **gone** in the v2 container.
That is a real consequence of the Q7 ruling and worth recording: census can no longer ride the same
value, which is consistent with barnard#128's own scope note that prevalence lives in the signed
per-window census, not in B005.

### a.4 Verification path (receiver, in order)

Steps 1–7 are offline and produce tier `authenticated`. Step 8 is the online upgrade.

1. Container: `formatVersion == 0x02`; total ≤ 512; `signedEnvelopeLength` ends exactly at the
   value boundary; `relayHopCount` ≤ 2.
2. Envelope structure: `envelopeVersion == 0x01`; `n` in 1..4; keys strictly ascending and each a
   valid compressed secp256k1 point; `threshold == 0x01`; `maxRelayHops == 0x02`; `L` in 1..64;
   `authoritySignerIndex < n`; `C` within the remaining bytes; length arithmetic lands exactly on
   the envelope boundary.
3. Display name: valid UTF-8, NFC, no forbidden controls. (Reject, do not sanitise.)
4. `keySetBytes = A3 01 01 02 (0x80|n) (58 21 key)*n 03 01`;
   `keySetDigest = SHA256("levarac:event-key-set-digest:v1\0" || keySetBytes)`.
5. `computedEventId = keccak256(keccak256("levarac:event:v1") || zero12||registrar ||
   zero12||anchorOperator || nonce || keySetDigest)`.
   **This is the self-certification step. It replaces the registry read for authority binding.**
5a. **Authority-direct mode (`C = 0`):** there is no cert. `eventId` is the value computed in
   step 5, and the envelope signer is `authorityKeys[signerIndex]`. Skip to 5b.
   **Delegate mode (`C > 0`):** decode the `delegationCert` COSE_Sign1 per the Draft 0007 CDDL: the six
   labels, `version == 1`, `delegatePublicKey` a valid compressed point, `roles` non-zero with no
   unassigned bit, `eninStart <= eninEnd`. Verify its COSE signature against
   `authorityKeys[authoritySignerIndex]` (recover-and-compare, as in step 6). Then require
   `cert.eventId == computedEventId` — this is where the recomputed identity and the
   authority-signed identity are tied together, and it is the only place `eventId` enters. Require
   `cert.eninStart <= currentEnin <= cert.eninEnd` (inclusive, per Draft 0007) in addition to the
   event window in step 7: a cert whose delegation window has lapsed cannot serve, even inside a
   still-valid event.
5b. If `joinMode == open`, require
   `eventCodeHash == SHA256(UTF8(lowercaseHex(eventId)))[0:8]`, where `lowercaseHex` is 64
   lowercase hex characters with no `0x` and leading zeroes preserved (parallax `openCodeV1`).
   This is free — no extra bytes, one SHA-256 — and it binds the advertised hash to the
   self-certified `eventId`, so a "genuine hash, fabricated everything else" envelope cannot
   pass. If `joinMode == gated`, `eventCodeHash` is **not** derivable and this check is skipped:
   parallax forbids publishing a digest of a human-memorable gated code because it enables an
   offline dictionary attack. Reject any other `joinMode`.
6. Verify `signature` over `SHA256(domain || tbs)` against the mode's signing key —
   `authorityKeys[signerIndex]` in authority-direct mode, the cert's `delegatePublicKey` in
   delegate mode. In delegate mode, because
   `tbs` spans the cert bytes, this is what binds *this* cert to *this* body — a valid cert for
   event X cannot be pasted onto a body for event Y, since the delegate signature would not
   verify over the spliced bytes and the delegate for Y would have to hold X's key.
   Barnard has **no classic `verify(pubkey, digest, sig)` primitive** on either platform — both
   sides do recover-and-compare (`signRecoverable` / `recoverPublicKey`, libsecp256k1 or the
   pure-Swift fallback on Swift, BouncyCastle on Kotlin). So: recover with recovery id 0, then 1,
   and accept if either recovers to the expected key byte-for-byte. That is at most two recoveries
   per signature, which is why `authoritySignerIndex` earns its byte in step 5a — without it the
   cert check alone would cost `2n`. Require low-S on both signatures: reject the malleable high-S
   counterpart rather than normalising it, otherwise the same logical signature has two encodings
   and the payload digest (and therefore dedup) splits.
7. ENIN window: `validFromEnin <= currentEnin < relayExpiresAtEnin <= validThroughEnin` and
   `relayExpiresAtEnin - validFromEnin <= 12`. If ENIN cannot be established, **fail closed**:
   no relay, no verified display.
8. *(online, optional)* `EventRegistry` read for `eventId`; require agreement on `keySetDigest`
   and the registration. Success upgrades the tier to `registered`.

Steps 1–3 must complete before any allocation beyond the 512-byte cap, per spec 113's parser
bound. `eventCodeHash` is cross-checked against B004 only when the host holds a code; a mismatch
prevents serving locally (spec 113 serve policy) but is not a receiver-side rejection.

### a.5 The DelegationCert in delegate mode, and its role bit

The Q7 ruling settles carriage: the cert rides in the envelope, byte-identical to the copy that
will appear in ObservationBundle v2. Byte-identical is the operative word — the relay copies the
whole envelope verbatim anyway, so the cert bytes survive unchanged from the signer to the bundle,
and a verifier can compare the two copies for equality without re-encoding either. Any
canonicalisation on barnard's side would break that, so the codec must treat the cert as an opaque
byte range: parse it for its fields, never re-serialise it.

**The unresolved piece is which role bit authorises signing event-info.** Draft 0007 assigns
exactly one bit, `anchor` (bit 0), defined as "the delegate key is organizer-designated anchor
evidence for the Observations the certificate covers" — a statement about that key's *Observations*,
not about broadcasting event-info. Draft 0007 also records that a `BROADCAST_DYNAMIC` bit was
"considered and rejected" for v1, with the reasoning that barnard#122 owns its semantics. So a
device verifying a B005 v2 envelope has no bit that means "may sign this". Its options are:

- accept `anchor` as sufficient, which silently widens a ratified role definition; or
- require a new bit, which barnard cannot assign — parallax must, and I was told not to change it.

**Resolved by the lead, 2026-09-05:** the `anchor` bit also authorises signing the B005 event-info
envelope — an anchor is by definition an organizer-placed device, and broadcasting event info is
what such a device does. That sentence goes into Draft 0007 decision 5 in the parallax PR, so the
widening is recorded in parallax rather than assumed in barnard. v1 therefore requires
`roles & anchor != 0` and rejects a cert with no assigned bit set.

Authority-direct mode sidesteps the question entirely: no cert, no role bit, and the authority
signing for its own event needs no delegation to do so.

### a.6 Parallax items to flag (do not fix here)

1. **Stands.** `EventDefinitionV1` carries no display name and no ENIN window, so two of spec 134
   step 4's five agreement checks have nothing to compare against. (§0.1)
2. **Stands, and is now more acute.** No `DelegationCertV1` role bit means "may sign event-info",
   yet the cert is now mandatory in the envelope. Needs a parallax decision. (§a.5)
3. **Resolved by the Q7/Q3 rulings** — recorded only so the history is legible. Draft 0007 open
   question 3 had chosen a registry-dependent cert whose stated reason ("a device that has fetched
   the Event Definition already holds both inputs") does not hold for a walk-up device. Carrying
   the `eventId` preimage in the envelope fixes it without changing the cert. Draft 0007's own
   estimate for that alternative was "roughly 85 more bytes"; measured here it is 72 bytes of
   preimage plus 35 for a one-key key set, minus the 32 bytes saved by dropping the redundant
   `eventId` — a net 75. Worth feeding back so the Draft's cost note matches reality.
4. **New.** With a 222-byte cert mandatory, a multi-key `EventKeySetV1` does not fit through a
   512-byte GATT value at full display-name length (§a.3). Parallax permits multi-key sets; B005
   v2 v1 effectively does not. Someone should own that gap.

---

## (b) Relay state machine — pure, platform-independent

All of this lives in the stdlib-only core (`BarnardCore` and its Kotlin twin) and is driven by
injected time, randomness, and signature verification so it is fully deterministic under test.

### b.1 Injected boundaries (the whole platform surface of the core)

```
EnvelopeVerifier   verify(keyCompressed33, digest32, signature64) -> Bool
Sha256             hash(bytes) -> [UInt8; 32]
Keccak256          hash(bytes) -> [UInt8; 32]          // exists on Swift, BouncyCastle on Android
Clock              currentEnin(eninSeconds) -> UInt32?  // nil = unestablished, fail closed
RandomSource       draw(digest, decisionEpoch) -> UInt32   // per-install secret, never on wire
HostState          joinedEventId() -> [UInt8;32]?      // selection rule 1 needs it
                   peripheralAvailable() -> Bool       // eligibility needs it
```

`joinedEventId` and `peripheralAvailable` are part of the boundary because spec 134's selection
policy prefers "the verified, unexpired envelope for the device's joined event" and its eligibility
rule requires "Peripheral operation is available". Without both injected, neither rule is testable
and the core would have to reach for platform state.

Making the verifier an injected interface lets the parser, dedup, and density logic be tested
against a stub with golden vectors before the real secp256k1 backend is wired, and keeps the core
independent of where secp256k1 actually lives on each platform.

### b.2 State (bounded, per spec 134)

```
selected: {
  digest: [UInt8;32]          // SHA256(signedEnvelope), local only
  envelope: [UInt8]           // exactly one, <= 508 B
  minHop: UInt8               // smallest valid hop observed
  verifiedAt: MonotonicTick   // tie-break
  pinnedUntil: MonotonicTick  // 5-minute selection pin
  relayExpiresAtEnin: UInt32
}?
densityHandles: BoundedSet<PeerHandle>   // cap 32, trailing T=30s, hop-positive sources only
lease: { activeUntil: MonotonicTick }?
epoch: UInt32                            // 30-second decision boundary counter
```

One selected digest at a time. `densityHandles` beyond 32 saturate `r >= k` without being
retained — saturation is the *correct* behaviour, not an overflow error, because a full set means
a dense neighborhood and suppression is the desired outcome.

### b.3 Transitions

**On observation** (verified envelope, hop `h`):
- digest differs from `selected` and no pin is active → run selection policy (spec 134: joined
  event first; else lowest hop; else earliest verification; else lexicographically smallest
  digest). A switch MUST stop old serving before starting new serving.
- digest equals `selected` → `minHop = min(minHop, h)`; if `h > 0`, record the peer handle in
  `densityHandles`. Duplicates refresh the density entry **only**: they must not duplicate
  envelope bytes, extend expiry, reset selection, or create hints.
- `h >= 2` → displayable after verification, never forwarded.

**At each 30-second boundary**, with `r` = distinct hop-positive sources in the trailing `T`:
- inactive, `r >= k` → stay silent
- inactive, `r < k` → enter with `pEnter = (k - r) / k`
- active → keep with `pKeep = min(1, k / (r + 1))`
- a positive decision waits a uniform `0..T/2` contention delay, keeps scanning, and starts or
  renews Advertise **only if `r < k` still holds at the end of the delay**
- lease is 30 s; renewal requires a fresh decision; a single missed packet must not stop and
  restart Advertise within one epoch

Randomness is drawn from the per-install secret plus payload digest plus decision epoch, so two
devices do not correlate and the secret never goes on wire.

**Teardown** — when `currentEnin` reaches `relayExpiresAtEnin`, on definition invalidation, on
signature failure, or when the host stops Scan/Advertise: stop new B005 reads, clear lease and
density handles, delete the cached envelope. Resume rechecks every guard; it never restores an old
lease.

### b.4 Hop output rule

Serve `relayHopCount = minHop + 1`, and only while `minHop < 2`. The header is unsigned congestion
control: it must not affect trust, prevalence, or admission anywhere in the code. An attacker
resetting it is expected and harmless; signed expiry is the adversary-resistant boundary.

### b.5 What the core must never expose

`r`, peer handles, and the election secret never leave the density controller — not through a
public API, not through a debug surface, not through a log. This is the count-inflation boundary
that barnard#128 comment 7 (gajumaru4444, 2026-09-04) draws explicitly, and the reason
`BarnardEventInfoHintEvent.peripheralId` must not become a prevalence signal: it does not survive
ENIN rotation, so counting it inflates in proportion to dwell time. Prevalence lives in the signed
per-window census (`specs/123-128-adoption-credential-census/spec.md`), not here.

### b.6 Conformance vectors

Shared fixtures in the repo-root `test-vectors/` directory, loaded byte-identically by Swift and
Kotlin. **The format is the existing plain-text `key=value` one, not JSON** — UTF-8, LF-only,
`#` and blank lines are comments, keys match `[A-Za-z0-9_]+`, hex is lowercase without `0x`
(`test-vectors/README.md`). Follow `secp256k1-ecdsa-v1.txt` as the model. The loaders already
exist and are reused, not rewritten: Swift `findTestVectorsDirectory` / `parseVectorFile` in
`Tests/BarnardCoreTests/BarnardOwnerKeyConformanceVectorTests.swift`, Kotlin `findRepoRoot` /
`parseVectors` in `src/test/kotlin/org/levarac/barnard/BarnardOwnerKeyConformanceVectorTest.kt`.

Four families, mapping 1:1 onto spec 134's testable scenarios 1–4:

1. **`envelope-v2-positive`** — the cross-repo anchor. Reproduces the parallax fixture's
   `eventId 5d5891b9…3195` from `registrar/anchorOperator/nonce/keySet`, then a full envelope and
   container built on it. This single vector pins interop; everything else is internal.
2. **`envelope-v2-negative`** — one entry per rejection: every structural bound, non-ascending
   keys, `threshold != 1`, `maxRelayHops != 2`, bad `signerIndex`, high-S signature, single-byte
   flips in each signed field and in the signature, non-NFC name, forbidden control character,
   `eventId` that does not match its preimage, lifetime > 12 ENIN, and each ENIN boundary
   (`validFromEnin - 1`, `relayExpiresAtEnin - 1` accept, `relayExpiresAtEnin` reject).
3. **`relay-hop-dedup`** — same envelope at hops 0/1/2 from duplicate and distinct handles;
   asserts one stored envelope, byte identity, minimum-hop retention, hop-1-from-0, hop-2-from-1,
   no output from hop 2.
4. **`density-decisions`** — deterministic random fixtures over `r = 0,1,2,3,4`, contention
   cancellation, lease renewal, 33 handles, two competing valid events, selection expiry.

Signature fixtures are **verify-only**: they carry pre-signed bytes, so libsecp256k1's
RFC 6979 determinism and BouncyCastle's non-deterministic default never have to agree. If barnard
later exposes signing, it mandates RFC 6979 + low-S on both platforms and vectors the output;
until then signing stays outside the SDK, mirroring Draft 0007's external-signer boundary.

---

## 0.3 The real-device duty cannot be discharged by the existing lab

Spec 134 requires two real multi-device scenarios and states plainly: "Unit, simulator, and
mock-Transport tests do not replace the two real multi-device scenarios."

- **Scenario 5** wants "at least five physical BLE devices with one direct source", a dense
  neighborhood settling near `k = 3`, and edge devices entering when relays are removed.
- **Scenario 6** wants "Swift and Android in both Central and Peripheral roles", iOS moved
  between foreground and background, ENIN rotation, and Bluetooth restart.

The device lab (Mac Studio `emi`) has **two** Android phones — Galaxy S7 edge (SC-02H, Android
8.0) and Nexus 5X (bullhead, Android 8.1) — and **no iOS device**. It runs a two-device
advertiser/scanner loop, reporting to commit status `device-lab/two-device-loop`.

So with today's hardware: scenario 5 is not runnable at all (2 of ≥5 devices, and density
behaviour at `k=3` is not observable with two radios), and scenario 6 is runnable only for the
Android↔Android half, with no iOS role and no foreground/background transitions.

This does not block implementation, and it does not block the unit and vector work, which is the
bulk of the lane. It blocks **spec 134's own definition of done**. Three options, all Ken's call:
procure three more Android devices plus at least one iOS device; accept a documented partial
discharge (Android two-device propagation proven, density and iOS lifecycle deferred with the
gap recorded on the issue); or split the real-device duty into a follow-up issue so #128 can
close on unit plus two-device evidence. Recommendation: the third, with the gap written on #128
rather than left implicit — the two-device hop-1 propagation test that #128's "Done when" names
*is* runnable today, and it matches beid#367's own acceptance criterion (two devices, hop 1), so
the lane's honest claim and the consumer's requirement line up.

Two conditions on that split, from the design gate, and they are not optional. Spec 134 says
unit and mock tests "do not replace" scenarios 5 and 6, and its Decision 5 keeps `k = 3`, `T = 30 s`,
the two-hop limit and the 32-handle cap **provisional** — "bounded starting values that the required
real-device tests validate before any constant is made permanent". So the follow-up issue is
**release-blocking for the feature**, not a nice-to-have, and those four constants ship marked
provisional. Scenario 6's Android-to-Android half — ENIN rotation, expiry, Bluetooth restart — is
runnable on the current lab today and stays in scope rather than moving to the follow-up.

## (c) Platform glue per OS

### c.1 Swift — a real boundary already exists, use it

`packages/swift/barnard/Sources/BarnardCore/` is stdlib-only and CI-enforced:
`.github/workflows/native-sdk.yml:59-67` builds `BarnardCore` and `BarnardCoreC`, then greps both
source directories for `Foundation|FoundationEssentials|CryptoKit|CoreBluetooth|Security|UIKit|
CommonCrypto|SecRandom|UserDefaults|Data|Date|CCCrypt` and fails on any hit. The grep is
word-boundary matched, so a type or variable named `Data` or `Date` also trips it — new core code
uses `[UInt8]` and `Int64` seconds throughout.

Everything the envelope and relay logic need is already reachable from the pure core:
`BarnardCoreCrypto.sha256(_: [UInt8]) -> [UInt8]`, and secp256k1 via
`BarnardCoreSigning.signRecoverable` / `recoverPublicKey`, which dispatch `#if BARNARD_LIBSECP256K1`
to the vendored C target `CSecp256k1` and otherwise to the from-scratch `BarnardCoreSecp256k1`
(the Linux path). Only keccak-256 is missing.

Platform layer `Sources/Barnard/` keeps GATT, `CoreBluetooth`, and the public façade. The relay's
Scan/Advertise and B005 reads **share** the existing bounded machinery rather than adding a second
one — `BarnardEngine.swift` already has `connectQueue`, `maxConnectQueue = 20`, and
`cooldownPerPeerSeconds = 10`, which are exactly spec 113's required limits and which spec 134
requires relay to reuse.

### c.2 Android — the boundary does not exist, and that is the main platform risk

`packages/android/barnard/src/main/kotlin/org/levarac/barnard/` is one flat Gradle module with no
pure-core equivalent and **no purity check anywhere in CI**. Crypto, signing and the BLE engine sit
side by side. SHA-256 is `java.security.MessageDigest` and secp256k1 is BouncyCastle
(`bcprov-jdk15to18:1.81`) — both JDK/library APIs rather than `android.*`, so they are
*incidentally* portable, but nothing enforces that and nothing stops the next edit from importing
`android.content.Context` into the middle of the relay state machine.

Two options, and I recommend the cheap one:

- **Recommended:** keep the new pure logic in clearly named new files and add
  `scripts/check-kotlin-core-purity.sh` — a file-scoped grep mirroring the Swift one, over a
  declared list, wired into the Android CI job. This matches how the repo already does invariants
  (`check-swift-mirror.sh`, `check-android-mirror.sh`, `check-schema-privacy-invariant.py`), costs
  one small script, and gives the Swift/Kotlin parity claim actual teeth.
- **Rejected:** extracting a new Gradle module. It is the architecturally correct answer and it is
  scope creep against a lane that is meant to ship relay, not restructure the Android package.

**This is a lead/Ken call, not mine to take silently.** If the answer is "no new CI check", the
design still works; the parity guarantee just rests on review rather than on the build.

### c.3 Mirror sync — mostly avoidable, and makers must know why

`scripts/mirror-manifest.sh` mirrors only *native → Dart plugin* (13 Swift pairs, 6 Kotlin files);
it does **not** compare Swift to Kotlin. Swift/Kotlin parity is held only by shared
`test-vectors/*.txt` plus hand-written parallel tests, which is precisely why every new primitive
needs a vector file entry and a test on each platform.

`BarnardEventInfo.{swift,kt}` and `BarnardAdoptionCensus.{swift,kt}` are **absent** from the
manifest. So new B005 v2 code in new files needs no mirror work at all. The trap: `BarnardCore/
BarnardCoreSigning.swift` **is** mirrored. Any maker who edits a mirrored file must run
`./scripts/sync-mirrors.sh` and must never hand-edit the Dart copy. Every maker prompt below
repeats this.

### c.4 ENIN and failing closed

Use `BarnardCoreCrypto.calculateEnin(unixSeconds:mode:eninSeconds:beaconChain:)` (default
`eninSeconds = 300`). For reads, `BarnardCoreCrypto.stableReadEnin(startedAt:completedAt:...)`
returns `nil` when a GATT read straddled an ENIN boundary — that `nil` is the fail-closed hook
spec 134 step 5 demands: no relay, no verified display. There is no clock-skew or NTP machinery in
the repo and this design adds none; unestablished time simply fails closed.

### c.5 Prior art to follow, not to reuse

`BarnardAdoptionCensus.{swift,kt}` already contains a complete, tested relay cache with exact-bytes
duplicate detection, TTL/window pruning and equivocation handling (`BarnardCensusRelayCache`,
`record`, `relayDisposition`, `prune`), specified by `specs/123-128-adoption-credential-census/`.
It is **not wired to either engine** and it keys on the census 5-tuple
`(credentialId, censusDomainId, authorityPolicyEpoch, censusAuthorityKeyHash, windowIndex)`, not on
a payload digest. Makers should read it as the house pattern for cache shape, bounded state and
test structure, and must **not** try to force the B005 digest key into it. Its contract tests
(`BarnardAdoptionCensusContractTests.swift`, `BarnardAdoptionCensusContractTest.kt`) are the
template for P3's tests.

---

## (d) beid consumer wiring

Tracked by thegreeting/beid#367 (「参加者端末で B005 のイベント情報を再発信する」, open, milestone
**U1 開くだけで参加が始まる**, parent levarac/dispatch#11), which is explicitly blocked on barnard#128
and barnard#122 — this lane unblocks it.

### d.1 What already exists

beid consumes barnard **0.6.0** on both platforms: SPM pin `Package.resolved`
(`"identity":"barnard"`, revision `ef661cfb…`, version `0.6.0`, products `Barnard` + `BarnardCore`)
and Gradle `android/app/build.gradle.kts:95` `implementation("org.levarac:barnard:0.6.0")`, with a
CI provenance check (`scripts/check_barnard_dependency_provenance.py`) asserting nothing shadowed
the resolved version. `android/README.md` still documents `0.3.0` — a stale doc, worth a one-line
fix but not this lane's job.

Ingestion is already relay-shaped: `shared/…/parallax/discovery/NearbyEventDiscovery.kt` aggregates
per event-code-hash into `NearbyEventCandidate` with a set of `NearbyEventSourceObservation`, and
`…/beid/shared/event/EventInfoStore.kt` "annotates, never filters" with a 32-entry cap matching
barnard's own. **A relayed hint is just another source observation folded into the same candidate**
— beid#367's own acceptance says relayed candidates render on the same card. No new UI surface.

### d.2 The one type change that matters

`NearbyEventTrustStatus` is today a single-value enum: `UNAUTHENTICATED_B005_HINT`. Registry state
lives on a separate axis, `NearbyEventRegistryStatus`
(`UNRESOLVED / LOOKUP_UNAVAILABLE / NOT_REGISTERED / REGISTERED_VIA_OPERATOR_LOOKUP`).

That two-axis split is exactly right for §0.2's two tiers and should be preserved, not collapsed:
add `AUTHENTICATED_OFFLINE` to the **trust** axis (envelope signature verified, `eventId`
self-certified, window valid) and leave the **registry** axis alone. A card is fully 照合済み only
when both axes are satisfied. Collapsing them into one "verified" boolean is how the two prior
retracted badges happened.

### d.3 Where the UI touches are

- Android: `android/app/…/ui/screens/EventJoinScreen.kt`, composable `NearbyEventCards` (~:325);
  cards are `selectable`, joinable only when `eventIdHex != null`, `onJoin` →
  `EventJoinViewModel::joinNearbyEvent` → `EventJoinSession.joinNearbyEvent(eventIdHex)`. Landed as
  PR #362.
- iOS: `ios/Beid/Views/EventFoundView.swift` + `EventCardView.swift`. The iOS card screen for the
  2026-09-03 v1.0 scheme has **not** landed yet. Note `EventCardView.Badge` deliberately dropped its
  `VERIFYING`/`VERIFIED` cases, and `RecordDetailScreen.kt:78-79` carries a standing comment that an
  unbacked "Verified" claim has already had to be removed from this product twice. **Do not
  reintroduce a verified badge without both axes in d.2 backing it.**
- Settings/About needs a line disclosing that the device relays, and relaying must stop when
  sensing stops or Bluetooth permission is denied (beid#367 acceptance).

### d.4 The v1.0 ruling this must not contradict

A 2026-09-03 maintainer ruling redefined beid#141 for v1.0/ETHTokyo and supersedes its original
requirements: census is unavailable in v1.0 and **barnard#128 is v2.0 scope**; open events use
`code = lowercaseHex(eventId)`; a verified card requires an authority-signed definition with
`joinMode = open` and a client-recomputed `SHA256(lowercaseHex(eventId))[0:8]` matching the heard
hash; **zero-tap is explicitly dropped** in favour of one explicit tap; out-of-range or unverified
candidates are display-only, not joinable.

Two consequences for this lane. First, the offline path designed here is an **addition to a shipped
online path**, not a replacement — which is why d.2 keeps the axes separate. Second, since #128 is
v2.0 scope on the beid side, the beid wiring package should be sequenced last and may legitimately
land after the barnard release; it must not become the thing that blocks barnard from shipping.

### d.5 beid has no two-device BLE test yet

`docs/device-lab-android-harness.md` is explicit: the only thing at target `:app:deviceLabBleTest`
is `DeviceLabBleSuiteNotImplementedTest.kt`, a sentinel that always fails so an empty run cannot be
mistaken for a pass. Central/peripheral role assignment across two devices does not exist. beid#367's
acceptance criterion ("2-device device-lab scenario, hop = 1") therefore requires **building that
harness first**, and no iOS two-device harness exists at all (the simulator has no BLE radio).
Combined with §0.3, this is the second half of the same hardware/harness gap.

---

## (e) Work packages, in dependency order

Conventions every package inherits (repeated in each maker prompt): Conventional Commits
(`<type>(<scope>): <summary>`, imperative, no trailing period); branch `<type>/<topic>` matching
actual repo practice; **TDD — failing test first, then implementation**; barnard PR bodies in
English, beid PR bodies in Japanese; `Closes #N` in the body for the primary issue and `Refs #N`
for supporting ones; the pre-merge comment must state `Development link: done`; **Draft PR only —
makers never merge, tag or release**.

| # | Package | Repo | Branch | Model | Depends on |
|---|---|---|---|---|---|
| P0 | #122 spec + golden vectors | barnard | `docs/issue-122-b005-v2-envelope-spec` | sis (me) | — |
| P1 | Event-identity primitives + bounded CBOR/COSE reader | barnard | `feat/issue-122-event-identity-primitives` | codex gpt-5.6-luna, max | P0 |
| P2 | Envelope v2 codec + verifier, both platforms | barnard | `feat/issue-122-envelope-v2-codec` | codex gpt-5.6-luna, max | P1 |
| P3 | Relay state machine, pure, both platforms | barnard | `feat/issue-128-relay-state-machine` | codex gpt-5.6-luna, max | P2 |
| P4 | B005 v2 GATT + engine wiring, both platforms | barnard | `feat/issue-128-b005-v2-engine-wiring` | codex gpt-5.6-luna, max | P3 |
| P5 | Release cut + beid pin bump | barnard / beid | — | lead (not a maker) | P4 |
| P6 | beid ingestion, trust axis, UI, disclosure | beid | `feat/issue-367-b005-relay-consumer` | codex gpt-5.6-luna, max | P5 |
| P7 | beid two-device device-lab harness | beid | `test/issue-367-device-lab-ble-harness` | agy gemini-3.8-flash, high | P6, hardware |

P1 is first because its headline vector is **cross-repo**, which pins interop before anything is
built on top. It is *not* the small package it first looked like: keccak already exists in Swift
`BarnardCore` and BouncyCastle covers Android, so the real work is the bounded deterministic-CBOR
reader and the COSE `Sig_structure` builder — a strict parser that must reject non-minimal integers,
indefinite lengths, duplicate and out-of-order keys, and trailing bytes. That is the same
byte-exact-and-subtle profile as P2, which is why it is assigned to codex rather than agy.

### P0 — #122 spec and golden vectors *(I write this, not a maker)*

Produce `specs/122-b005-v2-signed-envelope/spec.md` fixing everything in (a): container restatement,
the exact envelope layout, the verification order including step 5b, the two trust tiers, the
`joinMode` rule, low-S, and recover-and-compare. Produce `test-vectors/b005-envelope-v2.txt` in the
existing `key=value` format, including the cross-repo `eventId` reproduction, one full positive
envelope and container, and the negative corpus. Update issue #122 from "backlog, no adoption
decision" to adopted-and-specified, and record the two parallax mismatches (§a.6) as comments there.
Spec 134 states plainly that "Until those are fixed, a B005 v2 implementation is blocked" — so this
is genuinely first, and it is issue-management-first per Ken's standing rule for this lane.

**Done when:** spec file merged; vectors file present and independently recomputable; #122 records
the adopted layout; the lead has the parallax mismatches to relay.

### P1 — event-identity primitives and the bounded CBOR/COSE reader

> **Maker prompt.** Repo: `levarac/barnard`, branch from `origin/main` as
> `feat/issue-122-event-identity-primitives`. Read `specs/122-b005-v2-signed-envelope/spec.md`
> first; it is normative and complete.
> **Check what already exists before writing anything.** Swift already has keccak-256 in the pure
> core: `BarnardCorePrimitives.keccak256` (`Sources/BarnardCore/BarnardCorePrimitives.swift:4`),
> exposed publicly as `BarnardCoreCrypto.keccak256` (`BarnardCoreCrypto.swift:278`, documented as
> "legacy Keccak padding, not NIST SHA3-256"), already used for Ethereum address derivation in
> `BarnardCoreSigning.swift`. **Reuse it; do not write a second one.** On Android there is no
> keccak in `src/main`, but BouncyCastle is already a dependency
> (`packages/android/barnard/build.gradle.kts:56`, `org.bouncycastle:bcprov-jdk15to18:1.81`), which
> provides `KeccakDigest(256)` — so this needs no new dependency either. Your Android job is to
> expose it behind the same shape as Swift and prove byte-equality via the vectors.
> Swift additions go in `packages/swift/barnard/Sources/BarnardCore/`. That target is stdlib-only
> and CI greps it for `Foundation|FoundationEssentials|CryptoKit|CoreBluetooth|Security|UIKit|
> CommonCrypto|SecRandom|UserDefaults|Data|Date|CCCrypt` with word boundaries — use `[UInt8]` and
> `Int64`, and do not name anything `Data` or `Date`.
> Kotlin: add to `packages/android/barnard/src/main/kotlin/org/levarac/barnard/` in a new file; use
> only `kotlin.*` / `java.security.*` / BouncyCastle, no `android.*`.
> Expose on both: `keccak256(bytes) -> 32 bytes`, and
> `eventKeySetBytes(keys) = A3 01 01 02 (0x80|n) (58 21 key)*n 03 01`,
> `keySetDigest = sha256("levarac:event-key-set-digest:v1\0" || keySetBytes)`,
> `computeEventId(registrar20, anchorOperator20, nonce32, keySetDigest32) =
> keccak256(keccak256("levarac:event:v1") || zero12||registrar || zero12||anchorOperator || nonce ||
> keySetDigest)`.
> Also in this package, because it is the other mechanical primitive the envelope needs: a
> **bounded deterministic-CBOR reader** and the COSE_Sign1 `Sig_structure` builder. The reader
> handles only what the DelegationCert uses — unsigned ints, byte strings, text strings, arrays,
> maps, and tag 18 — with a hard input cap and no recursion beyond a small fixed depth; it must
> reject indefinite-length items, non-minimal integer encodings, trailing bytes, and duplicate or
> out-of-order map keys. The builder produces
> `Sig_structure = ["Signature1", protected, h'', payload]` in deterministic CBOR, whose SHA-256 is
> the digest that gets recovered against. Do **not** write a general CBOR library; this is a
> deliberately small, strict reader.
> TDD: write the failing tests first, from `test-vectors/b005-envelope-v2.txt`, loaded with the
> existing helpers (Swift `findTestVectorsDirectory`/`parseVectorFile` in
> `Tests/BarnardCoreTests/BarnardOwnerKeyConformanceVectorTests.swift`; Kotlin
> `findRepoRoot`/`parseVectors` in `BarnardOwnerKeyConformanceVectorTest.kt`).
> If you edit any file listed in `scripts/mirror-manifest.sh`, run `./scripts/sync-mirrors.sh` and
> never hand-edit the Dart copy. Open a Draft PR with `Closes #122` — do not merge.
>
> **Done when:** `swift build --target BarnardCore` and `--target BarnardCoreC` pass and the
> forbidden-import grep is clean; `xcodebuild -scheme Barnard-Package -destination "id=$UDID"
> SWIFT_OPTIMIZATION_LEVEL=-O test` passes; `cd packages/android/barnard && ./gradlew test` passes;
> `./scripts/check-swift-mirror.sh`, `./scripts/check-android-mirror.sh` and
> `./scripts/check-swift-package-manifest-mirror.sh` pass; and both platforms reproduce, from the
> fixture inputs in `test-vectors/b005-envelope-v2.txt`:
> `keySetDigest = cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b700`;
> `eventId = 5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195` (the cross-repo
> anchor — this same value appears in parallax's own `positive/event-definition-v1.json`);
> the parallax `openCodeV1` example, eventId `0001…1f` → `eventCodeHash = 6c86c6aac5fb24bc`;
> and, from parallax's `positive/delegation-cert-v1.json`, a decode of the 222-byte
> `signedDelegationCertHex` into its six labels plus a rebuilt 166-byte `Sig_structure` matching
> that vector's `sigStructureHex` and its SHA-256 matching `signatureDigestHex`.
> Every one of these is independently recomputable, so a wrong implementation cannot pass by
> agreeing with itself.

### P2 — envelope v2 codec and verifier

> **Maker prompt.** Repo `levarac/barnard`, branch `feat/issue-122-envelope-v2-codec` from the P1
> branch (or `origin/main` once P1 merges). `specs/122-b005-v2-signed-envelope/spec.md` is normative
> — implement it exactly; do not invent fields.
> Implement, on both platforms and byte-identically: serialize and strict-parse the B005 v2 delivery
> container (`0x02`, hop, 2-byte length, envelope; total ≤ 512, envelope ≤ 508), the signed-envelope
> fixed-offset layout, and the full verification order — structural bounds, NFC/UTF-8 display-name
> validation, key-set encoding, `keySetDigest`, the recomputed `eventId`, DelegationCert decode and
> authority-signature check, the `cert.eventId` tie-in, the cert's own inclusive ENIN window, the
> `joinMode = open` `eventCodeHash` derivation check, the delegate signature, and the event ENIN
> window with the 12-ENIN lifetime bound.
> **The DelegationCert is an opaque byte range**: parse its fields, never re-serialise it. It must
> stay byte-identical to the copy that appears in parallax's ObservationBundle v2, so any
> canonicalisation on our side is a bug.
> There are **two** signatures to check and both are **recover-and-compare** — barnard has no
> `verify()` primitive. Use `BarnardCoreSigning.recoverPublicKey` (Swift) and the BouncyCastle
> backend (Kotlin); try recovery id 0 then 1 and accept if either recovers to the expected key:
> `authorityKeys[authoritySignerIndex]` for the cert's COSE signature, and the cert's
> `delegatePublicKey` for the envelope signature. Enforce low-S on both by rejection, never by
> normalising.
> Define the verifier as an injected interface/protocol so the codec is testable against a stub, and
> make ENIN an injected input rather than reading the wall clock. Unestablished ENIN fails closed.
> Swift code goes in `Sources/BarnardCore/` under the purity rules from P1; Kotlin in a new file in
> the flat module using no `android.*`. Sync mirrors if you touch a manifest file. Draft PR,
> `Closes #122` — do not merge.
>
> **Done when:** every positive and negative entry in `test-vectors/b005-envelope-v2.txt` passes
> identically on Swift and Kotlin, including every single-byte mutation, the high-S rejection, the
> non-NFC and control-character rejections, the `eventId`-preimage mismatch, lifetime > 12 ENIN, and
> the three ENIN boundary cases (`validFromEnin - 1` reject, `relayExpiresAtEnin - 1` accept,
> `relayExpiresAtEnin` reject); plus the same build/test/mirror gate as P1.

### P3 — relay state machine

> **Maker prompt.** Repo `levarac/barnard`, branch `feat/issue-128-relay-state-machine`. Normative:
> `specs/134-b005-participant-relay/spec.md` (on `origin/main`) and
> `specs/122-b005-v2-signed-envelope/spec.md`. Implement §(b) of the design: selection with the
> one-event cap and 5-minute pin, dedup by `SHA256(signedEnvelope)` retaining the lowest hop,
> hop-limit-2 output, the probabilistic density controller (`k = 3`, `T = 30 s`, `pEnter = (k-r)/k`,
> `pKeep = min(1, k/(r+1))`, uniform `0..T/2` contention delay re-checked at its end, 30-second
> leases), the 32-handle bounded set that saturates rather than errors, and teardown on expiry,
> invalidation, signature failure or host stop.
> Pure and platform-free on both sides, with time, randomness and signature verification injected so
> every test is deterministic. Randomness derives from a per-install secret plus payload digest plus
> decision epoch and **must never** reach the wire, a public API, a debug surface or a log; neither
> may `r` or peer handles — relay observations must not feed census, prevalence, majority,
> attendance or admission.
> Read `BarnardAdoptionCensus.{swift,kt}` (`BarnardCensusRelayCache` and its contract tests) as the
> house pattern for cache shape and test structure, but do **not** reuse it: it keys on the census
> 5-tuple, this keys on the payload digest.
> Draft PR, `Closes #128`, `Refs #122` — do not merge.
>
> **Done when:** the `relay-hop-dedup` and `density-decisions` vector families pass identically on
> both platforms; deterministic fixtures cover `r = 0,1,2,3,4`, contention cancellation, lease
> renewal, 33 handles, two competing valid events and selection expiry; a test asserts no public API
> or log path exposes `r`, a peer handle or the election secret; plus the same build/test/mirror gate.

### P4 — GATT and engine wiring

> **Maker prompt.** Repo `levarac/barnard`, branch `feat/issue-128-b005-v2-engine-wiring`. Wire P2
> and P3 into `BarnardEngine` on both platforms: serve a v2 container from the Peripheral under spec
> 113's immutable bounded long-read snapshot rules, read and verify it on the Central, and drive the
> relay state machine from real observations.
> Relay **must share, not duplicate**, the existing bounded GATT machinery — `connectQueue`,
> `maxConnectQueue = 20`, `cooldownPerPeerSeconds = 10` (Swift `BarnardEngine.swift:236-248`;
> Kotlin `BarnardEngine.kt:166-167`), the 8-second exchange timeout, and the two-attempts-per-peer
> -per-session budget in `BarnardEventInfoRetryBudget`. Do not create a second Scan or queue.
> B005 v1 must keep parsing under its existing spec-113 semantics and must never be relayed or enter
> the v2 verified path. A Central that does not understand `0x02` treats event-info as unavailable.
> `BarnardEventInfo.{swift,kt}` are **not** in `scripts/mirror-manifest.sh`, so no Dart mirror work
> is expected — but run the three mirror checkers anyway and sync if you touched a manifest file.
> Draft PR, `Closes #128` — do not merge.
>
> **Done when:** full Swift and Android suites pass; a mock-Transport test shows a hop-0 observation
> producing hop-1 serving and a hop-2 observation producing none; v1 payloads still parse and are
> never relayed; stopping Scan clears lease, handles and cached envelope; and the two-device
> device-lab run on `emi` shows a relayed candidate reaching a device that never heard the direct
> source (commit status `device-lab/two-device-loop`).

### P5 — release and pin bump *(lead, not a maker)*

barnard cuts a tagged release; beid then bumps `android/app/build.gradle.kts` and the SPM pin.
beid's CI re-runs `scripts/check_barnard_dependency_provenance.py`. Worth folding in the stale
`android/README.md` `0.3.0` reference at the same time.

### P6 — beid consumer wiring

> **Maker prompt.** Repo `thegreeting/beid`, branch `feat/issue-367-b005-relay-consumer`. Read
> issue #367 and the 2026-09-03 maintainer ruling on #141 before starting; the ruling supersedes
> #141's original requirements and **drops zero-tap** — joining is one explicit tap.
> Feed verified relayed envelopes into the existing ingestion path: a relayed hint becomes another
> `NearbyEventSourceObservation` folded into the same `NearbyEventCandidate`
> (`shared/…/parallax/discovery/NearbyEventDiscovery.kt`, `…/beid/shared/event/EventInfoStore.kt`).
> Add `AUTHENTICATED_OFFLINE` to `NearbyEventTrustStatus`; **keep the registry axis
> (`NearbyEventRegistryStatus`) separate** — a card is fully verified only when both axes are
> satisfied. Never render a verified badge on the trust axis alone: `RecordDetailScreen.kt:78-79`
> records that an unbacked "Verified" claim has already been removed from this product twice, and
> `EventCardView.Badge` deliberately has no `VERIFIED` case.
> Never display hop count and never use it for aggregation. Honour one-device-one-event. Add the
> Settings/About relay-disclosure line. Stop relaying when sensing stops or Bluetooth is denied.
> Both platforms, or the PR body must state why one is intentionally untouched — silence is not a
> reason (beid's both-OS feature rule). PR body in **Japanese**, `Closes #367`, and the pre-merge
> comment must say `Development link: 済`. Draft PR — do not merge.
>
> **Done when:** `python3 scripts/run_local_tests.py android :shared:testAndroidHostTest
> :app:testDebugUnitTest` passes; the iOS scheme `Beid` tests pass; `scripts/lint.sh` is clean; a
> test pins that the relay path never touches record/sign/submit; and defaults and behaviour are
> identical on both platforms.

### P7 — beid two-device harness *(blocked; see §0.3 and §d.5)*

Build the central/peripheral role assignment behind `:app:deviceLabBleTest`, replacing the
always-failing `DeviceLabBleSuiteNotImplementedTest`. Needed for #367's acceptance criterion. Do
not start it until the lead has Ken's answer on the hardware question in §0.3.
