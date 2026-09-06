// Use of this source code is governed by a BSD-style license.

package org.levarac.barnard.example

import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardEvent
import org.levarac.barnard.BarnardPermissionResult

private const val TAG = "BarnardExample"
private const val MAX_LOG_LINES = 200

/**
 * Minimal native Android example (barnard#56): start/stop scan+advertise
 * against the Flutter-free `packages/android/barnard` library and print
 * events. No Flutter runtime involved.
 */
class MainActivity : AppCompatActivity() {
    private val engine by lazy { BarnardEngine(applicationContext) }

    private lateinit var statusText: TextView
    private lateinit var logText: TextView
    private lateinit var logScroll: ScrollView
    private val logLines = ArrayDeque<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.statusText)
        logText = findViewById(R.id.logText)
        logScroll = (logText.parent as ScrollView)

        findViewById<Button>(R.id.startButton).setOnClickListener { requestPermissionsThenStart() }
        findViewById<Button>(R.id.stopButton).setOnClickListener { engine.stopAuto() }

        engine.setActivity(this)
        engine.onEvent = { event -> runOnUiThread { handle(event) } }
    }

    override fun onDestroy() {
        engine.dispose()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (!engine.onRequestPermissionsResult(requestCode, permissions, grantResults)) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    private fun requestPermissionsThenStart() {
        engine.requestPermissions { result ->
            runOnUiThread {
                when (result) {
                    is BarnardPermissionResult.Granted -> {
                        val status = result.status
                        append("permissions: canScan=${status.canScan} canAdvertise=${status.canAdvertise}")
                        if (status.canScan && status.canAdvertise) {
                            engine.startAuto()
                        } else {
                            engine.openAppSettings()
                        }
                    }
                    is BarnardPermissionResult.Failed -> {
                        append("permissions_failed: ${result.error.code} ${result.error.message}")
                    }
                }
            }
        }
    }

    private fun handle(event: BarnardEvent) {
        when (event) {
            is BarnardEvent.State -> {
                val state = event.state
                statusText.text = "Scanning: ${if (state.isScanning) "on" else "off"}  " +
                    "Advertising: ${if (state.isAdvertising) "on" else "off"}"
                append("state: scanning=${state.isScanning} advertising=${state.isAdvertising} reason=${state.reasonCode ?: "-"}")
            }
            is BarnardEvent.Detection -> {
                val d = event.detection
                append("detection: rpid=${d.rpid} rssi=${d.rssi} enin=${d.enin}")
            }
            is BarnardEvent.RssiUpdate -> {
                val u = event.update
                append("rssi_update: rpid=${u.rpid} rssi=${u.rssi}")
            }
            is BarnardEvent.Error -> {
                append("error: ${event.error.code} ${event.error.message}")
            }
            is BarnardEvent.Constraint -> {
                append("constraint: ${event.constraint.code} ${event.constraint.message ?: ""}")
            }
            is BarnardEvent.EventInfoHint -> {
                val hint = event.hint
                append("event_info_hint: name=${hint.eventInfo.eventDisplayName} " +
                    "additionalNamesOmitted=${hint.additionalNamesOmitted} additionalEventsOmitted=${hint.additionalEventsOmitted}")
            }
            is BarnardEvent.EventInfoEnvelopeV2 -> {
                // Only the state and the size are logged. RADIO_SELF_VERIFIED means
                // the signature checks out, not that the event is registered, so it
                // must not be presented to a user as "verified".
                val envelope = event.envelope
                append("event_info_envelope_v2: receiverState=${envelope.receiverState} " +
                    "bytes=${envelope.rawContainer.size}")
            }
        }
    }

    private fun append(line: String) {
        Log.i(TAG, line)
        logLines.addLast(line)
        while (logLines.size > MAX_LOG_LINES) {
            logLines.removeFirst()
        }
        logText.text = logLines.joinToString("\n")
        logScroll.post { logScroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }
}
