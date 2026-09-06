// Use of this source code is governed by a BSD-style license.

package org.levarac.barnard

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.provider.Settings
import android.util.Base64
import android.util.Log
import org.levarac.barnard.BarnardCrypto.toHex
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "BarnardEngine"

internal fun shouldDiscardEventInfoSnapshotAfterResponse(status: Int, responseSent: Boolean): Boolean =
    status == BluetoothGatt.GATT_SUCCESS && !responseSent

internal fun isRuntimePermissionRequestBlocked(
    sdkInt: Int,
    hasPermission: Boolean,
    wasRequestedBefore: Boolean,
    shouldShowRequestPermissionRationale: Boolean
): Boolean {
    if (sdkInt < 23 || hasPermission) return false
    if (!wasRequestedBefore) return false
    return !shouldShowRequestPermissionRationale
}

/**
 * Barnard v2 BLE engine — Flutter-free, Kotlin-first port of
 * `BarnardController` (the Flutter plugin's native controller). Same GATT
 * service (fixed UUID), same v2 wire behavior:
 *
 * - B002 RPID (Read, 17 bytes)
 * - B003 displayId (Read, 4 bytes when joined to an event) — `SHA256(TEK)[0:4]`. v2 no longer serves TEK.
 * - B004 EventCodeHash (Read, 0 or 8 bytes)
 *
 * TEK is never transmitted over BLE in v2. No device-unique persistent
 * identifier is placed on the wire (same invariant as the Flutter plugin).
 *
 * Unlike [BarnardEngine.swift's `BarnardEngine`][BarnardEngine] (which gets
 * Bluetooth authorization state pushed to it by `CoreBluetooth`), Android's
 * runtime-permission flow is `Activity`-driven: callers must call
 * [setActivity] with the hosting `Activity` and forward
 * [Activity.onRequestPermissionsResult] callbacks into
 * [onRequestPermissionsResult] for [requestPermissions] to resolve.
 */
