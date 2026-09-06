// Use of this source code is governed by a BSD-style license.

package org.levarac.barnard.example.devicelab

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.levarac.barnard.BarnardDebugEvent
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardEvent
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Collections
import java.util.LinkedHashSet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private const val LOG_TAG = "BarnardDeviceLab"
private const val DEFAULT_EVENT_CODE = "BND"

private fun marker(message: String) {
    Log.i(LOG_TAG, message)
    println(message)
}

private fun stringArgument(name: String, defaultValue: String? = null): String {
    val value = InstrumentationRegistry.getArguments().getString(name) ?: defaultValue
    require(!value.isNullOrBlank()) { "pass -e $name <value> to AndroidJUnitRunner" }
    return value
}

private fun boundedIntArgument(name: String, defaultValue: Int, range: IntRange): Int {
    val raw = InstrumentationRegistry.getArguments().getString(name)
    val value = if (raw == null) {
        defaultValue
    } else {
        requireNotNull(raw.toIntOrNull()) { "$name must be an integer, got $raw" }
    }
    require(value in range) { "$name must be in ${range.first}..${range.last}, got $value" }
    return value
}

private fun targetContext(): Context =
    InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

private fun BarnardEngine.attachDebugMarkers() {
    onDebugEvent = { event: BarnardDebugEvent ->
        marker("BARNARD_DBG ${event.level} ${event.name} ${event.data ?: emptyMap<String, Any?>()}")
    }
}

private fun awaitCondition(timeoutMs: Long, condition: () -> Boolean): Boolean {
    val deadline = SystemClock.elapsedRealtime() + timeoutMs
    while (SystemClock.elapsedRealtime() < deadline) {
        if (condition()) return true
        SystemClock.sleep(100)
    }
    return condition()
}

@RunWith(AndroidJUnit4::class)
class BarnardAdvertiserDeviceLabTest {
    private lateinit var engine: BarnardEngine

    @After
    fun tearDown() {
        if (::engine.isInitialized) engine.dispose()
    }

    @Test
    fun advertisesAndHolds() {
        val eventCode = stringArgument("eventCode", DEFAULT_EVENT_CODE)
        val holdSeconds = boundedIntArgument("holdSeconds", 120, 1..900)

        engine = BarnardEngine(targetContext()).apply {
            attachDebugMarkers()
            onEvent = { event ->
                when (event) {
                    is BarnardEvent.State -> marker(
                        "BARNARD_EVT state scanning=${event.state.isScanning} " +
                            "advertising=${event.state.isAdvertising}",
                    )
                    is BarnardEvent.Constraint -> marker(
                        "BARNARD_EVT constraint code=${event.constraint.code} " +
                            "message=${event.constraint.message ?: ""}",
                    )
                    is BarnardEvent.Error -> marker(
                        "BARNARD_EVT error code=${event.error.code} message=${event.error.message}",
                    )
                    else -> Unit
                }
            }
        }

        engine.joinEvent(eventCode)
        marker("BARNARD_JOINED_EVENT=$eventCode")
        marker("BARNARD_SELF_DISPLAY_ID=${engine.getMyDisplayId()}")

        val permission = engine.getPermissionStatus()
        marker(
            "BARNARD_PERM canAdvertise=${permission.canAdvertise} " +
                "canScan=${permission.canScan}",
        )
        assertTrue(
            "Advertise unavailable; check Bluetooth and runtime permissions",
            permission.canAdvertise,
        )

        engine.startAdvertise()
        val advertising = awaitCondition(timeoutMs = 10_000) {
            engine.getState().isAdvertising
        }
        marker("BARNARD_ADVERTISING=$advertising")
        assertTrue("Advertise did not start within 10 seconds", advertising)

        SystemClock.sleep(holdSeconds * 1_000L)
    }
}

@RunWith(AndroidJUnit4::class)
class BarnardScannerDeviceLabTest {
    private lateinit var engine: BarnardEngine

    @After
    fun tearDown() {
        if (::engine.isInitialized) engine.dispose()
    }

