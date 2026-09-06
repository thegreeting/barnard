// Use of this source code is governed by a BSD-style license.

package org.levarac.barnard

/**
 * Flutter-free, Kotlin-first public event/value types for [BarnardEngine].
 *
 * These mirror the shapes emitted on the Flutter `barnard/events` and
 * `barnard/debugEvents` channels (see
 * `packages/dart/barnard/android/src/main/kotlin/org/levarac/barnard/BarnardController.kt`)
 * but are expressed as typed Kotlin classes instead of untyped
 * `Map<String, Any?>` payloads.
 */
public data class BarnardBeaconChain(
    val chainId: String,
    val genesisUnixSeconds: Long,
    val slotSeconds: Long,
) {
    public companion object {
        public val ethereumMainnet: BarnardBeaconChain = BarnardBeaconChain(
            chainId = "mainnet",
            genesisUnixSeconds = 1_606_824_023L,
            slotSeconds = 12L,
        )
    }

    internal fun toInternal(): BarnardCrypto.BeaconChainConfig = BarnardCrypto.BeaconChainConfig(
        chainId = chainId,
        genesisUnixSeconds = genesisUnixSeconds,
        slotSeconds = slotSeconds,
    )
}

public enum class BarnardEninMode {
    FIXED_LENGTH,
    BEACON_SLOT,
    ;

    internal fun toInternal(): BarnardCrypto.EninMode = when (this) {
        FIXED_LENGTH -> BarnardCrypto.EninMode.FIXED_LENGTH
        BEACON_SLOT -> BarnardCrypto.EninMode.BEACON_SLOT
    }

    internal companion object {
        fun fromInternal(mode: BarnardCrypto.EninMode): BarnardEninMode = when (mode) {
            BarnardCrypto.EninMode.FIXED_LENGTH -> FIXED_LENGTH
            BarnardCrypto.EninMode.BEACON_SLOT -> BEACON_SLOT
        }
    }
}

public data class BarnardCapabilities(
    val supportedTransports: List<String>,
    val supportsConnectionlessRpid: Boolean,
    val supportsGattFallback: Boolean,
    val supportsBackground: Boolean,
    val supportsHighRateRssi: Boolean,
    val eninMode: BarnardEninMode,
    val eninSeconds: Long,
    val beaconChain: BarnardBeaconChain,
)

public data class BarnardState(
    val isScanning: Boolean,
    val isAdvertising: Boolean,
    val eventCode: String?,
    val eninMode: BarnardEninMode,
    val eninSeconds: Long,
    val beaconChain: BarnardBeaconChain,
    val reasonCode: String?,
)

public data class BarnardPermissionStatus(
    val platform: String,
    val permissions: Map<String, String>,
    val requiredPermissions: List<String>,
    val missingPermissions: List<String>,
    val requestablePermissions: List<String>,
    val blockedPermissions: List<String>,
    val canScan: Boolean,
    val canAdvertise: Boolean,
)

/**
 * Error accompanying a [BarnardPermissionResult.Failed], mirroring the
 * Flutter plugin's `MethodChannel.Result.error` codes for
 * `requestPermissions` (`E_DISPOSED`, `E_NO_ACTIVITY`,
 * `E_PERMISSION_REQUEST_IN_PROGRESS`). [status] carries the
 * last-known [BarnardPermissionStatus] as details, same as the original's
 * error `details` argument — `null` for `E_DISPOSED`, matching the
 * original passing `null` there too.
 */
public data class BarnardPermissionError(
    val code: String,
    val message: String,
    val status: BarnardPermissionStatus?,
)

/**
 * Outcome of [BarnardEngine.requestPermissions]. Callers MUST branch on
 * this instead of assuming every callback invocation means the request
 * actually completed — [Failed] signals a request that never happened
 * (no attached `Activity`, one already in flight) or was abandoned
 * ([BarnardEngine.dispose] called before the platform replied).
 */
public sealed class BarnardPermissionResult {
    public data class Granted(val status: BarnardPermissionStatus) : BarnardPermissionResult()
    public data class Failed(val error: BarnardPermissionError) : BarnardPermissionResult()
}

public data class BarnardDetectionEvent(
    /** Unix epoch milliseconds. */
    val timestampMs: Long,
    val rssi: Int,
    val formatVersion: Int,
    /** Lowercase hex, 17 bytes. */
    val rpid: String,
    /** Lowercase hex, this device's own current RPID at [timestampMs]. */
    val reporterRpid: String,
    val detectedDisplayId: String?,
    val enin: Long,
    val debugLocalName: String?,
)

public data class BarnardRssiUpdateEvent(
    val timestampMs: Long,
    val rssi: Int,
    val rpid: String,
    val reporterRpid: String,
    val enin: Long,
    val detectedDisplayId: String?,
    val debugLocalName: String?,
)

public data class BarnardErrorEvent(
    val code: String,
    val message: String,
    val recoverable: Boolean?,
)

public data class BarnardConstraintEvent(
    val code: String,
    val message: String?,
    val requiredAction: String?,
)

