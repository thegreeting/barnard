// Use of this source code is governed by a BSD-style license.

package org.levarac.barnard

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
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
 * Engine-level receive path for the B005 v2 signed envelope (issue #186).
 *
 * `BluetoothGatt` cannot be constructed in a unit test, so these drive
 * [BarnardEngine.processEventInfoValue] — the seam the `onCharacteristicRead`
 * callback reduces to once the connection teardown is removed. The ENIN is
 * injected because the vendored conformance envelopes sit at ENIN ~6.0e6,
 * which no wall clock reachable by CI produces.
 */
@RunWith(RobolectricTestRunner::class)
class BarnardEngineB005EnvelopeV2Test {
    /** Inside the vectors' `[validFromEnin, relayExpiresAtEnin)` window. */
    private val vectorEnin = 6_000_000L

    private fun newContext(): Context = ApplicationProvider.getApplicationContext()

    /**
     * The handle handed to the seam. Named rather than written out at each
     * call site so an assertion compares against the value the engine was
     * actually given, not a second copy of the same literal.
     */
    private val seamAddress = "AA:BB:CC:DD:EE:FF"

    private fun collectEvents(
        value: ByteArray,
        b004EventCodeHash: ByteArray = ByteArray(0),
        currentEnin: Long = vectorEnin,
    ): List<BarnardEvent> {
        val engine = BarnardEngine(newContext())
        val events = mutableListOf<BarnardEvent>()
        engine.onEvent = { events.add(it) }
        engine.processEventInfoValue(
            address = seamAddress,
            value = value,
            b004EventCodeHash = b004EventCodeHash,
            currentEnin = currentEnin,
        )
        // onEvent is delivered through the main handler; drain it.
        shadowOf(Looper.getMainLooper()).idle()
        return events
    }

    private fun envelopeV2Event(events: List<BarnardEvent>): BarnardEventInfoEnvelopeV2Event? =
        events.filterIsInstance<BarnardEvent.EventInfoEnvelopeV2>().firstOrNull()?.envelope

    private fun hasHint(events: List<BarnardEvent>): Boolean =
        events.any { it is BarnardEvent.EventInfoHint }

    @Test
    fun validVectorContainerEmitsRadioSelfVerifiedWithByteIdenticalRawContainer() {
        for (key in listOf("v1_container", "v2_container")) {
            val container = hex(vector(key))
            val events = collectEvents(container)

            val emitted = envelopeV2Event(events)
            assertNotNull("$key: no v2 envelope event", emitted)
            emitted!!
            assertEquals(key, BarnardB005ReceiverState.RADIO_SELF_VERIFIED, emitted.receiverState)
            val verified = emitted.verifiedEnvelope
            assertNotNull(key, verified)
            assertEquals(key, BarnardB005ReceiverState.RADIO_SELF_VERIFIED, verified!!.receiverState)
            // Raw bytes must survive unchanged: spec 134 re-broadcast copies the
            // signature byte for byte.
            assertArrayEquals(key, container, emitted.rawContainer)
            // The event must name the peer it was read from: a host
            // correlating a receipt with a peer has nothing else to key on.
            assertEquals(key, seamAddress, emitted.peripheralId)
            assertFalse("$key: v1 hint must not be emitted for a v2 container", hasHint(events))
        }
    }

    @Test
    fun mutatedSignatureContainerEmitsUnverified() {
        val container = hex(vector("v1_container"))
        // Flip a bit in the trailing signature; every other field stays valid.
        container[container.size - 2] = (container[container.size - 2].toInt() xor 0x01).toByte()

        val events = collectEvents(container)

        val emitted = envelopeV2Event(events)
        assertNotNull("a failed envelope must still reach the host", emitted)
        emitted!!
        assertEquals(BarnardB005ReceiverState.UNVERIFIED, emitted.receiverState)
        assertNull(emitted.verifiedEnvelope)
        assertArrayEquals(container, emitted.rawContainer)
        // A failed envelope must still name its peer, or a host cannot tell
        // which peer to stop retrying.
        assertEquals(seamAddress, emitted.peripheralId)
        assertFalse(hasHint(events))
    }

    @Test
    fun malformedContainerLengthEmitsUnverified() {
        val container = hex(vector("v1_container"))
        // Truncate a valid vector by a few bytes without updating the declared
        // `signedEnvelopeLength` header field, so it no longer ends exactly at
        // the container boundary (spec 122 "Delivery container" table).
        val truncated = container.copyOfRange(0, container.size - 4)

        val events = collectEvents(truncated)

        val emitted = envelopeV2Event(events)
        assertNotNull("a malformed container must still reach the host", emitted)
        emitted!!
        assertEquals(BarnardB005ReceiverState.UNVERIFIED, emitted.receiverState)
        assertNull(emitted.verifiedEnvelope)
        assertArrayEquals(truncated, emitted.rawContainer)
        assertFalse(hasHint(events))
    }

    @Test
    fun v1PayloadStillEmitsHintAndNeverTheV2Case() {
        // Golden v1 B005 payload from BarnardEventInfoTest, with its B004 hash.
        val payload = hex("010100124261726e61726420436f72652053706c69740200080b9f14789f13968f")
        val b004 = hex("0b9f14789f13968f")

        val events = collectEvents(payload, b004EventCodeHash = b004)

        assertTrue("v1 traffic must still emit eventInfoHint", hasHint(events))
        assertNull("v1 traffic must never emit the v2 case", envelopeV2Event(events))
    }

    // --- vectors ---

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
