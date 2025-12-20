import CoreBluetooth
import Flutter
import Foundation

final class BarnardBleController: NSObject {
  // Spec constants (MVP).
  private let discoveryServiceUUID = CBUUID(string: "0000B001-0000-1000-8000-00805F9B34FB")
  private let rpidCharacteristicUUID = CBUUID(string: "0000B002-0000-1000-8000-00805F9B34FB")
  private let localName = "BNRD"

  private let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private let rpid = BarnardRpidGenerator()

  private var centralManager: CBCentralManager!
  private var peripheralManager: CBPeripheralManager!
  private var rpidCharacteristic: CBMutableCharacteristic?

  private var isScanning = false
  private var isAdvertising = false

  private var allowDuplicates = true
  private var formatVersion: UInt8 = 1

  private var discoveredRssi: [UUID: Int] = [:]
  private var discoveredAt: [UUID: Date] = [:]

  private var connectQueue: [UUID] = []
  private var peripheralsById: [UUID: CBPeripheral] = [:]
  private var lastConnectAttemptAt: [UUID: Date] = [:]
  private var activePeripheral: CBPeripheral?

  private let maxConcurrentConnections = 1
  private let cooldownPerPeerSeconds: TimeInterval = 10
  private let maxConnectQueue = 20

  let eventsStreamHandler: BarnardStreamHandler
  let debugEventsStreamHandler: BarnardStreamHandler

  private var eventSink: FlutterEventSink?
  private var debugEventSink: FlutterEventSink?