/**
 * B005 hint retained only for the current discovery session. Hosts MUST NOT
 * retain this hint data beyond that session. A generic overflow hint has an
 * empty [eventInfo], so no parsed display name or hash can escape the session.
 */
public data class BarnardEventInfoHintEvent(
    val peripheralId: String,
    val eventInfo: BarnardEventInfo,
    val additionalNamesOmitted: Boolean,
    val additionalEventsOmitted: Boolean,
)

/**
 * Outcome of running a B005 v2 container (spec 122) through
 * [BarnardB005EnvelopeV2.verify] on the receive path.
 *
 * Deliberately a two-case sum rather than a state field: `REGISTRY_VERIFIED`
 * is unrepresentable here, so the SDK cannot assign it even by mistake. That
 * tier is the host's to assign, and only after the host has performed an
 * authenticated registry read (spec 122, "Receiver policy").
 */
public sealed class BarnardB005EnvelopeV2Receipt {
    /**
     * Steps 1-7 passed: the signature verifies and `eventId` is self-consistent
     * with the key set carried in the envelope. Registration is NOT confirmed,
     * and this MUST NOT be presented to a user as "verified" or "registered".
     */
    public data class RadioSelfVerified(
        val envelope: BarnardB005VerifiedEnvelope,
    ) : BarnardB005EnvelopeV2Receipt()

    /**
     * Verification did not succeed. The SDK reports *that* it failed, not *why*:
     * `verify` returns nothing both for a malformed container and for one whose
     * signature does not check out, and the two are not distinguished.
     */
    public object Unverified : BarnardB005EnvelopeV2Receipt()

    public val receiverState: BarnardB005ReceiverState
        get() = when (this) {
            is RadioSelfVerified -> BarnardB005ReceiverState.RADIO_SELF_VERIFIED
            is Unverified -> BarnardB005ReceiverState.UNVERIFIED
        }

    public val verifiedEnvelope: BarnardB005VerifiedEnvelope?
        get() = (this as? RadioSelfVerified)?.envelope
}

/**
 * A B005 v2 signed envelope read from a peer's event-info characteristic.
 *
 * Emitted for every container whose first byte is
 * [BarnardB005EnvelopeV2.FORMAT_VERSION], verified or not: a failed envelope is
 * surfaced to the host rather than silently dropped.
 */
public class BarnardEventInfoEnvelopeV2Event(
    public val peripheralId: String,
    public val receipt: BarnardB005EnvelopeV2Receipt,
    /**
     * The container exactly as it came off the wire. Spec 134 re-broadcast
     * copies the signature byte for byte, so this is never re-encoded.
     */
    public val rawContainer: ByteArray,
) {
    public val receiverState: BarnardB005ReceiverState get() = receipt.receiverState
    public val verifiedEnvelope: BarnardB005VerifiedEnvelope? get() = receipt.verifiedEnvelope
}

/**
 * What the spec 134 density controller decided about the selected envelope.
 *
 * The controller renews a lease by ending the old one and electing again, so a
 * [KEEP] is always preceded by a [STOP] for the same digest. [KEEP] is the
 * engine's name for "elected again with the digest that was just being served";
 * the relay itself draws no distinction.
 */
public enum class BarnardRelayDecision { BROADCAST, KEEP, STOP }

/**
 * A spec 134 relay decision, surfaced so a host can observe whether and why an
 * envelope was re-broadcast. No peer handle, election secret, or density count
 * leaves the controller: the envelope is identified by its payload digest,
 * which is already derivable from the bytes on the wire.
 */
public class BarnardRelayDecisionEvent(
    public val decision: BarnardRelayDecision,
    /** `SHA256(signedEnvelope)` of the envelope the decision is about. */
    public val payloadDigest: ByteArray,
    /**
     * The `relayHopCount` this device serves (observed minimum + 1). For
     * [BarnardRelayDecision.STOP] it is the hop last served.
     */
    public val hop: Int,
    /**
     * `elected`, `renewed`, `lease_ended`, `host_stop`,
     * `definition_invalidated`, or `own_value_precedence`.
     */
    public val reason: String,
)

public sealed class BarnardEvent {
    public data class State(val state: BarnardState) : BarnardEvent()
    public data class Constraint(val constraint: BarnardConstraintEvent) : BarnardEvent()
    public data class Error(val error: BarnardErrorEvent) : BarnardEvent()
    public data class Detection(val detection: BarnardDetectionEvent) : BarnardEvent()
    public data class RssiUpdate(val update: BarnardRssiUpdateEvent) : BarnardEvent()
    public data class EventInfoHint(val hint: BarnardEventInfoHintEvent) : BarnardEvent()
    public data class EventInfoEnvelopeV2(val envelope: BarnardEventInfoEnvelopeV2Event) : BarnardEvent()
    public data class RelayDecision(val relay: BarnardRelayDecisionEvent) : BarnardEvent()
}

public data class BarnardDebugEvent(
    val timestampMs: Long,
    val level: String,
    val name: String,
    val data: Map<String, Any?>?,
)

public data class BarnardAutoStartResult(
    val scanningStarted: Boolean,
    val advertisingStarted: Boolean,
)