public class BarnardEngine(private val appContext: Context) {
    public companion object {
        // Kept private: these were never part of the public surface, and the
        // companion is only public so the relay cadence constants below can be.
        private const val permissionRequestCode = 0xB4D
        private const val permissionRequestedKeyPrefix = "permission_requested:"

        /** Spec 134's decision boundary: `T` = 30 seconds. */
        public const val RELAY_DECISION_BOUNDARY_MS: Long = 30_000L

        /**
         * How often the engine's internal tick runs the relay forward.
         *
         * Deliberately shorter than the decision boundary. A lease starts when
         * a contention delay ends, so it expires at an arbitrary offset within
         * an epoch rather than on the boundary; ticking only every 30 seconds
         * would let a lease be served for up to twice its length before
         * anything noticed. This bounds that overshoot to one tick. It does
         * not make the device decide more often -- the relay still takes at
         * most one election decision per epoch -- and it starts no radio work,
         * so the cost is a timer wake-up while relaying and nothing at all
         * when the relay is idle.
         */
        internal const val RELAY_TIMER_INTERVAL_MS: Long = 5_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var activity: Activity? = null
    private var pendingPermissionCallback: ((BarnardPermissionResult) -> Unit)? = null

    // MARK: - Event Delivery

    /** Called on the main thread with the same event stream the Flutter plugin exposes on `barnard/events`. */
    public var onEvent: ((BarnardEvent) -> Unit)? = null

    /** Called on the main thread with the same event stream the Flutter plugin exposes on `barnard/debugEvents`. */
    public var onDebugEvent: ((BarnardDebugEvent) -> Unit)? = null

    // MARK: - UUIDs

    private val serviceUuid: UUID = UUID.fromString("0000B001-0000-1000-8000-00805F9B34FB")
    private val rpidCharUuid: UUID = UUID.fromString("0000B002-0000-1000-8000-00805F9B34FB")
    private val displayIdCharUuid: UUID = UUID.fromString("0000B003-0000-1000-8000-00805F9B34FB")
    private val eventCodeHashCharUuid: UUID = UUID.fromString("0000B004-0000-1000-8000-00805F9B34FB")
    private val eventInfoCharUuid: UUID = UUID.fromString("0000B005-0000-1000-8000-00805F9B34FB")

    // MARK: - Bluetooth

    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter

    private var gattServer: BluetoothGattServer? = null

    // MARK: - State

    private var isScanning: Boolean = false
    private var isAdvertising: Boolean = false
    private var allowDuplicates: Boolean = true
    private var formatVersion: Int = 1
    private var debugOriginalName: String? = null
    private val unavailableRssi: Int = 127
    private var eninMode: BarnardCrypto.EninMode = BarnardCrypto.EninMode.FIXED_LENGTH
    private var eninSeconds: Long = 300L
    private var beaconChain: BarnardCrypto.BeaconChainConfig = BarnardCrypto.BeaconChainConfig()

    // MARK: - Event Mode

    private var eventCode: String? = null
    @Volatile
    private var eventInfoServePolicy = BarnardEventInfoServePolicy()
    @Volatile
    private var eventInfoDisplayName: String? = null
    private data class EventInfoSnapshot(val value: ByteArray, @Volatile var lastRequestAtMs: Long)
    private val eventInfoStateLock = Any()
    private val eventInfoConnectionEpochs: MutableMap<String, Long> = ConcurrentHashMap()
    private val eventInfoSnapshots: MutableMap<String, EventInfoSnapshot> = ConcurrentHashMap()
    private val eventInfoRetryBudget = BarnardEventInfoRetryBudget()
    private var eventInfoDiscoverySession = BarnardEventInfoDiscoverySession(System.currentTimeMillis())

    // MARK: - Spec 134 participant relay
    //
    // Every field below is read and written only under [eventInfoStateLock]:
    // observations arrive on a binder thread while the GATT server answers
    // reads on another, and BarnardParticipantRelay is not thread-safe.

    private var relayVerifier: BarnardRelayVerifier? = null
    private var relayJoinedEventProvider: BarnardRelayJoinedEventProvider? = null
    private var relaySeedMaterial: ByteArray = ByteArray(0)
    private var relayClock: BarnardRelayMonotonicClock? = null
    private var relayEninSource: BarnardRelayEninSource? = null
    private var participantRelay: BarnardParticipantRelay? = null
    private var relayTickRunnable: Runnable? = null
    private var relayServedContainer: ByteArray? = null

    /**
     * A host-supplied, host-signed hop-zero v2 container (spec 122), served in
     * place of the v1 payload while it is set. Guarded by [eventInfoStateLock]
     * like the relayed container: the GATT server answers reads on one thread
     * while the host configures on another.
     */
    private var ownEnvelopeV2Container: ByteArray? = null
    private var relayLastServedDigest: ByteArray? = null
    /**
     * Set around each relay call so the sink can name the cause of a start or
     * stop. The relay's sink interface carries no reason of its own.
     */
    private var relayDecisionReason: String = "elected"
    /** Decisions produced under the lock, emitted after it is released. */
    private val relayPendingDecisions = mutableListOf<BarnardRelayDecisionEvent>()

    private val relaySink = object : BarnardRelayOutputSink {
        override fun start(container: ByteArray) {
            relayServedContainer = container
            val envelope = if (container.size > 4) container.copyOfRange(4, container.size) else ByteArray(0)
            val digest = MessageDigest.getInstance("SHA-256").digest(envelope)
            val keep = relayLastServedDigest?.contentEquals(digest) == true
            relayLastServedDigest = digest
            val hop = if (container.size > 1) container[1].toInt() and 0xFF else 0
            val reason = if (keep) "renewed" else relayDecisionReason
            relayPendingDecisions += BarnardRelayDecisionEvent(
                decision = if (keep) BarnardRelayDecision.KEEP else BarnardRelayDecision.BROADCAST,
                payloadDigest = digest,
                hop = hop,
                reason = reason,
            )
        }

        override fun stop() {
            val container = relayServedContainer
            relayServedContainer = null
            val hop = if ((container?.size ?: 0) > 1) container!![1].toInt() and 0xFF else 0
            relayPendingDecisions += BarnardRelayDecisionEvent(
                decision = BarnardRelayDecision.STOP,
                payloadDigest = relayLastServedDigest ?: ByteArray(0),
                hop = hop,
                reason = relayDecisionReason,
            )
        }
    }
    @Volatile
    private var currentTek: ByteArray = ByteArray(16)

    private data class CachedReporterPayload(
        val enin: UInt,
        val tek: ByteArray,
        val payload: ByteArray,
    )

    private var cachedReporterPayload: CachedReporterPayload? = null

    // MARK: - Discovery State

    private val discoveredRssi: MutableMap<String, Int> = mutableMapOf()
    private val discoveredAt: MutableMap<String, Long> = mutableMapOf()
    private val lastDiscoveryNameById: MutableMap<String, String> = mutableMapOf()

    private fun isDebugBuild(): Boolean {
        return BuildConfig.BUILD_TYPE != "release"
    }

    // MARK: - Connection Queue

    private val connectQueue: ArrayDeque<BluetoothDevice> = ArrayDeque()
    private val lastConnectAttemptAtMs: MutableMap<String, Long> = mutableMapOf()
    private val resolutionBackoffUntilMs: MutableMap<String, Long> = mutableMapOf()
    private val pendingBoundaryRetryDevices: MutableMap<String, BluetoothDevice> = mutableMapOf()
    private val boundaryRetryBudget = BarnardV2Policy.BoundaryRetryBudget()
    private var activeGatt: BluetoothGatt? = null

    private val maxConnectQueue: Int = 20
    private val cooldownPerPeerMs: Long = 10_000
    private val resolutionFailureBackoffMs: Long = 30_000
    private val resolutionRejectedBackoffMs: Long = 5 * 60_000

    // `connectGatt` has no built-in deadline; a hung connection to a peer
    // whose BLE MAC has since rotated pins `activeGatt` forever, starving
    // every subsequently-discovered peripheral as "scan only, awaiting
    // GATT". Arm a manual watchdog that closes the GATT and releases the
    // pin if no connection progress is made.
    private val connectTimeoutMs: Long = 8_000
    private var connectWatchdog: Runnable? = null

    // MARK: - Central GATT State (v2)

    private data class GattReadValues(
        var eventCodeHash: ByteArray? = null,
        var rpid: ByteArray? = null,
        var rpidReadStartedAtMs: Long? = null,
        var rpidReadCompletedAtMs: Long? = null,
        var detectedDisplayId: ByteArray? = null
    )

    private val peripheralReadValues: MutableMap<String, GattReadValues> = mutableMapOf()

    // MARK: - Known Peers (for high-rate RSSI updates)

    private data class KnownPeer(
        val rpid: ByteArray,
        val enin: Long,
        val detectedDisplayId: String?,
        val debugLocalName: String?
    )

    private val knownPeers: MutableMap<String, KnownPeer> = mutableMapOf()

    // MARK: - Storage

    private val prefs: SharedPreferences =
        appContext.getSharedPreferences("barnard", Context.MODE_PRIVATE)

    init {
        initializeTek()
    }

    private fun initializeTek() {
        eventCode = prefs.getString("eventCode", null)

        val deviceSecret = getOrCreateDeviceSecret()
        currentTek = if (eventCode != null) {
            BarnardCrypto.deriveTekForEvent(deviceSecret, eventCode!!)
        } else {
            BarnardCrypto.deriveTekForAnonymous(deviceSecret)
        }
    }

    /** Must be called (with the hosting `Activity`, or `null` on detach) before [requestPermissions] can resolve. */
    public fun setActivity(activity: Activity?) {
        this.activity = activity
    }

    public fun dispose() {
        stopScan()
        stopAdvertise()
        // Mirrors the original BarnardController.dispose(), which resolves any
        // in-flight MethodChannel.Result with E_DISPOSED rather than dropping
        // it: a caller awaiting this callback (e.g. wrapped in
        // suspendCancellableCoroutine) must not hang forever just because the
        // engine was disposed mid-request.
        pendingPermissionCallback?.let { callback ->
            pendingPermissionCallback = null
            callback(
                BarnardPermissionResult.Failed(
                    BarnardPermissionError(
                        code = "E_DISPOSED",
                        message = "BarnardEngine disposed before permission result",
                        status = null,
                    )
                )
            )
        }
        activity = null
        onEvent = null
        onDebugEvent = null
    }

    // MARK: - Public API

    public fun getCapabilities(): BarnardCapabilities = BarnardCapabilities(
        supportedTransports = listOf("ble"),
        supportsConnectionlessRpid = false,
        supportsGattFallback = true,
        supportsBackground = false,
        supportsHighRateRssi = false,
        eninMode = BarnardEninMode.fromInternal(eninMode),
        eninSeconds = eninSeconds,
        beaconChain = beaconChainInfo(),
    )

    public fun getState(): BarnardState = BarnardState(
        isScanning = isScanning,
        isAdvertising = isAdvertising,
        eventCode = eventCode,
        eninMode = BarnardEninMode.fromInternal(eninMode),
        eninSeconds = eninSeconds,
        beaconChain = beaconChainInfo(),
        reasonCode = null,
    )

    public fun configure(
        eninMode: BarnardEninMode = BarnardEninMode.FIXED_LENGTH,
        eninSeconds: Long = 300L,
        beaconChain: BarnardBeaconChain = BarnardBeaconChain.ethereumMainnet,
        eventCode: String? = null,
    ) {
        this.eninMode = eninMode.toInternal()
        this.eninSeconds = eninSeconds.coerceIn(12L, 3600L)
        this.beaconChain = beaconChain.toInternal()

        if (!eventCode.isNullOrEmpty() && eventCode != this.eventCode) {
            joinEvent(eventCode)
        }

        knownPeers.clear()
        emitDebug("info", "configure", mapOf(
            "eninMode" to eninModeName(),
            "eninSeconds" to this.eninSeconds,
            "beaconChain" to this.beaconChain.chainId,
        ))
    }

    /** Sets B005 serving state. This is local host state and defaults to off. */
    public fun configureEventInfoServing(
        organizerDesignated: Boolean = false,
        eventActiveForDiscovery: Boolean = false,
        eventDisplayName: String? = null,
    ) {
        eventDisplayName?.let(BarnardEventInfoCodec::validateEventDisplayName)
        eventInfoServePolicy = BarnardEventInfoServePolicy(organizerDesignated, eventActiveForDiscovery)
        eventInfoDisplayName = eventDisplayName
    }

    /**
     * Supplies the pre-encoded, pre-signed B005 v2 container (spec 122) this
     * device serves as its own event-info value, or clears it when [container]
     * is null.
     *
     * The host builds the container with [BarnardB005EnvelopeV2.encodeContainer]
     * in either authority-direct or delegate mode. The SDK does not sign,
     * re-encode, or re-verify it, and it never assigns `REGISTRY_VERIFIED`: it
     * only checks that the bytes are a well-formed `0x03` container at hop zero
     * and then serves them byte for byte.
     *
     * A supplied container is not gated on [configureEventInfoServing]. The v1
     * payload needs that policy because it carries no signature of its own;
     * supplying a signed container is itself the decision to serve.
     *
     * @throws BarnardOwnEnvelopeV2Exception when the bytes are not such a
     *   container. Nothing is stored and any previous container stays in place.
     */
    public fun configureOwnEventInfoEnvelopeV2(container: ByteArray?) {
        if (container == null) {
            synchronized(eventInfoStateLock) { ownEnvelopeV2Container = null }
            emitDebug("info", "own_envelope_v2", mapOf("supplied" to false))
            return
        }
        validateOwnEnvelopeV2Container(container)
        val copy = container.copyOf()
        // This device now has an own value, so it can no longer put a relayed
        // container on the wire. Drop any lease here rather than at the next
        // advanceParticipantRelay, so isRelayServing never claims a broadcast
        // that has already stopped being possible.
        val decisions = synchronized(eventInfoStateLock) {
            ownEnvelopeV2Container = copy
            tearDownParticipantRelayLocked("own_value_precedence")
            drainRelayDecisionsLocked()
        }
        emitRelayDecisions(decisions)
        emitDebug("info", "own_envelope_v2", mapOf("supplied" to true, "bytes" to copy.size))
    }

    /** The container this device serves as its own hop-zero value, if any. */
    public val ownEventInfoEnvelopeV2: ByteArray?
        get() = synchronized(eventInfoStateLock) { ownEnvelopeV2Container?.copyOf() }

    /**
     * Structural gate for a host-supplied own container: the first two guards
     * of [BarnardB005EnvelopeV2.verify] plus a hop-zero requirement. `verify`
     * itself is deliberately not called — it needs the current ENIN and would
     * reject a container issued ahead of its own validity window.
     */
    private fun validateOwnEnvelopeV2Container(container: ByteArray) {
        if (container.size < 5 || container.size > 512) {
            throw BarnardOwnEnvelopeV2Exception(BarnardOwnEnvelopeV2Error.INVALID_CONTAINER_LENGTH)
        }
        if (container[0].toInt() and 0xFF != BarnardB005EnvelopeV2.FORMAT_VERSION) {
            throw BarnardOwnEnvelopeV2Exception(BarnardOwnEnvelopeV2Error.UNSUPPORTED_FORMAT_VERSION)
        }
        if (container[1].toInt() and 0xFF != 0) {
            throw BarnardOwnEnvelopeV2Exception(BarnardOwnEnvelopeV2Error.NON_ZERO_HOP_COUNT)
        }
        val envelopeLength = (container[2].toInt() and 0xFF) shl 8 or (container[3].toInt() and 0xFF)
        if (envelopeLength > 508 || envelopeLength != container.size - 4) {
            throw BarnardOwnEnvelopeV2Exception(BarnardOwnEnvelopeV2Error.ENVELOPE_LENGTH_MISMATCH)
        }
    }

    /**
     * Enables spec 134 participant relay, or disables it when [verifier] is null.
     *
     * The verifier is host-supplied on purpose. Spec 134 step 3 requires the
     * authoritative on-chain definition before an envelope may be relayed, and
     * the SDK has no registry access, so only a
     * [BarnardRelayVerification.RegistryVerified] answer from the host unlocks
     * re-broadcast. The engine pre-filters on its own radio verification: an
     * unverified container never reaches this verifier.
     *
     * [clock] and [eninSource] default to elapsed real time and the engine's
     * own B004 ENIN; they exist so tests can step 30-second decision epochs.
     */
    @JvmOverloads
    public fun configureParticipantRelay(
        verifier: BarnardRelayVerifier?,
        joinedEventProvider: BarnardRelayJoinedEventProvider? = null,
        randomnessSeedMaterial: ByteArray? = null,
        clock: BarnardRelayMonotonicClock? = null,
        eninSource: BarnardRelayEninSource? = null,
    ) {
        val decisions = synchronized(eventInfoStateLock) {
            tearDownParticipantRelayLocked("definition_invalidated")
            relayVerifier = verifier
            relayJoinedEventProvider = joinedEventProvider
            relayClock = clock
            relayEninSource = eninSource
            relaySeedMaterial = randomnessSeedMaterial
                ?: MessageDigest.getInstance("SHA-256").digest(getOrCreateDeviceSecret())
            drainRelayDecisionsLocked()
        }
        emitRelayDecisions(decisions)
        emitDebug("info", "relay_configured", mapOf("enabled" to (verifier != null)))
    }

    /**
     * Runs the relay's expiry, selection, contention, and lease decisions.
     *
     * This is the only path that consults the lease clock. Observations do not
     * take lease decisions, so it must be driven on a timer: a device that
     * stops hearing anything would otherwise keep serving a lease that has
     * already run out. The engine drives it internally while a relay is
     * configured, and also calls it before answering a B005 read. A host that
     * wants tighter control may call it as well, at least at the decision
     * boundary cadence of [RELAY_DECISION_BOUNDARY_MS]; calling it more often
     * is harmless because the relay takes at most one election decision per
     * 30-second epoch.
     */
    public fun advanceParticipantRelay() {
        val decisions = synchronized(eventInfoStateLock) { advanceParticipantRelayLocked() }
        emitRelayDecisions(decisions)
    }

    /**
     * Test seam: the engine's own timer callback, distinct from a host calling
     * [advanceParticipantRelay].
     */
    internal fun relayTimerDidFire() {
        val decisions = synchronized(eventInfoStateLock) {
            // Re-arm first so a teardown inside the advance below wins and
            // leaves no orphan tick queued.
            if (participantRelay != null) scheduleRelayTickLocked()
            advanceParticipantRelayLocked()
        }
        emitRelayDecisions(decisions)
    }

    /** Test seam: whether the self-protecting tick is currently armed. */
    internal val relayTimerIsScheduled: Boolean
        get() = synchronized(eventInfoStateLock) { relayTickRunnable != null }

    private fun scheduleRelayTickLocked() {
        cancelRelayTickLocked()
        val tick = Runnable { relayTimerDidFire() }
        relayTickRunnable = tick
        mainHandler.postDelayed(tick, RELAY_TIMER_INTERVAL_MS)
    }

    private fun cancelRelayTickLocked() {
        relayTickRunnable?.let { mainHandler.removeCallbacks(it) }
        relayTickRunnable = null
    }

    /** True while this device is re-broadcasting a relayed envelope. */
    public val isRelayServing: Boolean
        get() = synchronized(eventInfoStateLock) { participantRelay?.isServing == true }

    private fun advanceParticipantRelayLocked(): List<BarnardRelayDecisionEvent> {
        // Precedence is enforced here rather than at read time, so the relay
        // never holds a lease this device could not actually put on the wire.
        if (isServingOwnEventInfoLocked()) {
            tearDownParticipantRelayLocked("own_value_precedence")
            return drainRelayDecisionsLocked()
        }
        val relay = participantRelay ?: return emptyList()
        relayDecisionReason = if (relay.isServing) "lease_ended" else "elected"
        relay.advance()
        return drainRelayDecisionsLocked()
    }

    /**
     * This device's own B005 event-info value, when it has one to serve.
     *
     * Two forms, and the signed one wins: a host-supplied hop-zero v2
     * container (spec 122), else the v1 [BarnardEventInfoCodec] payload. Both
     * count as an own value everywhere precedence is decided, including the
     * election gate — a device serving a signed hop-zero container of its own
     * cannot put a relayed one on the wire either, so it must not elect or
     * hold density state for one.
     */
    private fun ownEventInfoValueLocked(): ByteArray? = ownEnvelopeV2Container ?: try {
        BarnardEventInfoCodec.payloadIfServing(
            eventInfoServePolicy,
            eventCode,
            eventInfoDisplayName,
            getEventCodeHash(),
        )
    } catch (_: IllegalArgumentException) {
        null
    }

    private fun isServingOwnEventInfoLocked(): Boolean = ownEventInfoValueLocked() != null

    private fun ensureParticipantRelayLocked(): BarnardParticipantRelay? {
        val verifier = relayVerifier ?: return null
        participantRelay?.let { return it }
        val relay = BarnardParticipantRelay(
            clock = relayClock ?: BarnardRelayMonotonicClock { SystemClock.elapsedRealtime() },
            eninSource = relayEninSource ?: BarnardRelayEninSource { currentEnin().toLong() },
            verifier = verifier,
            sink = relaySink,
            joinedEventProvider = relayJoinedEventProvider ?: BarnardRelayJoinedEventProvider { null },
            randomnessSeedMaterial = relaySeedMaterial,
        )
        participantRelay = relay
        scheduleRelayTickLocked()
        return relay
    }

    /**
     * Spec 134: stopping Scan or Advertise clears the lease and the cached
     * envelope. `hostStop()` is terminal, so the instance is dropped and a
     * later observation builds a fresh one that rechecks every guard.
     */
    private fun tearDownParticipantRelayLocked(reason: String) {
        cancelRelayTickLocked()
        val relay = participantRelay ?: return
        relayDecisionReason = reason
        relay.hostStop()
        participantRelay = null
        relayServedContainer = null
        relayLastServedDigest = null
    }

    private fun tearDownParticipantRelay(reason: String) {
        val decisions = synchronized(eventInfoStateLock) {
            tearDownParticipantRelayLocked(reason)
            drainRelayDecisionsLocked()
        }
        emitRelayDecisions(decisions)
    }

    private fun drainRelayDecisionsLocked(): List<BarnardRelayDecisionEvent> {
        if (relayPendingDecisions.isEmpty()) return emptyList()
        val out = relayPendingDecisions.toList()
        relayPendingDecisions.clear()
        return out
    }

    private fun emitRelayDecisions(decisions: List<BarnardRelayDecisionEvent>) {
        for (decision in decisions) {
            emitDebug("info", "relay_decision", mapOf(
                "decision" to decision.decision.name,
                "hop" to decision.hop,
                "reason" to decision.reason,
            ))
            mainHandler.post { onEvent?.invoke(BarnardEvent.RelayDecision(decision)) }
        }
    }

    /** The relayed container this device is currently serving, if any. */
    internal fun relayContainerForServing(): ByteArray? =
        synchronized(eventInfoStateLock) { relayServedContainer }

    /**
     * The value B005 answers a read at offset zero with.
     *
     * Precedence: this device's own event-info value wins over a relayed one.
     * Spec 134 is silent on the collision, and this is the conservative
     * reading -- a device that is itself an organizer-designated direct source
     * must keep serving hop zero rather than demote itself to a forwarder, and
     * the spec's one-payload-at-a-time rule forbids serving both.
     *
     * The own value itself has two forms, and the signed one wins: a
     * host-supplied hop-zero v2 container, else the v1 [BarnardEventInfoCodec]
     * payload, else the relayed container, else the read is refused.
     *
     * [advanceParticipantRelay] enforces the same precedence before this
     * chooses, so a device with an own value has no lease left to fall back to.
     */
    internal fun eventInfoValueForRead(): ByteArray? {
        val decisions: List<BarnardRelayDecisionEvent>
        val value: ByteArray?
        synchronized(eventInfoStateLock) {
            decisions = advanceParticipantRelayLocked()
            value = ownEventInfoValueLocked() ?: relayServedContainer
        }
        emitRelayDecisions(decisions)
        return value
    }

    /**
     * Observer-local peer handle. Spec 134: never transmitted, never persisted
     * beyond the density window, never interpreted as a person or a device.
     */
    private fun relayPeerHandle(address: String): ByteArray = address.toByteArray(Charsets.UTF_8)

    public fun getCurrentEventCode(): String? = eventCode

    public fun getMyDisplayId(): String = BarnardCrypto.displayIdString(currentTek)

    public fun getCurrentRpi(): String {
        val rpik = BarnardCrypto.deriveRpik(currentTek)
        val rpi = BarnardCrypto.generateRpi(rpik, currentEnin())
        return rpi.toHex()
    }

    public fun getCurrentEnin(): Long = currentEnin().toLong()

    /**
     * Explicit privacy egress. The SDK never transmits TEK over BLE; callers
     * decide whether/how to transmit it via another channel. Deprecated
     * (barnard#63): exposing the raw TEK lets anyone derive every RPID and
     * the displayId for it. Prefer [BarnardIdentity.proveRpidOwnership].
     * Kept for parity with the Flutter plugin's `exportCurrentTek`.
     */
    public fun exportCurrentTek(): String = currentTek.toHex()

    public fun getPermissionStatus(): BarnardPermissionStatus = permissionStatusPayload()

    public fun requestPermissions(callback: (BarnardPermissionResult) -> Unit) {
        val missing = requiredRuntimePermissions().filter { !hasPermission(it) }
        if (missing.isEmpty()) {
            callback(BarnardPermissionResult.Granted(permissionStatusPayload()))
            return
        }
        val requestable = missing.filterNot { isPermissionRequestBlocked(it) }
        if (requestable.isEmpty()) {
            callback(BarnardPermissionResult.Granted(permissionStatusPayload()))
            return
        }

        val currentActivity = activity
        if (currentActivity == null) {
            emitDebug("warn", "request_permissions_no_activity", null)
            callback(
                BarnardPermissionResult.Failed(
                    BarnardPermissionError(
                        code = "E_NO_ACTIVITY",
                        message = "requestPermissions requires an attached Activity",
                        status = permissionStatusPayload(),
                    )
                )
            )
            return
        }

        if (pendingPermissionCallback != null) {
            emitDebug("warn", "request_permissions_already_in_progress", null)
            callback(
                BarnardPermissionResult.Failed(
                    BarnardPermissionError(
                        code = "E_PERMISSION_REQUEST_IN_PROGRESS",
                        message = "A Barnard permission request is already in progress",
                        status = permissionStatusPayload(),
                    )
                )
            )
            return
        }

        pendingPermissionCallback = callback
        markPermissionsRequested(requestable)
        currentActivity.requestPermissions(requestable.toTypedArray(), permissionRequestCode)
    }

    /** Forward the hosting `Activity`'s `onRequestPermissionsResult` here. Returns `true` if handled. */
    public fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != permissionRequestCode) return false
        val callback = pendingPermissionCallback ?: return false
        pendingPermissionCallback = null
        callback(BarnardPermissionResult.Granted(permissionStatusPayload()))
        return true
    }

    public fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", appContext.packageName, null)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        (activity ?: appContext).startActivity(intent)
    }

    public fun startScan(allowDuplicates: Boolean = true) {
        if (!isScanning) {
            synchronized(eventInfoStateLock) {
                eventInfoRetryBudget.clearAll()
                eventInfoDiscoverySession = BarnardEventInfoDiscoverySession(System.currentTimeMillis())
            }
        }
        this.allowDuplicates = allowDuplicates
        startScanInternal()
    }

    public fun stopScan() {
        stopScanInternal()
    }

    public fun startAdvertise(formatVersion: Int = 1) {
        this.formatVersion = acceptFormatVersion(formatVersion)
        startAdvertiseInternal()
    }

    public fun stopAdvertise() {
        stopAdvertiseInternal()
    }

    public fun startAuto(
        scanAllowDuplicates: Boolean = true,
        advertiseFormatVersion: Int = 1,
    ): BarnardAutoStartResult {
        allowDuplicates = scanAllowDuplicates
        formatVersion = acceptFormatVersion(advertiseFormatVersion)

        val wasScanning = isScanning
        val wasAdvertising = isAdvertising
        startScanInternal()
        startAdvertiseInternal()
        return BarnardAutoStartResult(
            scanningStarted = !wasScanning && isScanning,
            advertisingStarted = !wasAdvertising && isAdvertising,
        )
    }

    public fun stopAuto() {
        stopScanInternal()
        stopAdvertiseInternal()
    }

    public fun joinEvent(code: String) {
        resetPeerDiscoveryState("join_event")
        eventCode = code
        prefs.edit().putString("eventCode", code).apply()

        val deviceSecret = getOrCreateDeviceSecret()
        currentTek = BarnardCrypto.deriveTekForEvent(deviceSecret, code)

        rebuildGattServerIfNeeded()

        emitState("join_event")
        emitDebug("info", "join_event", mapOf(
            "eventCode" to code,
            "myDisplayId" to BarnardCrypto.displayIdString(currentTek)
        ))
    }

    public fun leaveEvent() {
        resetPeerDiscoveryState("leave_event")
        eventCode = null
        prefs.edit().remove("eventCode").apply()

        val deviceSecret = getOrCreateDeviceSecret()
        currentTek = BarnardCrypto.deriveTekForAnonymous(deviceSecret)

        rebuildGattServerIfNeeded()

        emitState("leave_event")
        emitDebug("info", "leave_event", null)
    }

    // MARK: - Event Mode Control (internal helpers)

    private fun currentEnin(timestampMs: Long = System.currentTimeMillis()): UInt {
        return BarnardCrypto.calculateEnin(
            timestampMs = timestampMs,
            mode = eninMode,
            eninSeconds = eninSeconds,
            beaconChain = beaconChain,
        )
    }

    private fun eninModeName(): String {
        return when (eninMode) {
            BarnardCrypto.EninMode.BEACON_SLOT -> "beaconSlot"
            BarnardCrypto.EninMode.FIXED_LENGTH -> "fixedLength"
        }
    }

    private fun beaconChainInfo(): BarnardBeaconChain = BarnardBeaconChain(
        chainId = beaconChain.chainId,
        genesisUnixSeconds = beaconChain.effectiveGenesisUnixSeconds,
        slotSeconds = beaconChain.effectiveSlotSeconds,
    )

    private fun getEventCodeHash(): ByteArray {
        val code = eventCode ?: return ByteArray(0)
        return BarnardCrypto.computeEventCodeHash(code)
    }

    private fun eventCodeHashMatches(peerHash: ByteArray): Boolean {
        return peerHash.contentEquals(getEventCodeHash())
    }

    // MARK: - DeviceSecret Management

    private fun getOrCreateDeviceSecret(): ByteArray {
        val key = "rpidSeed"
        val existing = prefs.getString(key, null)
        if (existing != null) {
            val bytes = Base64.decode(existing, Base64.DEFAULT)
            if (bytes.size >= 32) return bytes
        }
        val bytes = BarnardCrypto.generateRandomBytes(32)
        prefs.edit().putString(key, Base64.encodeToString(bytes, Base64.NO_WRAP)).apply()
        return bytes
    }

    // MARK: - Scan Control

    private fun startScanInternal() {
        val a = adapter ?: run {
            emitConstraint("bluetooth_unavailable", "BluetoothAdapter is null")
            return
        }
        if (!a.isEnabled) {
            emitConstraint("bluetooth_off", "Bluetooth is disabled")
            return
        }
        if (!hasScanPermission()) {
            emitConstraint("permission_denied", "Missing ${requiredScanPermission()} permission", requiredAction = "grant_permission")
            return
        }
        val s = adapter?.bluetoothLeScanner ?: run {
            emitError("scan_failed", "BluetoothLeScanner is null", recoverable = true)
            return
        }
        if (isScanning) return

        scanCallback?.let { cb ->
            try {
                s.stopScan(cb)
            } catch (e: Exception) {
                Log.w(TAG, "stopScan before start failed: ${e.message}")
            }
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0)
            .build()

        val cb = createScanCallback()
        scanCallback = cb

        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(serviceUuid))
            .build()

        s.startScan(listOf(filter), settings, cb)
        isScanning = true

        s.flushPendingScanResults(cb)
        emitState("scan_start")
        emitDebug("info", "scan_start", mapOf("allowDuplicates" to allowDuplicates))
    }

    private fun stopScanInternal() {
        // Spec 134: stopping Scan clears the relay lease, the density handles,
        // and the cached envelope, whether or not Scan was actually running.
        tearDownParticipantRelay("host_stop")
        if (!isScanning) return
        scanCallback?.let { cb ->
            if (hasScanPermission()) {
                adapter?.bluetoothLeScanner?.stopScan(cb)
            }
        }
        scanCallback = null
        isScanning = false
        cancelConnectWatchdog()
        resetPeerDiscoveryState("scan_stop")

        emitState("scan_stop")
        emitDebug("info", "scan_stop", null)
    }

    private fun resetPeerDiscoveryState(reason: String) {
        connectQueue.clear()
        activeGatt?.close()
        activeGatt = null

        discoveredRssi.clear()
        discoveredAt.clear()
        lastDiscoveryNameById.clear()
        lastConnectAttemptAtMs.clear()
        resolutionBackoffUntilMs.clear()
        pendingBoundaryRetryDevices.clear()
        boundaryRetryBudget.clearAll()
        synchronized(eventInfoStateLock) {
            eventInfoRetryBudget.clearAll()
            eventInfoDiscoverySession = BarnardEventInfoDiscoverySession(System.currentTimeMillis())
        }
        peripheralReadValues.clear()
        knownPeers.clear()

        emitDebug("info", "peer_cache_reset", mapOf("reason" to reason))
    }

    // MARK: - Advertise Control

    private fun startAdvertiseInternal() {
        val a = adapter ?: run {
            emitConstraint("bluetooth_unavailable", "BluetoothAdapter is null")
            return
        }
        if (!a.isEnabled) {
            emitConstraint("bluetooth_off", "Bluetooth is disabled")
            return
        }
        if (!hasAdvertisePermission()) {
            emitConstraint("permission_denied", "Missing BLUETOOTH_ADVERTISE permission", requiredAction = "grant_permission")
            return
        }
        if (!a.isMultipleAdvertisementSupported) {
            emitConstraint("advertise_unsupported", "Multiple advertisement not supported")
            return
        }
        if (!hasConnectPermission()) {
            emitConstraint(
                "permission_denied",
                "Missing BLUETOOTH_CONNECT permission",
                requiredAction = "grant_permission"
            )
            return
        }
        val adv = a.bluetoothLeAdvertiser ?: run {
            emitError("advertise_failed", "BluetoothLeAdvertiser is null", recoverable = true)
            return
        }
        if (isAdvertising) return

        ensureGattServer()

        val localName = if (isDebugBuild()) {
            val deviceSecret = getOrCreateDeviceSecret()
            val tail = if (deviceSecret.size >= 2) {
                deviceSecret.copyOfRange(deviceSecret.size - 2, deviceSecret.size)
            } else {
                deviceSecret
            }
            val suffix = tail.joinToString("") { "%02x".format(it) }.uppercase()
            val debugName = "BND-" + if (suffix.isEmpty()) "DEAD" else suffix
            if (debugOriginalName == null && !a.name.isNullOrEmpty()) {
                debugOriginalName = a.name
            }
            if (a.name != debugName) {
                a.name = debugName
            }
            debugName
        } else {
            "BNRD"
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(serviceUuid))
            .setIncludeDeviceName(isDebugBuild())
            .build()
        adv.startAdvertising(settings, data, advertiseCallback)
        isAdvertising = true
        emitState("advertise_start")
        emitDebug(
            "info",
            "advertise_start",
            mapOf(
                "formatVersion" to formatVersion,
                "serviceUuid" to serviceUuid.toString(),
                "localName" to localName,
            )
        )
    }

    private fun stopAdvertiseInternal() {
        // Spec 134: without Advertise there is no way to serve a relayed value.
        tearDownParticipantRelay("host_stop")
        if (!isAdvertising) return
        if (hasAdvertisePermission()) {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        }
        if (isDebugBuild()) {
            val original = debugOriginalName
            if (original != null && adapter?.name != original) {
                adapter?.name = original
            }
            debugOriginalName = null
        }
        isAdvertising = false
        gattServer?.close()
        gattServer = null
        synchronized(eventInfoStateLock) {
            eventInfoConnectionEpochs.clear()
            eventInfoSnapshots.clear()
        }
        emitState("advertise_stop")
        emitDebug("info", "advertise_stop", null)
    }

    // MARK: - GATT Server (v2)

    @SuppressLint("MissingPermission")
    private fun ensureGattServer() {
        if (gattServer != null) return
        buildAndAddGattServer()
    }

    @SuppressLint("MissingPermission")
    private fun rebuildGattServerIfNeeded() {
        if (!hasConnectPermission()) return
        gattServer?.close()
        gattServer = null
        if (isAdvertising) {
            buildAndAddGattServer()
        }
    }

    @SuppressLint("MissingPermission")
    private fun buildAndAddGattServer() {
        if (!hasConnectPermission()) {
            emitConstraint("permission_denied", "Missing BLUETOOTH_CONNECT permission", requiredAction = "grant_permission")
            return
        }
        val manager = bluetoothManager ?: return
        val server = manager.openGattServer(appContext, gattServerCallback)

        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        // B002 RPID (Read only)
        val rpidCh = BluetoothGattCharacteristic(
            rpidCharUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        service.addCharacteristic(rpidCh)

        // B003 displayId (Read only) — v2: was TEK (r/w), now event-scoped SHA256(TEK)[0:4]
        val displayIdCh = BluetoothGattCharacteristic(
            displayIdCharUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        service.addCharacteristic(displayIdCh)

        // B004 EventCodeHash (Read only)
        val eventCodeHashCh = BluetoothGattCharacteristic(
            eventCodeHashCharUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        service.addCharacteristic(eventCodeHashCh)

        val eventInfoCh = BluetoothGattCharacteristic(
            eventInfoCharUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        service.addCharacteristic(eventInfoCh)

        server.addService(service)
        gattServer = server
        emitDebug("info", "gatt_server_started", mapOf(
            "characteristics" to listOf("RPID", "displayId", "EventCodeHash", "eventInfo")
        ))
    }

    // MARK: - RPID Payload Generation

    /**
     * Build the 17-byte RPID wire form at [nowMs], atomically deriving ENIN
     * and RPI from the same timestamp.
     *
     * A cache hit returns the same array instance; callers must not mutate it.
     */
    @Synchronized
    private fun computePayload(nowMs: Long): ByteArray {
        val enin = currentEnin(nowMs)
        val tek = currentTek
        val cached = cachedReporterPayload
        if (cached != null && cached.enin == enin && cached.tek.contentEquals(tek)) {
            return cached.payload
        }

        val rpik = BarnardCrypto.deriveRpik(tek)
        val rpi = BarnardCrypto.generateRpi(rpik, enin)

        val payload = ByteArray(17)
        payload[0] = (formatVersion and 0xFF).toByte()
        System.arraycopy(rpi, 0, payload, 1, 16)
        cachedReporterPayload = CachedReporterPayload(enin, tek.copyOf(), payload)
        return payload
    }

    // MARK: - Event Emission

    private fun emitState(reasonCode: String?) {
        val state = BarnardState(
            isScanning = isScanning,
            isAdvertising = isAdvertising,
            eventCode = eventCode,
            eninMode = BarnardEninMode.fromInternal(eninMode),
            eninSeconds = eninSeconds,
            beaconChain = beaconChainInfo(),
            reasonCode = reasonCode,
        )
        mainHandler.post { onEvent?.invoke(BarnardEvent.State(state)) }
    }

    private fun emitConstraint(code: String, message: String?, requiredAction: String? = null) {
        val constraint = BarnardConstraintEvent(code = code, message = message, requiredAction = requiredAction)
        mainHandler.post { onEvent?.invoke(BarnardEvent.Constraint(constraint)) }
    }

    private fun emitError(code: String, message: String, recoverable: Boolean? = null) {
        val error = BarnardErrorEvent(code = code, message = message, recoverable = recoverable)
        mainHandler.post { onEvent?.invoke(BarnardEvent.Error(error)) }
    }

    private fun emitEventInfoHint(address: String, eventInfo: BarnardEventInfo) {
        val observation = synchronized(eventInfoStateLock) {
            eventInfoDiscoverySession.observe(eventInfo, System.currentTimeMillis())
        }
        val hint = BarnardEventInfoHintEvent(
            peripheralId = address,
            eventInfo = eventInfoForDiscoveryHint(eventInfo, observation.shouldEmitGenericHint),
            additionalNamesOmitted = observation.additionalNamesOmitted,
            additionalEventsOmitted = observation.additionalEventsOmitted,
        )
        mainHandler.post { onEvent?.invoke(BarnardEvent.EventInfoHint(hint)) }
    }

    /**
     * The B005 event-info read path with the Bluetooth plumbing removed:
     * everything `onCharacteristicRead` does with the characteristic value,
     * minus tearing the connection down. [BluetoothGatt] cannot be constructed
     * in a unit test, so this is the seam the tests drive.
     *
     * A container whose first byte is [BarnardB005EnvelopeV2.FORMAT_VERSION]
     * (0x03) is a spec 122 v2 signed envelope and is verified in the SDK: hosts
     * have no GATT access of their own, so leaving the verify call to them
     * would make the verifier unreachable from the radio path. Everything else
     * stays on the unchanged v1 hint path.
     */
    internal fun processEventInfoValue(
        address: String,
        value: ByteArray,
        b004EventCodeHash: ByteArray,
        currentEnin: Long,
    ) {
        if (value.isNotEmpty() && value[0].toInt() == BarnardB005EnvelopeV2.FORMAT_VERSION) {
            processEventInfoEnvelopeV2(address, value, currentEnin)
            return
        }

        try {
            val hint = BarnardEventInfoCodec.parse(value)
            if (!BarnardEventInfoCodec.matchesB004(hint, b004EventCodeHash)) {
                eventInfoRetryBudget.recordSemanticUnavailable(address)
                emitDebug("info", "gatt_event_info_unavailable", mapOf("address" to address, "reason" to "b004_mismatch"))
                return
            }
            emitDebug("info", "gatt_event_info_hint", mapOf(
                "address" to address,
                "eventCodeHash" to hint.eventCodeHash.toHex(),
            ) + if (isDebugBuild()) mapOf("displayName" to hint.eventDisplayName) else emptyMap())
            eventInfoRetryBudget.recordSuccessfulAttempt(address, System.currentTimeMillis())
            emitEventInfoHint(address, hint)
        } catch (_: IllegalArgumentException) {
            eventInfoRetryBudget.recordSemanticUnavailable(address)
            emitDebug("info", "gatt_event_info_unavailable", mapOf("address" to address))
        }
    }

    private fun processEventInfoEnvelopeV2(address: String, container: ByteArray, currentEnin: Long) {
        val verified = BarnardB005EnvelopeV2.verify(container, currentEnin)
        val receipt = verified?.let { BarnardB005EnvelopeV2Receipt.RadioSelfVerified(it) }
            ?: BarnardB005EnvelopeV2Receipt.Unverified

        // A container came back, so the GATT exchange succeeded, and this consumes
        // one of the peer's two session attempts exactly as a valid v1 hint does.
        // Verification failure is not radio unavailability: marking the peer
        // semantically unavailable would bar every further read of it for the rest
        // of the discovery session, including one whose envelope becomes valid in
        // a later ENIN.
        eventInfoRetryBudget.recordSuccessfulAttempt(address, System.currentTimeMillis())
        emitDebug("info", "gatt_event_info_envelope_v2", mapOf(
            "address" to address,
            "bytes" to container.size,
            "receiverState" to receipt.receiverState.name,
        ))
        val event = BarnardEventInfoEnvelopeV2Event(
            peripheralId = address,
            receipt = receipt,
            rawContainer = container,
        )
        mainHandler.post { onEvent?.invoke(BarnardEvent.EventInfoEnvelopeV2(event)) }

        // Spec 134: only a receipt that this device verified from the radio is
        // offered to the relay. The relay's own host-supplied verifier then
        // applies step 3 (registry agreement) before any re-broadcast.
        if (receipt !is BarnardB005EnvelopeV2Receipt.RadioSelfVerified) return
        val decisions = synchronized(eventInfoStateLock) {
            // A device serving its own event-info value cannot put a relayed
            // container on the wire, so it does not observe, elect, or hold
            // density state for one.
            if (isServingOwnEventInfoLocked()) {
                tearDownParticipantRelayLocked("own_value_precedence")
                return@synchronized drainRelayDecisionsLocked()
            }
            val relay = ensureParticipantRelayLocked() ?: return@synchronized emptyList()
            // Observe only. Spec 134 takes lease decisions "at each 30-second
            // decision boundary", not on arrival, and `observe` already does
            // the dedup, hop retention and selection that an observation is
            // responsible for. Deciding here instead would fix each epoch's
            // decision to the density observed at that epoch's *first*
            // arrival, so a burst of neighbours arriving moments later could
            // not suppress it. Decisions run in [advanceParticipantRelay],
            // which the host calls at its scheduled wake-up and which the B005
            // read path calls before answering.
            relay.observe(container, relayPeerHandle(address))
            drainRelayDecisionsLocked()
        }
        emitRelayDecisions(decisions)
    }

    /**
     * Emit v2 detection event. Byte-valued fields are lowercase hex.
     */
    private fun emitDetection(
        timestampMs: Long,
        rssi: Int,
        payloadBytes: ByteArray,
        detectedDisplayIdHex: String?,
        debugLocalName: String? = null
    ) {
        if (payloadBytes.size != 17) {
            emitDebug("warn", "payload_invalid_length", mapOf("length" to payloadBytes.size))
            return
        }
        val version = payloadBytes[0].toInt() and 0xFF
        if (version != 1) {
            emitDebug("warn", "payload_unsupported_version", mapOf("formatVersion" to version))
            return
        }

        // Atomic reporter snapshot at the observation timestamp.
        val reporterPayload = computePayload(timestampMs)
        val enin = currentEnin(timestampMs).toLong()

        val resolvedDebugLocalName = if (isDebugBuild()) debugLocalName else null

        val detection = BarnardDetectionEvent(
            timestampMs = timestampMs,
            rssi = rssi,
            formatVersion = version,
            rpid = payloadBytes.toHex(),
            reporterRpid = reporterPayload.toHex(),
            detectedDisplayId = detectedDisplayIdHex,
            enin = enin,
            debugLocalName = resolvedDebugLocalName,
        )
        mainHandler.post { onEvent?.invoke(BarnardEvent.Detection(detection)) }
    }

    private fun emitRssiUpdate(address: String, rssi: Int, timestampMs: Long) {
        if (!isUsableRssi(rssi)) return
        val peer = knownPeers[address] ?: return

        // Atomic reporter snapshot (same contract as DetectionEvent).
        val reporterPayload = computePayload(timestampMs)
        val enin = currentEnin(timestampMs).toLong()

        val update = BarnardRssiUpdateEvent(
            timestampMs = timestampMs,
            rssi = rssi,
            rpid = peer.rpid.toHex(),
            reporterRpid = reporterPayload.toHex(),
            enin = enin,
            detectedDisplayId = peer.detectedDisplayId,
            debugLocalName = if (isDebugBuild()) peer.debugLocalName else null,
        )
        mainHandler.post { onEvent?.invoke(BarnardEvent.RssiUpdate(update)) }
    }

    private fun isUsableRssi(rssi: Int): Boolean {
        return rssi != unavailableRssi
    }

    private fun emitDebug(level: String, name: String, data: Map<String, Any?>?) {
        val event = BarnardDebugEvent(
            timestampMs = System.currentTimeMillis(),
            level = level,
            name = name,
            data = data,
        )
        mainHandler.post { onDebugEvent?.invoke(event) }
    }

    /**
     * Accept a caller-provided formatVersion. v2 only ships format 1, so
     * clamp to 1 and emit a debug warning otherwise. Advertising format 2+
     * would make the device silently undiscoverable to all v2 peers.
     */
    private fun acceptFormatVersion(raw: Int?): Int {
        val v = raw ?: return 1
        if (v == 1) return 1
        emitDebug("warn", "format_version_clamped", mapOf("requested" to v, "applied" to 1))
        return 1
    }

    // MARK: - Permissions

    private fun permissionStatusPayload(): BarnardPermissionStatus {
        val required = requiredRuntimePermissions()
        val missing = required.filter { !hasPermission(it) }
        val blocked = missing.filter { isPermissionRequestBlocked(it) }
        val requestable = missing.filterNot { blocked.contains(it) }
        val permissions = required.associateWith { permission ->
            if (hasPermission(permission)) "granted" else "denied"
        }
        // BLE capability requires both runtime permission AND hardware support.
        // Android Emulator and BLE-less devices report permission grants but
        // cannot actually scan or advertise — host apps would otherwise enable
        // BLE-only UI based on permission state alone. See issue #57.
        val hasBleHardware = appContext.packageManager
            .hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val a = adapter
        val hasAdvertiseHardware = hasBleHardware &&
            a != null &&
            a.bluetoothLeAdvertiser != null &&
            a.isMultipleAdvertisementSupported
        return BarnardPermissionStatus(
            platform = "android",
            permissions = permissions,
            requiredPermissions = required,
            missingPermissions = missing,
            requestablePermissions = requestable,
            blockedPermissions = blocked,
            canScan = hasScanPermission() && hasBleHardware,
            canAdvertise = hasAdvertisePermission() && hasConnectPermission() && hasAdvertiseHardware,
        )
    }

    private fun requiredRuntimePermissions(): List<String> {
        return when {
            Build.VERSION.SDK_INT >= 31 -> listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
            Build.VERSION.SDK_INT >= 23 -> listOf(Manifest.permission.ACCESS_FINE_LOCATION)
            else -> emptyList()
        }
    }

    private fun hasPermission(permission: String): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        return appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun isPermissionRequestBlocked(permission: String): Boolean {
        if (Build.VERSION.SDK_INT < 23 || hasPermission(permission)) return false
        val currentActivity = activity ?: return false
        return isRuntimePermissionRequestBlocked(
            sdkInt = Build.VERSION.SDK_INT,
            hasPermission = false,
            wasRequestedBefore = wasPermissionRequested(permission),
            shouldShowRequestPermissionRationale =
                currentActivity.shouldShowRequestPermissionRationale(permission)
        )
    }

    private fun markPermissionsRequested(permissions: List<String>) {
        if (permissions.isEmpty()) return
        prefs.edit().apply {
            for (permission in permissions) {
                putBoolean(permissionRequestedKey(permission), true)
            }
        }.apply()
    }

    private fun wasPermissionRequested(permission: String): Boolean {
        return prefs.getBoolean(permissionRequestedKey(permission), false)
    }

    private fun permissionRequestedKey(permission: String): String {
        return "$permissionRequestedKeyPrefix$permission"
    }

    private fun hasScanPermission(): Boolean {
        return when {
            Build.VERSION.SDK_INT >= 31 -> hasPermission(Manifest.permission.BLUETOOTH_SCAN)
            Build.VERSION.SDK_INT >= 23 -> hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            else -> true
        }
    }

    private fun requiredScanPermission(): String {
        return if (Build.VERSION.SDK_INT >= 31) {
            Manifest.permission.BLUETOOTH_SCAN
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
    }

    private fun hasAdvertisePermission(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    }

    private fun hasConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
    }

    // MARK: - Advertise Callback

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            emitError("advertise_failed", "errorCode=$errorCode", recoverable = true)
            isAdvertising = false
            emitState("advertise_failed")
        }

        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            emitDebug("info", "advertise_started", null)
        }
    }

    // MARK: - Scan Callback

    private var scanCallback: ScanCallback? = null

    private fun createScanCallback(): ScanCallback {
        return object : ScanCallback() {
            override fun onScanFailed(errorCode: Int) {
                Log.e(TAG, "onScanFailed: errorCode=$errorCode")
                emitError("scan_failed", "errorCode=$errorCode", recoverable = true)
                isScanning = false
                emitState("scan_failed")
            }

            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handleScanResult(result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                for (r in results) handleScanResult(r)
            }
        }
    }

    private fun handleScanResult(result: ScanResult) {
        val device = result.device ?: return
        val address = device.address ?: return
        if (!isBarnardScanResult(result)) {
            emitDebug(
                "trace",
                "scan_ignored",
                mapOf(
                    "address" to address,
                    "name" to result.scanRecord?.deviceName,
                    "hasService" to (result.scanRecord?.serviceUuids?.any { it.uuid == serviceUuid } == true),
                    "isConnectable" to isConnectableResult(result),
                )
            )
            return
        }
        val nowMs = System.currentTimeMillis()
        if (!isUsableRssi(result.rssi)) {
            emitDebug("trace", "ble_discovery_rssi_unavailable", mapOf(
                "id" to address,
                "rssi" to result.rssi,
                "name" to result.scanRecord?.deviceName
            ))
            return
        }
        if (!allowDuplicates) {
            val last = discoveredAt[address]
            if (last != null && nowMs - last < 2_000) return
        }
        discoveredRssi[address] = result.rssi
        discoveredAt[address] = nowMs
        if (isDebugBuild()) {
            result.scanRecord?.deviceName?.let { name ->
                if (name.isNotEmpty()) lastDiscoveryNameById[address] = name
            }
        }

        emitDebug("trace", "ble_discovery_result", mapOf(
            "id" to address,
            "rssi" to result.rssi,
            "name" to result.scanRecord?.deviceName
        ))

        val knownPeer = knownPeers[address]
        if (knownPeer != null) {
            val currentEnin = currentEnin(nowMs).toLong()
            if (BarnardV2Policy.shouldEmitRssiUpdate(knownPeer.enin, currentEnin)) {
                emitRssiUpdate(address, result.rssi, nowMs)
            } else {
                knownPeers.remove(address)
                emitDebug("trace", "known_peer_rpid_expired", mapOf(
                    "address" to address,
                    "cachedEnin" to knownPeer.enin,
                    "currentEnin" to currentEnin,
                ))
                // Force a fresh resolution. enqueueConnect dedups against in-flight /
                // queued connects, so following advertisements on the same address
                // remain safe.
                enqueueConnect(device)
            }
        } else if (isResolutionBackedOff(address, nowMs)) {
            emitResolutionBackoff(address, nowMs)
        } else {
            enqueueConnect(device)
        }
    }

    private fun isBarnardScanResult(result: ScanResult): Boolean {
        val record = result.scanRecord ?: return false
        val uuids = record.serviceUuids
        val hasService = uuids?.any { it.uuid == serviceUuid } == true
        val name = record.deviceName
        val isBnrd = name == "BNRD" || (isDebugBuild() && name?.startsWith("BND-") == true)
        if (hasService) return true
        if (isBnrd) return true
        return false
    }

    private fun isConnectableResult(result: ScanResult): Boolean {
        return if (Build.VERSION.SDK_INT >= 26) {
            result.isConnectable
        } else {
            true
        }
    }

    // MARK: - Connection Queue

    private fun enqueueConnect(device: BluetoothDevice) {
        val address = device.address ?: return
        val nowMs = System.currentTimeMillis()
        if (isResolutionBackedOff(address, nowMs)) {
            emitResolutionBackoff(address, nowMs)
            return
        }
        if (connectQueue.any { it.address == address }) return
        if (activeGatt?.device?.address == address) return

        if (connectQueue.size >= maxConnectQueue) {
            emitDebug("warn", "connect_queue_full", mapOf("max" to maxConnectQueue))
            return
        }
        connectQueue.add(device)
        pumpConnectQueue()
    }

    @SuppressLint("MissingPermission")
    private fun pumpConnectQueue() {
        if (activeGatt != null) return
        val device = connectQueue.removeFirstOrNull() ?: return
        val nowMs = System.currentTimeMillis()
        val key = device.address ?: ""
        val last = lastConnectAttemptAtMs[key]
        if (last != null && nowMs - last < cooldownPerPeerMs) {
            connectQueue.add(device)
            val remainingMs = cooldownPerPeerMs - (nowMs - last)
            mainHandler.postDelayed({ pumpConnectQueue() }, remainingMs + 50)
            return
        }
        if (!hasConnectPermission()) {
            emitConstraint("permission_denied", "Missing BLUETOOTH_CONNECT permission", requiredAction = "grant_permission")
            return
        }
        lastConnectAttemptAtMs[key] = nowMs
        peripheralReadValues[key] = GattReadValues()

        activeGatt =
            if (Build.VERSION.SDK_INT >= 23) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        emitDebug("trace", "connect_attempt", mapOf("address" to device.address))
        armConnectWatchdog(device.address ?: "")
    }

    @SuppressLint("MissingPermission")
    private fun armConnectWatchdog(address: String) {
        connectWatchdog?.let { mainHandler.removeCallbacks(it) }
        val task = Runnable {
            val current = activeGatt?.device?.address
            if (current != address) return@Runnable
            emitDebug(
                "warn",
                "connect_timeout",
                mapOf("address" to address, "ms" to connectTimeoutMs)
            )
            markGattResolutionFailed(
                address = address,
                reason = "connect_timeout",
                recoverable = true,
                extra = mapOf("ms" to connectTimeoutMs)
            )
            activeGatt?.close()
            activeGatt = null
            peripheralReadValues.remove(address)
            lastDiscoveryNameById.remove(address)
            pumpConnectQueue()
        }
        connectWatchdog = task
        mainHandler.postDelayed(task, connectTimeoutMs)
    }

    private fun cancelConnectWatchdog() {
        connectWatchdog?.let { mainHandler.removeCallbacks(it) }
        connectWatchdog = null
    }

    private fun isResolutionBackedOff(address: String, nowMs: Long): Boolean {
        val until = resolutionBackoffUntilMs[address] ?: return false
        if (nowMs < until) return true
        resolutionBackoffUntilMs.remove(address)
        return false
    }

    private fun emitResolutionBackoff(address: String, nowMs: Long) {
        val until = resolutionBackoffUntilMs[address] ?: return
        emitDebug(
            "trace",
            "gatt_resolution_backoff",
            mapOf(
                "address" to address,
                "remainingMs" to (until - nowMs).coerceAtLeast(0),
            )
        )
    }

    private fun markGattResolutionFailed(
        address: String,
        reason: String,
        recoverable: Boolean,
        extra: Map<String, Any?> = emptyMap()
    ) {
        if (address.isEmpty()) return
        val backoffMs = if (recoverable) resolutionFailureBackoffMs else resolutionRejectedBackoffMs
        resolutionBackoffUntilMs[address] = System.currentTimeMillis() + backoffMs
        emitDebug(
            if (recoverable) "warn" else "info",
            "gatt_resolution_failed",
            mapOf(
                "address" to address,
                "reason" to reason,
                "recoverable" to recoverable,
                "backoffMs" to backoffMs,
            ) + extra
        )
    }

    // MARK: - GATT Exchange Logic (Central, v2 flow)

    @SuppressLint("MissingPermission")
    private fun finishConnection(gatt: BluetoothGatt) {
        val address = gatt.device?.address ?: ""
        peripheralReadValues.remove(address)
        lastDiscoveryNameById.remove(address)
        gatt.disconnect()
    }

    private fun retryAfterRpidBoundaryCrossing(gatt: BluetoothGatt, address: String) {
        if (!boundaryRetryBudget.consume(address)) {
            markGattResolutionFailed(
                address = address,
                reason = "rpid_boundary_retry_exhausted",
                recoverable = true,
                extra = mapOf("maxRetries" to boundaryRetryBudget.maxRetries)
            )
            finishConnection(gatt)
            return
        }
        val device = gatt.device
        lastConnectAttemptAtMs.remove(address)
        if (device != null) {
            pendingBoundaryRetryDevices[address] = device
        }
        finishConnection(gatt)
    }

    private fun schedulePendingBoundaryRetry(address: String) {
        val device = pendingBoundaryRetryDevices.remove(address) ?: return
        mainHandler.postDelayed(
            {
                if (isScanning) enqueueConnect(device)
            },
            BarnardCrypto.rpidBoundaryRetryDelayMs
        )
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (activeGatt !== gatt) {
                emitDebug("trace", "stale_connection_callback_ignored", mapOf(
                    "address" to (gatt.device?.address ?: ""),
                    "status" to status,
                    "newState" to newState,
                ))
                return
            }
            if (status != BluetoothGatt.GATT_SUCCESS) {
                cancelConnectWatchdog()
                emitError("connect_failed", "status=$status", recoverable = true)
                val address = gatt.device?.address ?: ""
                markGattResolutionFailed(
                    address = address,
                    reason = "connect_failed",
                    recoverable = true,
                    extra = mapOf("status" to status)
                )
                gatt.close()
                peripheralReadValues.remove(address)
                lastDiscoveryNameById.remove(address)
                activeGatt = null
                pumpConnectQueue()
                return
            }
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                cancelConnectWatchdog()
                emitDebug("trace", "connected", mapOf("address" to gatt.device.address))
                gatt.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                cancelConnectWatchdog()
                val address = gatt.device?.address ?: ""
                peripheralReadValues.remove(address)
                lastDiscoveryNameById.remove(address)
                gatt.close()
                activeGatt = null
                schedulePendingBoundaryRetry(address)
                pumpConnectQueue()
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                markGattResolutionFailed(
                    address = gatt.device?.address ?: "",
                    reason = "service_discovery_failed",
                    recoverable = true,
                    extra = mapOf("status" to status)
                )
                emitError("service_discovery_failed", "status=$status", recoverable = true)
                finishConnection(gatt)
                return
            }
            val svc = gatt.getService(serviceUuid)
            if (svc == null) {
                markGattResolutionFailed(
                    address = gatt.device?.address ?: "",
                    reason = "service_not_found",
                    recoverable = true
                )
                emitError("service_not_found", "Barnard service not found", recoverable = true)
                finishConnection(gatt)
                return
            }

            readB004ForResolution(gatt, svc)
        }

        @SuppressLint("MissingPermission")
        private fun readB004ForResolution(gatt: BluetoothGatt, svc: BluetoothGattService) {
            val eventCodeHashCh = svc.getCharacteristic(eventCodeHashCharUuid)
            if (eventCodeHashCh != null && hasConnectPermission()) {
                if (gatt.readCharacteristic(eventCodeHashCh)) return
                markGattResolutionFailed(
                    address = gatt.device?.address ?: "",
                    reason = "b004_read_not_started",
                    recoverable = true
                )
                finishConnection(gatt)
            } else {
                markGattResolutionFailed(
                    address = gatt.device?.address ?: "",
                    reason = "b004_missing",
                    recoverable = true
                )
                emitDebug("warn", "gatt_b004_missing", mapOf(
                    "address" to (gatt.device?.address ?: "")
                ))
                finishConnection(gatt)
            }
        }

        @SuppressLint("MissingPermission")
        private fun readEventInfoAfterResolution(gatt: BluetoothGatt, svc: BluetoothGattService) {
            val address = gatt.device?.address ?: ""
            val eventInfoCh = svc.getCharacteristic(eventInfoCharUuid)
            if (eventInfoCh == null || !hasConnectPermission()) {
                eventInfoRetryBudget.recordSemanticUnavailable(address)
                emitDebug("info", "gatt_event_info_unavailable", mapOf("address" to address, "reason" to "missing"))
                finishConnection(gatt)
                return
            }
            if (!eventInfoRetryBudget.canStart(address, System.currentTimeMillis())) {
                finishConnection(gatt)
                return
            }
            if (!gatt.readCharacteristic(eventInfoCh)) retryEventInfoRead(gatt, "read_not_started")
        }

        private fun retryEventInfoRead(gatt: BluetoothGatt, reason: String) {
            val address = gatt.device?.address ?: ""
            val nowMs = System.currentTimeMillis()
            val deadlineMs = eventInfoRetryBudget.recordRecoverableFailure(address, nowMs)
            emitDebug("info", "gatt_event_info_unavailable", mapOf("address" to address, "reason" to reason))
            val device = gatt.device
            finishConnection(gatt)
            if (deadlineMs != null && device != null) {
                mainHandler.postDelayed({
                    if (isScanning) {
                        lastConnectAttemptAtMs.remove(address)
                        enqueueConnect(device)
                    }
                }, deadlineMs - nowMs)
            }
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val value = characteristic.value ?: ByteArray(0)
            handleCharacteristicRead(gatt, characteristic.uuid, status, value)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            handleCharacteristicRead(gatt, characteristic.uuid, status, value)
        }

        @SuppressLint("MissingPermission")
        private fun handleCharacteristicRead(gatt: BluetoothGatt, uuid: UUID, status: Int, value: ByteArray) {
            val address = gatt.device?.address ?: ""
            val svc = gatt.getService(serviceUuid) ?: run {
                finishConnection(gatt)
                return
            }

            // v2 failure policy: B003 read failure keeps the detection flow alive
            // with detectedDisplayId=null. B002/B004 failures still drop.
            if (status != BluetoothGatt.GATT_SUCCESS) {
                if (uuid == eventInfoCharUuid) {
                    if (status == BluetoothGatt.GATT_READ_NOT_PERMITTED) {
                        eventInfoRetryBudget.recordSemanticUnavailable(address)
                        emitDebug("info", "gatt_event_info_unavailable", mapOf("address" to address, "reason" to "read_not_permitted"))
                        finishConnection(gatt)
                    } else {
                        retryEventInfoRead(gatt, "status=$status")
                    }
                    return
                }
                if (uuid == displayIdCharUuid) {
                    emitDebug("warn", "gatt_b003_read_failed", mapOf(
                        "address" to address,
                        "status" to status,
                    ))
                    peripheralReadValues[address]?.detectedDisplayId = null
                    completeGattExchange(gatt)
                    return
                }
                markGattResolutionFailed(
                    address = address,
                    reason = "read_failed",
                    recoverable = true,
                    extra = mapOf(
                        "status" to status,
                        "characteristic" to uuid.toString(),
                    )
                )
                emitError("read_failed", "status=$status uuid=$uuid", recoverable = true)
                finishConnection(gatt)
                return
            }

            when (uuid) {
                eventInfoCharUuid -> {
                    processEventInfoValue(
                        address = address,
                        value = value,
                        b004EventCodeHash = peripheralReadValues[address]?.eventCodeHash ?: ByteArray(0),
                        currentEnin = currentEnin().toLong(),
                    )
                    finishConnection(gatt)
                }
                eventCodeHashCharUuid -> {
                    peripheralReadValues[address]?.eventCodeHash = value
                    val matches = eventCodeHashMatches(value)
                    emitDebug("trace", "gatt_read_event_code_hash", mapOf(
                        "address" to address,
                        "bytes" to value.size,
                        "isEmpty" to value.isEmpty(),
                        "matches" to matches
                    ))
                    if (!matches) {
                        markGattResolutionFailed(
                            address = address,
                            reason = "b004_mismatch",
                            recoverable = false,
                            extra = mapOf("bytes" to value.size)
                        )
                        emitDebug("info", "gatt_b004_mismatch", mapOf(
                            "address" to address,
                            "bytes" to value.size
                        ))
                        readEventInfoAfterResolution(gatt, svc)
                        return
                    }
                    val rpidCh = svc.getCharacteristic(rpidCharUuid)
                    if (rpidCh != null && hasConnectPermission()) {
                        peripheralReadValues[address]?.rpidReadStartedAtMs = System.currentTimeMillis()
                        gatt.readCharacteristic(rpidCh)
                    } else {
                        markGattResolutionFailed(
                            address = address,
                            reason = "b002_missing",
                            recoverable = true
                        )
                        readEventInfoAfterResolution(gatt, svc)
                    }
                }

                rpidCharUuid -> {
                    peripheralReadValues[address]?.rpid = value
                    peripheralReadValues[address]?.rpidReadCompletedAtMs = System.currentTimeMillis()
                    emitDebug("trace", "gatt_read_rpid", mapOf(
                        "address" to address,
                        "bytes" to value.size
                    ))
                    // v2: always read B003 next.
                    val displayIdCh = svc.getCharacteristic(displayIdCharUuid)
                    if (displayIdCh != null && hasConnectPermission()) {
                        gatt.readCharacteristic(displayIdCh)
                    } else {
                        emitDebug("warn", "gatt_b003_missing", mapOf(
                            "address" to address,
                        ))
                        completeGattExchange(gatt)
                    }
                }

                displayIdCharUuid -> {
                    if (value.size == 4) {
                        peripheralReadValues[address]?.detectedDisplayId = value
                        emitDebug("trace", "gatt_read_display_id", mapOf(
                            "address" to address,
                            "displayId" to value.toHex(),
                        ))
                    } else {
                        emitDebug("warn", "gatt_b003_invalid_length", mapOf(
                            "address" to address,
                            "length" to value.size,
                        ))
                        peripheralReadValues[address]?.detectedDisplayId = null
                    }
                    completeGattExchange(gatt)
                }
            }
        }

        private fun completeGattExchange(gatt: BluetoothGatt) {
            val address = gatt.device?.address ?: ""
            val values = peripheralReadValues[address]

            val rpidData = values?.rpid
            if (rpidData != null) {
                val rssi = discoveredRssi[address] ?: 0
                val completedAtMs = values.rpidReadCompletedAtMs ?: System.currentTimeMillis()
                val stablePeerEnin = BarnardCrypto.stableReadEnin(
                    startedAtMs = values.rpidReadStartedAtMs ?: completedAtMs,
                    completedAtMs = completedAtMs,
                    mode = eninMode,
                    eninSeconds = eninSeconds,
                    beaconChain = beaconChain,
                )
                if (stablePeerEnin == null) {
                    emitDebug("warn", "gatt_rpid_read_crossed_enin_boundary", mapOf(
                        "address" to address,
                        "startedAtMs" to values.rpidReadStartedAtMs,
                        "completedAtMs" to completedAtMs,
                    ))
                    retryAfterRpidBoundaryCrossing(gatt, address)
                    return
                }
                val detectedDisplayIdHex = values.detectedDisplayId?.toHex()
                emitDetection(completedAtMs, rssi, rpidData, detectedDisplayIdHex, lastDiscoveryNameById[address])
                resolutionBackoffUntilMs.remove(address)
                boundaryRetryBudget.clear(address)

                if (rpidData.size == 17) {
                    knownPeers[address] = KnownPeer(
                        rpidData,
                        stablePeerEnin.toLong(),
                        detectedDisplayIdHex,
                        lastDiscoveryNameById[address]
                    )
                }
            }

            val svc = gatt.getService(serviceUuid)
            if (svc == null) finishConnection(gatt) else readEventInfoAfterResolution(gatt, svc)
        }
    }

    // MARK: - GATT Server Callback (v2)

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            val address = device.address ?: return
            synchronized(eventInfoStateLock) {
                eventInfoSnapshots.keys.removeAll { it.startsWith("$address:") }
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    eventInfoConnectionEpochs[address] = (eventInfoConnectionEpochs[address] ?: 0L) + 1L
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            val server = gattServer ?: return

            when (characteristic.uuid) {
                rpidCharUuid -> {
                    val payload = computePayload(System.currentTimeMillis())
                    val slice =
                        if (offset <= 0) payload
                        else if (offset >= payload.size) ByteArray(0)
                        else payload.copyOfRange(offset, payload.size)
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
                    emitDebug(
                        "trace",
                        "gatt_respond_rpid",
                        mapOf(
                            "bytes" to payload.size,
                            "formatVersion" to (payload[0].toInt() and 0xFF),
                        )
                    )
                }

                displayIdCharUuid -> {
                    if (!BarnardV2Policy.shouldServeGattDisplayId(eventCode)) {
                        server.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, offset, null)
                        emitDebug("trace", "gatt_reject_display_id_read", mapOf(
                            "reason" to "not_joined_to_event"
                        ))
                        return
                    }

                    // v2: event-scoped 4-byte SHA256(TEK)[0:4].
                    val displayId = BarnardCrypto.displayId4(currentTek)
                    val slice =
                        if (offset <= 0) displayId
                        else if (offset >= displayId.size) ByteArray(0)
                        else displayId.copyOfRange(offset, displayId.size)
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
                    emitDebug("trace", "gatt_respond_display_id", mapOf(
                        "bytes" to displayId.size
                    ))
                }

                eventCodeHashCharUuid -> {
                    val hash = getEventCodeHash()
                    val slice =
                        if (offset <= 0) hash
                        else if (offset >= hash.size) ByteArray(0)
                        else hash.copyOfRange(offset, hash.size)
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
                    emitDebug("trace", "gatt_respond_event_code_hash", mapOf(
                        "bytes" to hash.size,
                        "isEmpty" to hash.isEmpty()
                    ))
                }

                eventInfoCharUuid -> {
                    respondEventInfoRead(server, device, requestId, offset)
                }

                else -> {
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            // v2 has no writable characteristics.
            val server = gattServer ?: return
            if (responseNeeded) {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, offset, null)
            }
            emitDebug("warn", "gatt_write_rejected", mapOf(
                "uuid" to characteristic.uuid.toString(),
            ))
        }
    }

    @SuppressLint("MissingPermission")
    private fun respondEventInfoRead(server: BluetoothGattServer, device: BluetoothDevice, requestId: Int, offset: Int) {
        data class Outcome(val status: Int, val value: ByteArray?)
        // Own value vs relayed value is decided here, outside the lock's
        // snapshot bookkeeping, because it advances the relay first.
        val offsetZeroValue = if (offset == 0) eventInfoValueForRead() else null
        val outcome = synchronized(eventInfoStateLock) {
            val now = System.currentTimeMillis()
            eventInfoSnapshots.entries.removeIf { now - it.value.lastRequestAtMs > 30_000L }
            val address = device.address ?: ""
            val key = "$address:${eventInfoConnectionEpochs[address] ?: 0L}"
            if (offset == 0) {
                if (offsetZeroValue == null) {
                    return@synchronized Outcome(BluetoothGatt.GATT_READ_NOT_PERMITTED, null)
                }
                eventInfoSnapshots[key] = EventInfoSnapshot(offsetZeroValue, now)
            }
            val snapshot = eventInfoSnapshots[key]
            if (snapshot == null) {
                return@synchronized Outcome(BluetoothGatt.GATT_INVALID_OFFSET, null)
            }
            if (offset > snapshot.value.size) {
                eventInfoSnapshots.remove(key)
                return@synchronized Outcome(BluetoothGatt.GATT_INVALID_OFFSET, null)
            }
            val slice = if (offset == snapshot.value.size) ByteArray(0) else snapshot.value.copyOfRange(offset, snapshot.value.size)
            if (offset == snapshot.value.size) eventInfoSnapshots.remove(key) else snapshot.lastRequestAtMs = now
            Outcome(BluetoothGatt.GATT_SUCCESS, slice)
        }
        val responseSent = server.sendResponse(device, requestId, outcome.status, offset, outcome.value)
        if (shouldDiscardEventInfoSnapshotAfterResponse(outcome.status, responseSent)) {
            val address = device.address ?: ""
            val key = "$address:${eventInfoConnectionEpochs[address] ?: 0L}"
            synchronized(eventInfoStateLock) {
                eventInfoSnapshots.remove(key)
            }
        }
    }
}