    @Test
    fun discoversAdvertiserByDisplayId() {
        val expectedDisplayId = stringArgument("expectedDisplayId")
        val eventCode = stringArgument("eventCode", DEFAULT_EVENT_CODE)
        val scanTimeoutSeconds = boundedIntArgument("scanTimeoutSeconds", 60, 1..180)
        val permissionWaitSeconds = boundedIntArgument("permissionWaitSeconds", 30, 0..60)

        assertTrue(
            "expectedDisplayId must be 8 lowercase hex characters",
            expectedDisplayId.matches(Regex("[0-9a-f]{8}")),
        )
        marker("BARNARD_SCAN_EXPECTED=$expectedDisplayId")

        val found = CountDownLatch(1)
        val detections = AtomicInteger(0)
        val rssiUpdates = AtomicInteger(0)
        val seen = Collections.synchronizedSet(LinkedHashSet<String>())

        engine = BarnardEngine(targetContext()).apply {
            attachDebugMarkers()
            onEvent = { event ->
                when (event) {
                    is BarnardEvent.Detection -> {
                        detections.incrementAndGet()
                        val displayId = event.detection.detectedDisplayId
                        marker(
                            "BARNARD_EVT detection displayId=$displayId " +
                                "rssi=${event.detection.rssi}",
                        )
                        if (displayId != null) seen.add(displayId)
                        if (displayId == expectedDisplayId) found.countDown()
                    }
                    is BarnardEvent.RssiUpdate -> {
                        rssiUpdates.incrementAndGet()
                        val displayId = event.update.detectedDisplayId
                        marker(
                            "BARNARD_EVT rssi_update displayId=$displayId " +
                                "rssi=${event.update.rssi}",
                        )
                        if (displayId != null) seen.add(displayId)
                        if (displayId == expectedDisplayId) found.countDown()
                    }
                    is BarnardEvent.State -> marker(
                        "BARNARD_EVT state scanning=${event.state.isScanning} " +
                            "advertising=${event.state.isAdvertising}",
                    )
                    is BarnardEvent.Constraint -> marker(
                        "BARNARD_EVT constraint code=${event.constraint.code} " +
                            "message=${event.constraint.message ?: ""}",
                    )
                    is BarnardEvent.Error -> marker(
                        "BARNARD_EVT error code=${event.error.code} message=${event.error.message}",
                    )
                    is BarnardEvent.EventInfoHint -> marker(
                        "BARNARD_EVT event_info_hint name=${event.hint.eventInfo.eventDisplayName} " +
                            "additionalNamesOmitted=${event.hint.additionalNamesOmitted} " +
                            "additionalEventsOmitted=${event.hint.additionalEventsOmitted}",
                    )
                    is BarnardEvent.EventInfoEnvelopeV2 -> marker(
                        "BARNARD_EVT event_info_envelope_v2 " +
                            "receiverState=${event.envelope.receiverState} " +
                            "bytes=${event.envelope.rawContainer.size}",
                    )
                    is BarnardEvent.RelayDecision -> marker(
                        "BARNARD_EVT relay_decision decision=${event.relay.decision} " +
                            "hop=${event.relay.hop} reason=${event.relay.reason}",
                    )
                }
            }
        }

        engine.joinEvent(eventCode)
        marker("BARNARD_JOINED_EVENT=$eventCode")

        val canScan = awaitCondition(timeoutMs = permissionWaitSeconds * 1_000L) {
            engine.getPermissionStatus().canScan
        }
        val permission = engine.getPermissionStatus()
        marker(
            "BARNARD_PERM canScan=${permission.canScan} " +
                "canAdvertise=${permission.canAdvertise}",
        )
        assertTrue(
            "Scan unavailable; check Bluetooth, Location services, and runtime permissions",
            canScan,
        )

        engine.startScan(allowDuplicates = true)
        val matched = found.await(scanTimeoutSeconds.toLong(), TimeUnit.SECONDS)
        val seenSnapshot = synchronized(seen) { seen.toList() }
        marker(
            "BARNARD_SCAN_FOUND=$matched detections=${detections.get()} " +
                "rssiUpdates=${rssiUpdates.get()} seen=$seenSnapshot",
        )

        assertTrue(
            "Did not detect expected displayId $expectedDisplayId within " +
                "$scanTimeoutSeconds seconds (seen=$seenSnapshot)",
            matched,
        )
    }
}
