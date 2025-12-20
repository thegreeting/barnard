package network.greeting.barnard

import android.Manifest
import android.annotation.SuppressLint
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
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal class BarnardController(
    private val appContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())

    private val methods = MethodChannel(messenger, "barnard/methods")
    private val events = EventChannel(messenger, "barnard/events")
    private val debugEvents = EventChannel(messenger, "barnard/debugEvents")

    private var eventSink: EventChannel.EventSink? = null
    private var debugEventSink: EventChannel.EventSink? = null

    private val serviceUuid: UUID = UUID.fromString("0000B001-0000-1000-8000-00805F9B34FB")
    private val rpidCharUuid: UUID = UUID.fromString("0000B002-0000-1000-8000-00805F9B34FB")

    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter

    private var gattServer: BluetoothGattServer? = null

    private var isScanning: Boolean = false
    private var isAdvertising: Boolean = false
    private var allowDuplicates: Boolean = true
    private var formatVersion: Int = 1

    private val discoveredRssi: MutableMap<String, Int> = mutableMapOf()
    private val discoveredAt: MutableMap<String, Long> = mutableMapOf()

    private val connectQueue: ArrayDeque<BluetoothDevice> = ArrayDeque()
    private val lastConnectAttemptAtMs: MutableMap<String, Long> = mutableMapOf()
    private var activeGatt: BluetoothGatt? = null

    private val maxConnectQueue: Int = 20
    private val cooldownPerPeerMs: Long = 10_000

    private val prefs: SharedPreferences =
        appContext.getSharedPreferences("barnard", Context.MODE_PRIVATE)

    init {
        methods.setMethodCallHandler(this)

        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        debugEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                debugEventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                debugEventSink = null
            }
        })
    }

    fun dispose() {
        methods.setMethodCallHandler(null)
        stopScan()
        stopAdvertise()
        eventSink = null
        debugEventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapabilities" -> result.success(
                mapOf(
                    "supportedTransports" to listOf("ble"),
                    "supportsConnectionlessRpid" to false,
                    "supportsGattFallback" to true,
                    "supportsBackground" to false,
                    "supportsHighRateRssi" to false,
                )
            )
            "getState" -> result.success(mapOf("isScanning" to isScanning, "isAdvertising" to isAdvertising))
            "startScan" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                allowDuplicates = args["allowDuplicates"] as? Boolean ?: true
                startScan()
                result.success(null)
            }
            "stopScan" -> {
                stopScan()
                result.success(null)
            }
            "startAdvertise" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                formatVersion = (args["formatVersion"] as? Int) ?: 1
                startAdvertise()
                result.success(null)
            }
            "stopAdvertise" -> {
                stopAdvertise()
                result.success(null)
            }
            "startAuto" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val scan = args["scan"] as? Map<*, *>
                val adv = args["advertise"] as? Map<*, *>
                allowDuplicates = scan?.get("allowDuplicates") as? Boolean ?: true
                formatVersion = adv?.get("formatVersion") as? Int ?: 1

                val wasScanning = isScanning
                val wasAdvertising = isAdvertising
                startScan()
                startAdvertise()
                result.success(
                    mapOf(
                        "scanningStarted" to (!wasScanning && isScanning),
                        "advertisingStarted" to (!wasAdvertising && isAdvertising),
                        "issues" to emptyList<Any>(),
                    )
                )
            }
            "stopAuto" -> {
                stopScan()
                stopAdvertise()
                result.success(null)
            }
            "dispose" -> {
                dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startScan() {
        val a = adapter ?: run {
            emitConstraint("bluetooth_unavailable", "BluetoothAdapter is null")
            return
        }
        if (!a.isEnabled) {
            emitConstraint("bluetooth_off", "Bluetooth is disabled")
            return
        }
        if (!hasScanPermission()) {
            emitConstraint("permission_denied", "Missing BLUETOOTH_SCAN permission", requiredAction = "grant_permission")
            return
        }
        val s = adapter?.bluetoothLeScanner ?: run {
            emitError("scan_failed", "BluetoothLeScanner is null", recoverable = true)
            return
        }
        if (isScanning) return

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        // Scan without a filter and apply Barnard matching in code.
        // This improves iOS discoverability when the service UUID is not present.
        s.startScan(emptyList(), settings, scanCallback)
        isScanning = true
        emitState("scan_start")
        emitDebug("info", "scan_start", mapOf("allowDuplicates" to allowDuplicates))
    }

    private fun stopScan() {
        if (!isScanning) return
        if (hasScanPermission()) {
            adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        }
        isScanning = false
        connectQueue.clear()
        activeGatt?.close()
        activeGatt = null
        emitState("scan_stop")
        emitDebug("info", "scan_stop", null)
    }

    private fun startAdvertise() {
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
        val adv = a.bluetoothLeAdvertiser ?: run {
            emitError("advertise_failed", "BluetoothLeAdvertiser is null", recoverable = true)
            return
        }
        if (isAdvertising) return

        ensureGattServer()

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(serviceUuid))
            .setIncludeDeviceName(false)
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
                "localName" to "BNRD",
            )
        )
    }

    private fun stopAdvertise() {
        if (!isAdvertising) return
        if (hasAdvertisePermission()) {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        }
        isAdvertising = false
        gattServer?.close()
        gattServer = null
        emitState("advertise_stop")
        emitDebug("info", "advertise_stop", null)
    }

    @SuppressLint("MissingPermission")
    private fun ensureGattServer() {
        if (gattServer != null) return
        if (!hasConnectPermission()) {
            emitConstraint("permission_denied", "Missing BLUETOOTH_CONNECT permission", requiredAction = "grant_permission")
            return
        }
        val manager = bluetoothManager ?: return
        val server = manager.openGattServer(appContext, gattServerCallback)
        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val ch = BluetoothGattCharacteristic(
            rpidCharUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        service.addCharacteristic(ch)
        server.addService(service)
        gattServer = server
        emitDebug("info", "gatt_server_started", null)
    }

    private fun computePayload(nowMs: Long): ByteArray {
        val rotationSeconds = 600L
        val window = (nowMs / 1000L) / rotationSeconds
        val seed = getOrCreateSeed()

        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(seed, "HmacSHA256"))
        val msg = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(window).array()
        val digest = mac.doFinal(msg)

        val out = ByteArray(17)
        out[0] = (formatVersion and 0xFF).toByte()
        System.arraycopy(digest, 0, out, 1, 16)
        return out
    }

    private fun getOrCreateSeed(): ByteArray {
        val key = "rpidSeed"
        val existing = prefs.getString(key, null)
        if (existing != null) {
            val bytes = Base64.decode(existing, Base64.DEFAULT)
            if (bytes.size >= 16) return bytes
        }
        val bytes = ByteArray(32)
        java.security.SecureRandom().nextBytes(bytes)
        prefs.edit().putString(key, Base64.encodeToString(bytes, Base64.NO_WRAP)).apply()
        return bytes
    }

    private fun emitState(reasonCode: String?) {
        val payload = mapOf(
            "type" to "state",
            "timestamp" to BarnardIso8601.now(),
            "state" to mapOf("isScanning" to isScanning, "isAdvertising" to isAdvertising),
            "reasonCode" to reasonCode,
        )
        mainHandler.post { eventSink?.success(payload) }
    }

    private fun emitConstraint(code: String, message: String?, requiredAction: String? = null) {
        val payload = mapOf(
            "type" to "constraint",
            "timestamp" to BarnardIso8601.now(),
            "code" to code,
            "message" to message,
            "requiredAction" to requiredAction,
        )
        mainHandler.post { eventSink?.success(payload) }
    }

    private fun emitError(code: String, message: String, recoverable: Boolean? = null) {
        val payload = mapOf(
            "type" to "error",
            "timestamp" to BarnardIso8601.now(),
            "code" to code,
            "message" to message,
            "recoverable" to recoverable,
        )
        mainHandler.post { eventSink?.success(payload) }
    }

    private fun emitDetection(timestampMs: Long, rssi: Int, payloadBytes: ByteArray) {
        if (payloadBytes.size != 17) {
            emitDebug("warn", "payload_invalid_length", mapOf("length" to payloadBytes.size))
            return
        }
        val version = payloadBytes[0].toInt() and 0xFF
        if (version != 1) {
            emitDebug("warn", "payload_unsupported_version", mapOf("formatVersion" to version))
            return
        }
        val rpid = payloadBytes.copyOfRange(1, 17)
        val displayId = rpid.copyOfRange(0, 4).joinToString("") { b -> "%02x".format(b) }
        val payload = mapOf(
            "type" to "detection",
            "timestamp" to BarnardIso8601.fromMs(timestampMs),
            "transport" to "ble",
            "formatVersion" to version,
            "rpid" to Base64.encodeToString(rpid, Base64.NO_WRAP),
            "displayId" to displayId,
            "rssi" to rssi,
            "rssiSummary" to null,
            "payloadRaw" to Base64.encodeToString(payloadBytes, Base64.NO_WRAP),
        )
        mainHandler.post { eventSink?.success(payload) }
    }

    private fun emitDebug(level: String, name: String, data: Map<String, Any?>?) {
        val payload = mapOf(
            "type" to "debug",
            "timestamp" to BarnardIso8601.now(),
            "level" to level,
            "name" to name,
            "data" to data,
        )
        mainHandler.post { debugEventSink?.success(payload) }
    }

    private fun hasScanPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasAdvertisePermission(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    }

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

    private val scanCallback = object : ScanCallback() {
        override fun onScanFailed(errorCode: Int) {
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
        if (!allowDuplicates) {
            val last = discoveredAt[address]
            if (last != null && nowMs - last < 2_000) return
        }
        discoveredRssi[address] = result.rssi
        discoveredAt[address] = nowMs

        emitDebug("trace", "ble_discovery_result", mapOf(
            "id" to address,
            "rssi" to result.rssi,
            "name" to result.scanRecord?.deviceName
        ))

        enqueueConnect(device)
    }

    private fun isBarnardScanResult(result: ScanResult): Boolean {
        val record = result.scanRecord ?: return false
        val uuids = record.serviceUuids
        val hasService = uuids?.any { it.uuid == serviceUuid } == true
        if (hasService) return true
        // Local Name fallback for iOS foreground advertise.
        if (record.deviceName == "BNRD") return true
        // PoC fallback: try any connectable result and validate via GATT.
        return isConnectableResult(result)
    }

    private fun isConnectableResult(result: ScanResult): Boolean {
        return if (Build.VERSION.SDK_INT >= 26) {
            result.isConnectable
        } else {
            true
        }
    }

    private fun enqueueConnect(device: BluetoothDevice) {
        if (activeGatt != null) return
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
            return
        }
        if (!hasConnectPermission()) {
            emitConstraint("permission_denied", "Missing BLUETOOTH_CONNECT permission", requiredAction = "grant_permission")
            return
        }
        lastConnectAttemptAtMs[key] = nowMs
        activeGatt =
            if (Build.VERSION.SDK_INT >= 23) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        emitDebug("trace", "connect_attempt", mapOf("address" to device.address))
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitError("connect_failed", "status=$status", recoverable = true)
                gatt.close()
                activeGatt = null
                pumpConnectQueue()
                return
            }
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                emitDebug("trace", "connected", mapOf("address" to gatt.device.address))
                gatt.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                gatt.close()
                activeGatt = null
                pumpConnectQueue()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitError("service_discovery_failed", "status=$status", recoverable = true)
                gatt.disconnect()
                return
            }
            val svc = gatt.getService(serviceUuid)
            if (svc == null) {
                emitError("service_not_found", "Barnard service not found", recoverable = true)
                gatt.disconnect()
                return
            }
            val ch = svc.getCharacteristic(rpidCharUuid)
            if (ch == null) {
                emitError("characteristic_not_found", "RPID characteristic not found", recoverable = true)
                gatt.disconnect()
                return
            }
            if (!hasConnectPermission()) {
                emitConstraint("permission_denied", "Missing BLUETOOTH_CONNECT permission", requiredAction = "grant_permission")
                gatt.disconnect()
                return
            }
            @SuppressLint("MissingPermission")
            gatt.readCharacteristic(ch)
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val value = characteristic.value ?: ByteArray(0)
            handleRead(gatt, status, value)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            handleRead(gatt, status, value)
        }

        private fun handleRead(gatt: BluetoothGatt, status: Int, value: ByteArray) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitError("read_failed", "status=$status", recoverable = true)
                gatt.disconnect()
                return
            }
            val address = gatt.device.address ?: ""
            val rssi = discoveredRssi[address] ?: 0
            val ts = discoveredAt[address] ?: System.currentTimeMillis()
            emitDetection(ts, rssi, value)
            gatt.disconnect()
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            val server = gattServer ?: return
            val payload = computePayload(System.currentTimeMillis())
            val slice =
                if (offset <= 0) payload
                else if (offset >= payload.size) ByteArray(0)
                else payload.copyOfRange(offset, payload.size)
            server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
            emitDebug(
                "trace",
                "gatt_read_rpid",
                mapOf(
                    "bytes" to payload.size,
                    "formatVersion" to (payload[0].toInt() and 0xFF),
                    "displayId" to displayIdForPayload(payload),
                )
            )
        }
    }

    private fun displayIdForPayload(payload: ByteArray): String {
        if (payload.size < 5) return ""
        return payload.copyOfRange(1, 5).joinToString("") { b -> "%02x".format(b) }
    }
}
