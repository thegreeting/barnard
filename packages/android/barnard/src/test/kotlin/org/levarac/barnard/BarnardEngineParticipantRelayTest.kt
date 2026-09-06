// Use of this source code is governed by a BSD-style license.

package org.levarac.barnard

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * Engine-level relay driving for B005 v2 (issue #187, spec 134).
 *
 * The pure [BarnardParticipantRelay] already has its own vector tests. These
 * drive the same shared vectors through the *engine* seam
 * ([BarnardEngine.processEventInfoValue]), which is what issue #187 asks for:
 * a receipt produced by the #186 receive path must reach the relay, and the
 * relay's chosen container must reach the B005 serving path.
 *
 * `relay-hop-dedup.txt` carries a four-byte placeholder envelope
 * (`01020304`). That envelope cannot cross the engine seam: the engine runs
 * the real [BarnardB005EnvelopeV2.verify], which rejects it, so it never
 * becomes a receipt. These tests therefore drive the *relationships* that file
 * encodes -- container layout, served hop = observed minimum + 1, no output at
 * hop two, the 32-handle cap and the 12-ENIN lifetime -- using the signed
 * conformance envelope from `b005-envelope-v2.txt`, and assert separately that
 * the placeholder containers in the file agree with the same container encoder
 * the relay serves through.
 */
@RunWith(RobolectricTestRunner::class)
class BarnardEngineParticipantRelayTest {
    /** Inside the conformance vectors' `[validFromEnin, relayExpiresAtEnin)`. */
    private val vectorEnin = 6_000_000L

    private class Clock : BarnardRelayMonotonicClock {
        var now: Long = 0
        override fun nowMilliseconds(): Long = now
    }

    private class Enin : BarnardRelayEninSource {
        var value: Long? = 6_000_000L
        override fun currentEnin(): Long? = value
    }

    /**
     * Stands in for the host's registry check. Spec 134 step 3 requires the
     * on-chain definition, which the SDK cannot reach, so the relay's verifier
     * is host-supplied and only RegistryVerified unlocks relaying.
     */
    private class RegistryVerifier : BarnardRelayVerifier {
        var invocations = 0
        var result: BarnardRelayVerification = BarnardRelayVerification.RegistryVerified(
            eventId = byteArrayOf(1),
            validFromEnin = 5_999_990L,
            validThroughEnin = 6_000_010L,
            relayExpiresAtEnin = 6_000_002L,
        )

        override fun verify(envelope: ByteArray, currentEnin: Long): BarnardRelayVerification {
            invocations++
            return result
        }
    }

    private class Harness(
        val engine: BarnardEngine,
        val clock: Clock,
        val enin: Enin,
        val verifier: RegistryVerifier,
        val events: MutableList<BarnardEvent>,
    )

    private fun harness(configureRelay: Boolean = true, seed: ByteArray = byteArrayOf(7, 8, 9)): Harness {
        val context: Context = ApplicationProvider.getApplicationContext()
        val engine = BarnardEngine(context)
        val clock = Clock()
        val enin = Enin()
        val verifier = RegistryVerifier()
        val events = mutableListOf<BarnardEvent>()
        engine.onEvent = { events.add(it) }
        if (configureRelay) {
            engine.configureParticipantRelay(
                verifier = verifier,
                joinedEventProvider = BarnardRelayJoinedEventProvider { null },
                randomnessSeedMaterial = seed,
                clock = clock,
                eninSource = enin,
            )
        }
        return Harness(engine, clock, enin, verifier, events)
    }

    private fun feed(h: Harness, container: ByteArray, peer: Int) {
        h.engine.processEventInfoValue(
            address = peerAddress(peer),
            value = container,
            b004EventCodeHash = ByteArray(0),
            currentEnin = vectorEnin,
        )
    }

    private fun peerAddress(n: Int): String = "AA:BB:CC:DD:%02X:%02X".format(n shr 8, n and 0xFF)

    /**
     * Mirrors `BarnardParticipantRelayTest`'s contention helper: run the epoch
     * decision, then let the <=15 s contention delay elapse.
     */
    private fun finishContention(h: Harness) {
        h.engine.advanceParticipantRelay()
        h.clock.now += 15_001
        h.engine.advanceParticipantRelay()
        if (!h.engine.isRelayServing) {
            h.clock.now = (h.clock.now / 30_000 + 1) * 30_000
            h.engine.advanceParticipantRelay()
            h.clock.now += 15_001
            h.engine.advanceParticipantRelay()
        }
    }

    private fun decisions(h: Harness): List<BarnardRelayDecisionEvent> {
        shadowOf(Looper.getMainLooper()).idle()
        return h.events.filterIsInstance<BarnardEvent.RelayDecision>().map { it.relay }
    }

    // 1. A verified receipt drives the relay and is served unchanged.

    @Test
    fun verifiedReceiptIsRelayedWithHopIncrementedAndBytesUnchanged() {
        val container = vectorContainer(0)
        val envelope = container.copyOfRange(4, container.size)
        val h = harness()

        feed(h, container, 1)
        assertEquals("a radioSelfVerified receipt must reach the relay verifier", 1, h.verifier.invocations)
        finishContention(h)

        assertTrue(h.engine.isRelayServing)
        val served = h.engine.relayContainerForServing()
        assertNotNull(served)
        assertArrayEquals(BarnardB005EnvelopeV2.encodeContainer(1, envelope), served)
        // Signature preserving: the envelope is copied, never re-encoded.
        assertArrayEquals(envelope, served!!.copyOfRange(4, served.size))

        val broadcast = decisions(h).last { it.decision == BarnardRelayDecision.BROADCAST }
        assertEquals(1, broadcast.hop)
        assertEquals("elected", broadcast.reason)
        assertArrayEquals(MessageDigest.getInstance("SHA-256").digest(envelope), broadcast.payloadDigest)
    }

    @Test
    fun leaseRenewalEmitsStopThenKeepForTheSameDigest() {
        val h = harness()
        feed(h, vectorContainer(0), 1)
        finishContention(h)
        val broadcast = decisions(h).last()
        assertEquals(BarnardRelayDecision.BROADCAST, broadcast.decision)

        // Run the 30-second lease out. The relay renews by ending the old
        // lease and electing again, with r = 0 making pKeep = 1.
        h.clock.now += 30_000
        h.engine.advanceParticipantRelay()
        h.clock.now += 15_001
        h.engine.advanceParticipantRelay()

        assertTrue(h.engine.isRelayServing)
        val tail = decisions(h).takeLast(2)
        assertEquals(listOf(BarnardRelayDecision.STOP, BarnardRelayDecision.KEEP), tail.map { it.decision })
        assertEquals("lease_ended", tail[0].reason)
        assertEquals("renewed", tail[1].reason)
        assertArrayEquals(broadcast.payloadDigest, tail[1].payloadDigest)
        assertEquals(1, tail[1].hop)
    }

    // 2. Hop at the limit is never re-broadcast.

    @Test
    fun hopAtLimitIsNeverRebroadcast() {
        val h = harness()
        feed(h, vectorContainer(2), 1)
        // The container still verifies and still reaches the relay: spec 134
        // keeps a hop-two observation displayable. It is the relay's own hop
        // guard, not a rejected receipt, that must stop the re-broadcast.
        assertEquals(1, h.verifier.invocations)
        finishContention(h)

        assertFalse(h.engine.isRelayServing)
        assertNull(h.engine.relayContainerForServing())
        assertTrue(
            "a hop-two observation must produce no broadcast decision",
            decisions(h).isEmpty(),
        )
    }

    // 3. v1 traffic never reaches the relay.

    @Test
    fun v1EventInfoHintNeverReachesTheRelay() {
        val h = harness()
        val payload = hex("010100124261726e61726420436f72652053706c69740200080b9f14789f13968f")
        val b004 = hex("0b9f14789f13968f")

        h.engine.processEventInfoValue(
            address = peerAddress(1),
            value = payload,
            b004EventCodeHash = b004,
            currentEnin = vectorEnin,
        )
        finishContention(h)

        assertEquals("v1 hint traffic must never be offered to the relay", 0, h.verifier.invocations)
        assertFalse(h.engine.isRelayServing)
        assertNull(h.engine.relayContainerForServing())
    }

    // 4. Unverified containers never reach the relay.

    @Test
    fun unverifiedContainerNeverReachesTheRelay() {
        val container = vectorContainer(0)
        container[container.size - 2] = (container[container.size - 2].toInt() xor 0x01).toByte()

        val h = harness()
        feed(h, container, 1)
        finishContention(h)

        assertEquals("an unverified container must never be offered to the relay", 0, h.verifier.invocations)
        assertFalse(h.engine.isRelayServing)
    }

    // 5. Shared vectors through the engine seam.

    /**
     * The placeholder envelope in `relay-hop-dedup.txt` is not signed, so the
     * engine's real verifier rejects it and it never becomes a receipt. This
     * pins that as a property of the seam rather than leaving it as a remark
     * in the file's own comment: feeding the vector's hop-zero container
     * through the receive path must reach neither the relay nor the host.
     */
    @Test
    fun hopDedupVectorContainerNeverReachesTheRelayAtTheEngineSeam() {
        val container = hex(vectors("relay-hop-dedup").getValue("hop_zero_container"))
        assertEquals("the vector must still be dispatched as a v2 container", 0x03, container[0].toInt())

        val h = harness()
        feed(h, container, 1)
        finishContention(h)

        assertEquals("an unsigned placeholder must never reach the relay verifier", 0, h.verifier.invocations)
        assertFalse(h.engine.isRelayServing)
        assertNull(h.engine.relayContainerForServing())
        assertTrue(decisions(h).isEmpty())
    }

    @Test
    fun relayHopDedupVectorsThroughTheEngineSeam() {
        val hopVectors = vectors("relay-hop-dedup")
        assertEquals("03", hopVectors["format_version"])
        assertEquals("32", hopVectors["handle_cap"])
        assertEquals("12", hopVectors["relay_lifetime_enins"])

        // The file's own placeholder containers must agree with the encoder the
        // relay serves through, even though they cannot cross the engine seam.
        val placeholder = hex(hopVectors.getValue("envelope"))
        for ((key, hop) in listOf("hop_zero_container" to 0, "hop_one_container" to 1, "hop_two_container" to 2)) {
            assertArrayEquals(key, BarnardB005EnvelopeV2.encodeContainer(hop, placeholder), hex(hopVectors.getValue(key)))
        }
        assertArrayEquals(hex(hopVectors.getValue("hop_one_container")), hex(hopVectors.getValue("served_from_zero")))
        assertArrayEquals(hex(hopVectors.getValue("hop_two_container")), hex(hopVectors.getValue("served_from_one")))

        // served hop = observed minimum + 1, and nothing at hop two, driven with
        // the signed conformance envelope so the engine's verifier accepts it.
        val signedEnvelope = vectorContainer(0).let { it.copyOfRange(4, it.size) }
        for (observed in 0..1) {
            val h = harness()
            feed(h, vectorContainer(observed), 1)
            finishContention(h)
            val served = h.engine.relayContainerForServing()
            assertNotNull("observed hop $observed", served)
            assertArrayEquals(BarnardB005EnvelopeV2.encodeContainer(observed + 1, signedEnvelope), served)
        }

        // Duplicate at a lower hop wins: hop one then hop zero must serve hop one.
        val h = harness()
        feed(h, vectorContainer(1), 1)
        feed(h, vectorContainer(0), 2)
        finishContention(h)
        assertArrayEquals(
            BarnardB005EnvelopeV2.encodeContainer(1, signedEnvelope),
            h.engine.relayContainerForServing(),
        )
    }

    /**
     * Enter decisions, driven by the vector file's numerators.
     *
     * `pEnter = (k - r) / k` is a probability, so a single seed's outcome at
     * r = 1 or 2 is a coin flip and asserting one fixed outcome would pin
     * whatever that seed happened to draw. The election draw is a pure
     * function of (seed material, digest, epoch), so sweeping a fixed set of
     * seeds makes the *distribution* deterministic without reimplementing the
     * draw here:
     *
     * - `r = 0` has `pEnter = 1`, so every seed must enter;
     * - `r >= k` has `pEnter = 0`, so no seed may enter;
     * - `0 < r < k` must show both branches across the sweep, which is what
     *   proves the suppression path is reachable at all.
     */
    @Test
    fun densityEnterDecisionsAcrossSeedsMatchTheVectorNumerators() {
        val density = vectors("density-decisions")
        val k = density.getValue("k").toInt()
        val contentionMax = density.getValue("contention_max_ms").toLong()
        assertEquals(3, k)
        assertEquals(30_000L, density.getValue("window_ms").toLong())

        val seeds = (0 until 24).map { byteArrayOf(it.toByte(), 0x5A, 0xA5.toByte()) }

        for (r in 0..4) {
            val enterNumerator = density.getValue("r${r}_enter_numerator").toInt()
            assertEquals("r=$r numerator disagrees with (k - r)", maxOf(0, k - r), enterNumerator)

            var entered = 0
            for (seed in seeds) {
                val h = harness(seed = seed)
                // Establish the candidate from a direct source (hop 0):
                // hop-zero peers do not count toward r.
                feed(h, vectorContainer(0), 1)
                // r distinct hop-positive relay sources inside the window.
                for (i in 0 until r) feed(h, vectorContainer(1), 100 + i)

                h.engine.advanceParticipantRelay()
                h.clock.now += contentionMax + 1
                h.engine.advanceParticipantRelay()

                if (h.engine.isRelayServing) entered++
            }

            when (enterNumerator) {
                k -> assertEquals("r=$r: pEnter = 1, every seed must enter", seeds.size, entered)
                0 -> assertEquals("r=$r: pEnter = 0, no seed may enter", 0, entered)
                else -> {
                    assertTrue("r=$r: no seed entered, the enter branch is unreachable", entered > 0)
                    assertTrue("r=$r: every seed entered, the suppress branch is unreachable", entered < seeds.size)
                }
            }
        }
    }

    /**
     * Keep decisions, driven by the vector file's keep numerators.
     *
     * Entry only ever happens at `r < k`, so r = 3 and 4 cannot be reached by
     * entering with a live r. Entry is forced at r = 0 (where `pEnter = 1`
     * makes it seed-independent), then the r handles are populated one
     * millisecond before the lease boundary so they are still inside the
     * 30-second window at the instant the keep decision runs.
     */
    @Test
    fun densityKeepDecisionsThroughTheEngineSeam() {
        val density = vectors("density-decisions")
        val k = density.getValue("k").toInt()
        val window = density.getValue("window_ms").toLong()
        val contentionMax = density.getValue("contention_max_ms").toLong()

        for (r in 0..(k + 1)) {
            val keepNumerator = density.getValue("r${r}_keep_numerator").toInt()
            assertEquals("r=$r: pKeep = min(1, k/(r+1)) always has numerator k", k, keepNumerator)

            val h = harness()
            feed(h, vectorContainer(0), 1)
            h.engine.advanceParticipantRelay()
            h.clock.now += contentionMax + 1
            h.engine.advanceParticipantRelay()
            assertTrue("r=$r: entry at r=0 must be guaranteed", h.engine.isRelayServing)

            h.clock.now += window - 1
            for (i in 0 until r) feed(h, vectorContainer(1), 150 + i)
            h.clock.now += 1 // now == activeUntil: the keep decision runs at this exact r
            h.engine.advanceParticipantRelay()
            h.clock.now += contentionMax + 1
            h.engine.advanceParticipantRelay()

            // pKeep picks a keep candidate whenever the numerator is positive,
            // but Advertise only restarts if r < k at the end of the delay.
            assertEquals("r=$r keep decision mismatch", keepNumerator > 0 && r < k, h.engine.isRelayServing)
        }
    }

    @Test
    fun thirtyThreeHandlesSaturateThroughTheEngineSeam() {
        val h = harness()
        feed(h, vectorContainer(1), 0)
        for (i in 1..32) feed(h, vectorContainer(1), i)
        h.engine.advanceParticipantRelay()
        h.clock.now += 15_001
        h.engine.advanceParticipantRelay()
        assertFalse("32 handles plus overflow must saturate r >= k", h.engine.isRelayServing)
    }

    // 6. Serving precedence and lease teardown.

    @Test
    fun ownEventInfoValueTakesPrecedenceOverTheRelayedContainer() {
        val h = harness()
        feed(h, vectorContainer(0), 1)
        finishContention(h)
        assertNotNull(h.engine.relayContainerForServing())
        // With no own value configured, the relayed container is what B005 serves.
        assertArrayEquals(h.engine.relayContainerForServing(), h.engine.eventInfoValueForRead())

        // Once this device serves its own event-info value, that wins.
        h.engine.joinEvent("BARNARD-RELAY-TEST")
        h.engine.configureEventInfoServing(
            organizerDesignated = true,
            eventActiveForDiscovery = true,
            eventDisplayName = "Own Event",
        )
        val own = h.engine.eventInfoValueForRead()
        assertNotNull(own)
        assertEquals("the own value is the unchanged v1 event-info payload", 0x01, own!![0].toInt())

        // Precedence is not a read-time tie-break: taking the wire away from
        // the relay must also end its lease, or isRelayServing and the
        // decision events would describe a broadcast no peer can observe.
        assertFalse(h.engine.isRelayServing)
        assertNull(h.engine.relayContainerForServing())
        val stop = decisions(h).last()
        assertEquals(BarnardRelayDecision.STOP, stop.decision)
        assertEquals("own_value_precedence", stop.reason)
        h.engine.leaveEvent()
    }

    /**
     * The mirror of the case above: a device already serving its own value
     * must never enter election in the first place, so no lease is ever taken
     * that the read path would then have to override.
     */
    @Test
    fun ownValueDeviceNeverEntersElection() {
        val h = harness()
        h.engine.joinEvent("BARNARD-RELAY-TEST")
        h.engine.configureEventInfoServing(
            organizerDesignated = true,
            eventActiveForDiscovery = true,
            eventDisplayName = "Own Event",
        )

        feed(h, vectorContainer(0), 1)
        finishContention(h)

        assertEquals("an own-value device must not offer observations to the relay", 0, h.verifier.invocations)
        assertFalse(h.engine.isRelayServing)
        assertNull(h.engine.relayContainerForServing())
        assertTrue(decisions(h).all { it.decision == BarnardRelayDecision.STOP })
        assertEquals(0x01, h.engine.eventInfoValueForRead()!![0].toInt())
        h.engine.leaveEvent()
    }

    @Test
    fun stoppingScanClearsTheRelayLease() {
        val h = harness()
        feed(h, vectorContainer(0), 1)
        finishContention(h)
        assertTrue(h.engine.isRelayServing)

        h.engine.stopScan()

        assertFalse(h.engine.isRelayServing)
        assertNull(h.engine.relayContainerForServing())
        val stop = decisions(h).last { it.decision == BarnardRelayDecision.STOP }
        assertEquals("host_stop", stop.reason)
    }

    @Test
    fun relayIsInertUntilAVerifierIsConfigured() {
        val h = harness(configureRelay = false)
        feed(h, vectorContainer(0), 1)
        h.engine.advanceParticipantRelay()
        assertFalse(h.engine.isRelayServing)
        assertNull(h.engine.relayContainerForServing())
        assertTrue(decisions(h).isEmpty())
    }

    // Vectors

    private fun vectorContainer(hop: Int): ByteArray {
        val base = hex(vectors("b005-envelope-v2").getValue("v1_container"))
        base[1] = hop.toByte()
        return base
    }

    private fun hex(value: String): ByteArray =
        ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun vectors(name: String): Map<String, String> =
        File(findRepoRoot(), "test-vectors/$name.txt").readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") && it.contains("=") }
            .associate { line -> line.substringBefore("=") to line.substringAfter("=") }

    private fun findRepoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        var levels = 0
        while (dir != null && levels < 20) {
            if (File(dir, "test-vectors/b005-envelope-v2.txt").isFile) return dir!!
            dir = dir!!.parentFile
            levels++
        }
        error("Could not locate repo root containing test-vectors/b005-envelope-v2.txt")
    }
}