  override init() {
    let eventsHandler = BarnardStreamHandler()
    let debugHandler = BarnardStreamHandler()
    eventsStreamHandler = eventsHandler
    debugEventsStreamHandler = debugHandler
    super.init()

    eventsHandler.onListen = { [weak self] sink in self?.eventSink = sink }
    eventsHandler.onCancel = { [weak self] in self?.eventSink = nil }
    debugHandler.onListen = { [weak self] sink in self?.debugEventSink = sink }
    debugHandler.onCancel = { [weak self] in self?.debugEventSink = nil }

    centralManager = CBCentralManager(delegate: self, queue: nil)
    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCapabilities":
      result([
        "supportedTransports": ["ble"],
        "supportsConnectionlessRpid": false,
        "supportsGattFallback": true,
        "supportsBackground": false,
        "supportsHighRateRssi": false,
      ])
    case "getState":
      result([
        "isScanning": isScanning,
        "isAdvertising": isAdvertising,
      ])
    case "startScan":
      let args = (call.arguments as? [String: Any]) ?? [:]
      allowDuplicates = (args["allowDuplicates"] as? Bool) ?? true
      startScan()
      result(nil)
    case "stopScan":
      stopScan()
      result(nil)
    case "startAdvertise":
      let args = (call.arguments as? [String: Any]) ?? [:]
      if let v = args["formatVersion"] as? Int, v >= 0, v <= 255 { formatVersion = UInt8(v) }
      startAdvertise()
      result(nil)
    case "stopAdvertise":
      stopAdvertise()
      result(nil)
    case "startAuto":
      let args = (call.arguments as? [String: Any]) ?? [:]
      if let scan = args["scan"] as? [String: Any] {
        allowDuplicates = (scan["allowDuplicates"] as? Bool) ?? true
      }
      if let adv = args["advertise"] as? [String: Any] {
        if let v = adv["formatVersion"] as? Int, v >= 0, v <= 255 { formatVersion = UInt8(v) }
      }

      let wasScanning = isScanning
      let wasAdvertising = isAdvertising
      startScan()
      startAdvertise()
      result([
        "scanningStarted": (!wasScanning && isScanning),
        "advertisingStarted": (!wasAdvertising && isAdvertising),
        "issues": [],
      ])
    case "stopAuto":
      stopScan()
      stopAdvertise()
      result(nil)
    case "dispose":
      stopScan()
      stopAdvertise()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startScan() {
    guard centralManager.state == .poweredOn else {
      emitConstraint(code: "bluetooth_not_ready", message: "CentralManager state=\(centralManager.state.rawValue)")
      return
    }
    if isScanning { return }
    let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
    centralManager.scanForPeripherals(withServices: [discoveryServiceUUID], options: options)
    isScanning = true
    emitState(reasonCode: "scan_start")
    emitDebug(level: "info", name: "scan_start", data: ["allowDuplicates": allowDuplicates])
  }

  private func stopScan() {
    if !isScanning { return }
    centralManager.stopScan()
    isScanning = false
    connectQueue.removeAll()
    activePeripheral = nil
    emitState(reasonCode: "scan_stop")
    emitDebug(level: "info", name: "scan_stop", data: nil)
  }

  private func startAdvertise() {
    guard peripheralManager.state == .poweredOn else {
      emitConstraint(code: "bluetooth_not_ready", message: "PeripheralManager state=\(peripheralManager.state.rawValue)")
      return
    }
    if isAdvertising { return }
    ensureGattService()
    let ad: [String: Any] = [
      CBAdvertisementDataLocalNameKey: localName,
      CBAdvertisementDataServiceUUIDsKey: [discoveryServiceUUID],
    ]
    peripheralManager.startAdvertising(ad)
    isAdvertising = true
    emitState(reasonCode: "advertise_start")
    emitDebug(
      level: "info",
      name: "advertise_start",
      data: [
        "formatVersion": Int(formatVersion),
        "serviceUuid": discoveryServiceUUID.uuidString,
        "localName": localName,
      ]
    )
  }

  private func stopAdvertise() {
    if !isAdvertising { return }
    peripheralManager.stopAdvertising()
    isAdvertising = false
    emitState(reasonCode: "advertise_stop")
    emitDebug(level: "info", name: "advertise_stop", data: nil)
  }

  private func ensureGattService() {
    if rpidCharacteristic != nil { return }

    let ch = CBMutableCharacteristic(
      type: rpidCharacteristicUUID,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )
    let svc = CBMutableService(type: discoveryServiceUUID, primary: true)
    svc.characteristics = [ch]
    peripheralManager.add(svc)
    rpidCharacteristic = ch
    emitDebug(level: "info", name: "gatt_service_added", data: nil)
  }

  private func enqueueConnect(_ peripheral: CBPeripheral) {
    let id = peripheral.identifier
    peripheralsById[id] = peripheral

    if connectQueue.contains(id) || (activePeripheral?.identifier == id) { return }

    if connectQueue.count >= maxConnectQueue {
      emitDebug(level: "warn", name: "connect_queue_full", data: ["max": maxConnectQueue])
      return
    }

    connectQueue.append(id)
    pumpConnectQueue()
  }

  private func pumpConnectQueue() {
    if maxConcurrentConnections <= 0 { return }
    if activePeripheral != nil { return }
    guard let nextId = connectQueue.first else { return }

    let now = Date()
    if let last = lastConnectAttemptAt[nextId], now.timeIntervalSince(last) < cooldownPerPeerSeconds {
      connectQueue.removeFirst()
      connectQueue.append(nextId)
      return
    }

    guard let p = peripheralsById[nextId] else {
      connectQueue.removeFirst()
      return
    }

    connectQueue.removeFirst()
    activePeripheral = p
    lastConnectAttemptAt[nextId] = now

    p.delegate = self
    centralManager.connect(p, options: nil)
    emitDebug(level: "trace", name: "connect_attempt", data: ["id": nextId.uuidString])
  }

  private func emitState(reasonCode: String?) {
    eventSink?([
      "type": "state",
      "timestamp": iso8601.string(from: Date()),
      "state": ["isScanning": isScanning, "isAdvertising": isAdvertising],
      "reasonCode": reasonCode as Any,
    ])
  }

  private func emitConstraint(code: String, message: String?) {
    eventSink?([
      "type": "constraint",
      "timestamp": iso8601.string(from: Date()),
      "code": code,
      "message": message as Any,
      "requiredAction": NSNull(),
    ])
  }

  private func emitError(code: String, message: String, recoverable: Bool? = nil) {
    eventSink?([
      "type": "error",
      "timestamp": iso8601.string(from: Date()),
      "code": code,
      "message": message,
      "recoverable": recoverable as Any,
    ])
  }

  private func emitDetection(timestamp: Date, rssi: Int, payload: Data) {
    guard payload.count == 17 else {
      emitDebug(level: "warn", name: "payload_invalid_length", data: ["length": payload.count])
      return
    }
    let version = Int(payload[0])
    if version != 1 {
      emitDebug(level: "warn", name: "payload_unsupported_version", data: ["formatVersion": version])
      return
    }
    let rpidBytes = payload.subdata(in: 1 ..< 17)
    let displayId = rpidBytes.prefix(4).map { String(format: "%02x", $0) }.joined()

    eventSink?([
      "type": "detection",
      "timestamp": iso8601.string(from: timestamp),
      "transport": "ble",
      "formatVersion": version,
      "rpid": rpidBytes.base64EncodedString(),
      "displayId": displayId,
      "rssi": rssi,
      "rssiSummary": NSNull(),
      "payloadRaw": payload.base64EncodedString(),
    ])
  }

  private func emitDebug(level: String, name: String, data: [String: Any]?) {
    debugEventSink?([
      "type": "debug",
      "timestamp": iso8601.string(from: Date()),
      "level": level,
      "name": name,
      "data": data as Any,
    ])
  }
}

extension BarnardBleController: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    emitDebug(level: "info", name: "central_state", data: ["state": central.state.rawValue])
    if central.state != .poweredOn, isScanning {
      stopScan()
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let now = Date()
    discoveredRssi[peripheral.identifier] = RSSI.intValue
    discoveredAt[peripheral.identifier] = now

    emitDebug(level: "trace", name: "ble_discovery_result", data: [
      "id": peripheral.identifier.uuidString,
      "rssi": RSSI.intValue,
      "name": (advertisementData[CBAdvertisementDataLocalNameKey] as? String) as Any,
    ])

    enqueueConnect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    emitDebug(level: "trace", name: "connected", data: ["id": peripheral.identifier.uuidString])
    peripheral.discoverServices([discoveryServiceUUID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    emitError(code: "connect_failed", message: error?.localizedDescription ?? "unknown", recoverable: true)
    activePeripheral = nil
    pumpConnectQueue()
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    activePeripheral = nil
    pumpConnectQueue()
  }
}

extension BarnardBleController: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
      emitError(code: "service_discovery_failed", message: error.localizedDescription, recoverable: true)
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    guard let services = peripheral.services, let svc = services.first(where: { $0.uuid == discoveryServiceUUID }) else {
      emitError(code: "service_not_found", message: "Barnard service not found", recoverable: true)
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics([rpidCharacteristicUUID], for: svc)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let error = error {
      emitError(code: "characteristic_discovery_failed", message: error.localizedDescription, recoverable: true)
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    guard let chars = service.characteristics,
      let ch = chars.first(where: { $0.uuid == rpidCharacteristicUUID })
    else {
      emitError(code: "characteristic_not_found", message: "RPID characteristic not found", recoverable: true)
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.readValue(for: ch)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error = error {
      emitError(code: "read_failed", message: error.localizedDescription, recoverable: true)
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    guard let value = characteristic.value else {
      emitError(code: "read_failed", message: "empty characteristic value", recoverable: true)
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    let id = peripheral.identifier
    let rssi = discoveredRssi[id] ?? 0
    let ts = discoveredAt[id] ?? Date()
    emitDetection(timestamp: ts, rssi: rssi, payload: value)
    centralManager.cancelPeripheralConnection(peripheral)
  }
}

extension BarnardBleController: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    emitDebug(level: "info", name: "peripheral_state", data: ["state": peripheral.state.rawValue])
    if peripheral.state != .poweredOn, isAdvertising {
      stopAdvertise()
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    if let error = error {
      emitError(code: "gatt_service_add_failed", message: error.localizedDescription, recoverable: false)
    }
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error = error {
      emitError(code: "advertise_failed", message: error.localizedDescription, recoverable: true)
      isAdvertising = false
      emitState(reasonCode: "advertise_failed")
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    let payload = rpid.currentPayload(formatVersion: formatVersion, now: Date())
    request.value = payload
    peripheral.respond(to: request, withResult: .success)
    var displayId = ""
    if payload.count >= 5 {
      let bytes = payload.subdata(in: 1 ..< 5)
      displayId = bytes.map { String(format: "%02x", $0) }.joined()
    }
    emitDebug(
      level: "trace",
      name: "gatt_read_rpid",
      data: [
        "bytes": payload.count,
        "formatVersion": Int(formatVersion),
        "displayId": displayId,
      ]
    )
  }
}
