// Use of this source code is governed by a BSD-style license.

package org.levarac.barnard

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * Serving a host-supplied hop-zero B005 v2 container as this device's own
 * event-info value (issue #189).
 *
 * The engine neither signs nor re-encodes what the host hands it, so these
 * tests assert byte identity rather than any derived field, plus the
 * structural gate that keeps a malformed or already-relayed container out. The
 * round-trip case feeds the served bytes back through the #186 receive seam,
 * which is the only way to show a peer would reach `RADIO_SELF_VERIFIED`
 * without a radio.
 */
@RunWith(RobolectricTestRunner::class)
class BarnardEngineOwnEnvelopeV2Test {
    /** Inside the conformance vectors' `[validFromEnin, relayExpiresAtEnin)`. */
    private val vectorEnin = 6_000_000L

    private fun newEngine(): BarnardEngine =
        BarnardEngine(ApplicationProvider.getApplicationContext<Context>())

    // --- 1. A supplied container is served byte for byte at hop zero ---

    @Test
    fun suppliedContainerIsServedByteIdenticalAtHopZero() {
        val container = vectorContainer()
        val engine = newEngine()

        engine.configureOwnEventInfoEnvelopeV2(container)

        assertArrayEquals(container, engine.ownEventInfoEnvelopeV2())
        val served = engine.eventInfoValueForRead()
        assertNotNull(served)
        assertArrayEquals("the container must reach the wire unchanged", container, served)
        assertEquals(BarnardB005EnvelopeV2.FORMAT_VERSION, served!![0].toInt() and 0xFF)
        assertEquals("the device's own value is a hop-zero source", 0, served[1].toInt())
    }

    // --- 2. The structural gate ---

    @Test
    fun nonZeroHopIsRejected() {
        val container = vectorContainer()
        container[1] = 1
        val engine = newEngine()

        assertEquals(
            BarnardOwnEnvelopeV2Error.NON_ZERO_HOP_COUNT,
            rejection(engine, container),
        )
        assertNull(engine.ownEventInfoEnvelopeV2())
        assertNull(engine.eventInfoValueForRead())
    }

    @Test
    fun nonV2FormatVersionIsRejected() {
        val container = vectorContainer()
        container[0] = 0x02
        val engine = newEngine()

        assertEquals(
            BarnardOwnEnvelopeV2Error.UNSUPPORTED_FORMAT_VERSION,
            rejection(engine, container),
        )
        assertNull(engine.ownEventInfoEnvelopeV2())
    }

    @Test
    fun truncatedAndOverlongContainersAreRejected() {
        val engine = newEngine()

        assertEquals(
            BarnardOwnEnvelopeV2Error.INVALID_CONTAINER_LENGTH,
            rejection(engine, byteArrayOf(3, 0, 0, 0)),
        )
        assertEquals(
            BarnardOwnEnvelopeV2Error.ENVELOPE_LENGTH_MISMATCH,
            rejection(engine, vectorContainer() + byteArrayOf(0)),
        )
    }

    @Test
    fun aRejectedContainerLeavesAPreviouslySuppliedOneInPlace() {
        val container = vectorContainer()
        val engine = newEngine()
        engine.configureOwnEventInfoEnvelopeV2(container)

        val relayed = vectorContainer()
        relayed[1] = 1
        assertNotNull(rejection(engine, relayed))

        assertArrayEquals(container, engine.eventInfoValueForRead())
    }

    // --- 3. The v1 fallback is unchanged ---

    @Test
    fun withoutASuppliedContainerTheV1PayloadIsServed() {
        val engine = newEngine()
        engine.joinEvent("BARNARD-OWN-V2-TEST")
        engine.configureEventInfoServing(
            organizerDesignated = true,
            eventActiveForDiscovery = true,
            eventDisplayName = "Own Event",
        )

        val v1 = engine.eventInfoValueForRead()
        assertNotNull(v1)
        assertEquals("with no v2 container the v1 payload is served as before", 0x01, v1!![0].toInt())

        // Supplying and then clearing a container restores exactly those bytes.
        engine.configureOwnEventInfoEnvelopeV2(vectorContainer())
        assertEquals(
            BarnardB005EnvelopeV2.FORMAT_VERSION,
            engine.eventInfoValueForRead()!![0].toInt() and 0xFF,
        )
        engine.configureOwnEventInfoEnvelopeV2(null)
        assertNull(engine.ownEventInfoEnvelopeV2())
        assertArrayEquals(v1, engine.eventInfoValueForRead())

        // The joined event code is persisted; restore anonymous mode.
        engine.leaveEvent()
    }

    @Test
    fun stoppingAdvertiseKeepsTheHostSuppliedContainer() {
        val container = vectorContainer()
        val engine = newEngine()
        engine.configureOwnEventInfoEnvelopeV2(container)

        // Deliberate asymmetry with the relay lease, which stopAdvertise tears
        // down: the lease is engine-elected state that spec 134 requires be
        // rechecked on resume, while this container is host state the engine
        // was handed. Only the host clears it.
        engine.stopAdvertise()
        shadowOf(Looper.getMainLooper()).idle()

        assertArrayEquals(container, engine.ownEventInfoEnvelopeV2())
        assertArrayEquals(container, engine.eventInfoValueForRead())
    }

    // --- 4. Precedence over a relayed container ---

    @Test
    fun suppliedContainerBeatsARelayedOneAndEndsTheLease() {
        val engine = newEngine()
        val events = mutableListOf<BarnardEvent>()
        engine.onEvent = { events.add(it) }
        val clock = Clock()
        engine.configureParticipantRelay(
            verifier = RegistryVerifier(),
            joinedEventProvider = BarnardRelayJoinedEventProvider { null },
            randomnessSeedMaterial = byteArrayOf(7, 8, 9),
            clock = clock,
            eninSource = BarnardRelayEninSource { 6_000_000L },
        )
        engine.processEventInfoValue(
            address = "AA:BB:CC:DD:EE:FF",
            value = vectorContainer(),
            b004EventCodeHash = ByteArray(0),
            currentEnin = vectorEnin,
        )
        // Run the epoch decision, then let the <=15 s contention delay elapse.
        engine.advanceParticipantRelay()
        clock.now += 15_001
        engine.advanceParticipantRelay()
        if (!engine.isRelayServing) {
            clock.now = (clock.now / 30_000 + 1) * 30_000
            engine.advanceParticipantRelay()
            clock.now += 15_001
            engine.advanceParticipantRelay()
        }
        shadowOf(Looper.getMainLooper()).idle()
        val relayed = engine.relayContainerForServing()
        assertNotNull(relayed)
        assertEquals("the relayed copy sits one hop out", 1, relayed!![1].toInt())

        val own = vectorContainer()
        own[4] = (own[4].toInt() xor 0x01).toByte()
        engine.configureOwnEventInfoEnvelopeV2(own)

        assertArrayEquals(own, engine.eventInfoValueForRead())
        shadowOf(Looper.getMainLooper()).idle()
        // A supplied container is an own value for the #187 election gate too,
        // not only for the read chooser: this device can no longer put a
        // relayed container on the wire, so the lease ends rather than
        // lingering behind a value that shadows it.
        assertFalse(engine.isRelayServing)
        assertNull(engine.relayContainerForServing())
        val stop = events.filterIsInstance<BarnardEvent.RelayDecision>()
            .map { it.relay }
            .last { it.decision == BarnardRelayDecision.STOP }
        assertEquals("own_value_precedence", stop.reason)
    }

    @Test
    fun aSuppliedContainerKeepsTheRelayFromElectingAtAll() {
        val engine = newEngine()
        val clock = Clock()
        engine.configureParticipantRelay(
            verifier = RegistryVerifier(),
            joinedEventProvider = BarnardRelayJoinedEventProvider { null },
            randomnessSeedMaterial = byteArrayOf(7, 8, 9),
            clock = clock,
            eninSource = BarnardRelayEninSource { 6_000_000L },
        )
        engine.configureOwnEventInfoEnvelopeV2(vectorContainer())

        engine.processEventInfoValue(
            address = "AA:BB:CC:DD:EE:FF",
            value = vectorContainer(),
            b004EventCodeHash = ByteArray(0),
            currentEnin = vectorEnin,
        )
        engine.advanceParticipantRelay()
        clock.now += 15_001
        engine.advanceParticipantRelay()
        shadowOf(Looper.getMainLooper()).idle()

        assertFalse("an own value must not observe or elect", engine.isRelayServing)
        assertNull(engine.relayContainerForServing())
    }

    // --- 5. A peer running the #186 receive path verifies what we serve ---

    @Test
    fun servedContainerRoundTripsToRadioSelfVerifiedOnAPeer() {
        val source = newEngine()
        source.configureOwnEventInfoEnvelopeV2(vectorContainer())
        val served = source.eventInfoValueForRead()
        assertNotNull(served)

        val peer = newEngine()
        val events = mutableListOf<BarnardEvent>()
        peer.onEvent = { events.add(it) }
        peer.processEventInfoValue(
            address = "AA:BB:CC:DD:EE:01",
            value = served!!,
            b004EventCodeHash = ByteArray(0),
            currentEnin = vectorEnin,
        )
        shadowOf(Looper.getMainLooper()).idle()

        val envelope = events.filterIsInstance<BarnardEvent.EventInfoEnvelopeV2>()
            .firstOrNull()?.envelope
        assertNotNull("the peer saw no v2 envelope", envelope)
        assertEquals(BarnardB005ReceiverState.RADIO_SELF_VERIFIED, envelope!!.receiverState)
        assertFalse(
            "the SDK never assigns REGISTRY_VERIFIED",
            envelope.receiverState == BarnardB005ReceiverState.REGISTRY_VERIFIED,
        )
        assertArrayEquals(served, envelope.rawContainer)
        assertEquals(0, envelope.verifiedEnvelope!!.relayHopCount)
    }

    // --- helpers ---

    private fun rejection(engine: BarnardEngine, container: ByteArray): BarnardOwnEnvelopeV2Error? =
        try {
            engine.configureOwnEventInfoEnvelopeV2(container)
            fail("expected the container to be rejected")
            null
        } catch (e: BarnardOwnEnvelopeV2Exception) {
            e.reason
        }

    private class Clock : BarnardRelayMonotonicClock {
        var now: Long = 0
        override fun nowMilliseconds(): Long = now
    }

    private class RegistryVerifier : BarnardRelayVerifier {
        override fun verify(envelope: ByteArray, currentEnin: Long): BarnardRelayVerification =
            BarnardRelayVerification.RegistryVerified(
                eventId = byteArrayOf(1),
                validFromEnin = 5_999_990L,
                validThroughEnin = 6_000_010L,
                relayExpiresAtEnin = 6_000_002L,
            )
    }

    // --- vectors ---

    private fun vectorContainer(): ByteArray = hex(vector("v1_container"))

    private fun vector(key: String): String =
        requireNotNull(vectors[key]) { "missing vector $key" }

    private val vectors: Map<String, String> by lazy {
        File(findRepoRoot(), "test-vectors/b005-envelope-v2.txt").readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") && it.contains('=') }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
    }

    private fun findRepoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir")!!).absoluteFile
        var levels = 0
        while (dir != null && levels < 20) {
            if (File(dir, "test-vectors/b005-envelope-v2.txt").isFile) return dir
            dir = dir.parentFile
            levels++
        }
        fail("Could not locate repo root containing test-vectors/b005-envelope-v2.txt")
        error("unreachable")
    }

    private fun hex(value: String): ByteArray =
        ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
