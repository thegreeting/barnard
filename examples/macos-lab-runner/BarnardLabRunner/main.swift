// Use of this source code is governed by a BSD-style license.

import Barnard
import CoreBluetooth
import Foundation

// MARK: - Exit codes

/// The device-lab orchestrator judges a run by its exit code and by the last
/// `RESULT=` line, so the two are decided together in `finish`.
enum LabExit: Int32 {
  /// Rendezvous met.
  case pass = 0
  /// Harness or argument problem; the radio was never really exercised.
  case harness = 1
  /// The radio worked but the rendezvous condition was not met in time.
  case rendezvousNotMet = 2
  /// Bluetooth is unauthorized, powered off, or unsupported on this host.
  case bluetoothUnavailable = 3
}

// MARK: - Runner

/// Headless BarnardEngine host for the device lab.
///
/// Everything here runs on the main queue: `BarnardEngine` requires it, and the
/// timeout and signal sources are attached to the same queue so no engine call
/// is ever made concurrently.
final class LabRunner {
  private let options: LabOptions
  private let reporter: LabReporter
  private let engine = BarnardEngine()

  /// Peer display ids seen this run, deduplicated. The rendezvous condition
  /// counts distinct peers, not detections.
  private var foundPeers: Set<String> = []
  private var announcedDisplayId = false
  private var finished = false
  /// Last CoreBluetooth manager states observed through the debug stream. They
  /// are what separates "not granted" from "granted but the radio is off".
  private var centralState: CBManagerState?
  private var peripheralState: CBManagerState?
  private var relayTimer: DispatchSourceTimer?

  init(options: LabOptions, reporter: LabReporter) {
    self.options = options
    self.reporter = reporter
  }

  // MARK: Lifecycle

  func start() {
    engine.onEvent = { [weak self] event in self?.handle(event) }
    engine.onDebugEvent = { [weak self] event in self?.handleDebug(event) }

    engine.configure(eventCode: options.eventCode)

    if options.relayEnabled {
      engine.configureParticipantRelay(verifier: LabPermissiveRelayVerifier())
      // The relay only takes lease decisions when it is advanced, and a device
      // that stops hearing anything would otherwise keep serving an expired
      // lease. One tick per decision boundary is the documented minimum.
      let timer = DispatchSource.makeTimerSource(queue: .main)
      let interval = Double(BarnardEngine.relayDecisionBoundaryMilliseconds) / 1000.0
      timer.schedule(deadline: .now() + interval, repeating: interval)
      timer.setEventHandler { [weak self] in self?.engine.advanceParticipantRelay() }
      timer.resume()
      relayTimer = timer
    }

    reporter.emitJson([
      "type": "runner_start",
      "eventCode": options.eventCode,
      "role": options.role.rawValue,
      "relay": options.relayEnabled,
      "expectPeers": options.expectPeers,
      "timeoutSeconds": options.timeoutSeconds,
    ])

    engine.requestPermissions { [weak self] status in
      guard let self else { return }
      self.reporter.emitJson([
        "type": "permissions",
        "canScan": status.canScan,
        "canAdvertise": status.canAdvertise,
        "missing": status.missingPermissions,
        "blocked": status.blockedPermissions,
      ])
      self.startRadio()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + options.timeoutSeconds) { [weak self] in
      self?.finishOnTimeout()
    }
  }

  private func startRadio() {
    switch options.role {
    case .advertise:
      engine.startAdvertise()
    case .scan:
      engine.startScan()
    case .auto:
      engine.startAuto()
    }
  }

  /// SIGTERM and SIGINT are handled through dispatch sources rather than C
  /// handlers, so stopping the engine and printing the last line happen on the
  /// main queue like every other call.
  func installSignalHandlers() {
    for signalNumber in [SIGTERM, SIGINT] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler { [weak self] in
        self?.finish(.rendezvousNotMet, "FAIL", "interrupted")
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private var signalSources: [DispatchSourceSignal] = []

  // MARK: Engine events

  private func handle(_ event: BarnardEvent) {
    switch event {
    case .state(let state):
      reporter.emitJson([
        "type": "state",
        "isScanning": state.isScanning,
        "isAdvertising": state.isAdvertising,
        "eventCode": state.eventCode ?? NSNull(),
        "reasonCode": state.reasonCode ?? NSNull(),
      ])
      // The display id is derived from the TEK for the joined event, so it is
      // only meaningful once the radio is actually up. It is announced on the
      // first radio-active state for any role, including `--role scan`, where
      // nothing is advertised but the id still identifies this host to a
      // human reading the log.
      if !announcedDisplayId, state.isScanning || state.isAdvertising {
        announcedDisplayId = true
        reporter.emitMarker("BARNARD_MACHOST_DISPLAY_ID=\(engine.getMyDisplayId())")
      }

    case .detection(let detection):
      reporter.emitJson([
        "type": "detection",
        "rpid": detection.rpid,
        "rssi": detection.rssi,
        "enin": detection.enin,
        "formatVersion": detection.formatVersion,
        "detectedDisplayId": detection.detectedDisplayId ?? NSNull(),
      ])
      notePeer(detection.detectedDisplayId)

    case .rssiUpdate(let update):
      reporter.emitJson([
        "type": "rssi_update",
        "rpid": update.rpid,
        "rssi": update.rssi,
        "enin": update.enin,
        "detectedDisplayId": update.detectedDisplayId ?? NSNull(),
      ])
      // A peer's display id comes from a GATT read that completes after the
      // first advertisement is seen, so it often arrives on an rssi update
      // rather than on the detection that started the connection.
      notePeer(update.detectedDisplayId)

    case .error(let error):
      reporter.emitJson([
        "type": "error",
        "code": error.code,
        "message": error.message,
        "recoverable": error.recoverable ?? NSNull(),
      ])

    case .constraint(let constraint):
      reporter.emitJson([
        "type": "constraint",
        "code": constraint.code,
        "message": constraint.message ?? NSNull(),
      ])

    case .eventInfoHint(let hint):
      reporter.emitJson([
        "type": "event_info_hint",
        "eventDisplayName": hint.eventInfo.eventDisplayName,
        "additionalNamesOmitted": hint.additionalNamesOmitted,
        "additionalEventsOmitted": hint.additionalEventsOmitted,
      ])

    case .eventInfoEnvelopeV2(let envelope):
      // Only the receiver state and the size are logged. RADIO_SELF_VERIFIED
      // means the signature checks out, not that the event is registered.
      let state = String(describing: envelope.receiverState)
      reporter.emitJson([
        "type": "event_info_envelope_v2",
        "receiverState": state,
        "bytes": envelope.rawContainer.count,
      ])
      reporter.emitMarker("BARNARD_MACHOST_ENVELOPE_V2=\(state)")

    case .relayDecision(let decision):
      // The digest is a local dedup key, not an identifier of a person or a
      // device.
      let digest = decision.payloadDigest.map { String(format: "%02x", $0) }.joined()
      reporter.emitJson([
        "type": "relay_decision",
        "decision": decision.decision.rawValue,
        "hop": decision.hop,
        "reason": decision.reason,
        "payloadDigest": digest,
      ])
      reporter.emitMarker("BARNARD_MACHOST_RELAY=\(decision.decision.rawValue):\(digest)")
    }
  }

  private func handleDebug(_ event: BarnardDebugEvent) {
    var payload: [String: Any] = ["type": "debug", "name": event.name, "level": event.level]
    if let data = event.data {
      // Nested rather than merged: debug payloads carry their own `name` key
      // (a peer's advertised local name), which would otherwise overwrite the
      // debug event's name and make the stream unparseable.
      var nested: [String: Any] = [:]
      for (key, value) in data where JSONSerialization.isValidJSONObject([key: value]) {
        nested[key] = value
      }
      payload["data"] = nested
    }
    reporter.emitJson(payload)

    guard let raw = event.data?["state"] as? Int, let state = CBManagerState(rawValue: raw) else {
      return
    }
    switch event.name {
    case "central_state": centralState = state
    case "peripheral_state": peripheralState = state
    default: break
    }
  }

  private func notePeer(_ displayId: String?) {
    guard let displayId, !displayId.isEmpty, !finished else { return }
    guard foundPeers.insert(displayId).inserted else { return }
    reporter.emitMarker("BARNARD_MACHOST_FOUND=\(displayId)")
    if foundPeers.count >= options.expectPeers {
      finish(.pass, "PASS", "peers=\(foundPeers.count) expected=\(options.expectPeers)")
    }
  }

  // MARK: Finishing

  private func finishOnTimeout() {
    guard !finished else { return }
    // A timeout is only a rendezvous failure when the radio was actually
    // usable. Anything else is a harness problem the lab host has to fix, and
    // must not be reported as a failed radio test.
    if let blocker = bluetoothBlocker() {
      finish(.bluetoothUnavailable, "ERROR", blocker)
      return
    }
    finish(
      .rendezvousNotMet,
      "FAIL",
      "timeout after \(Int(options.timeoutSeconds))s peers=\(foundPeers.count) expected=\(options.expectPeers)"
    )
  }

  /// Why the radio could not have worked, or nil when it could have.
  private func bluetoothBlocker() -> String? {
    switch CBManager.authorization {
    case .denied:
      return "bluetooth permission denied for org.levarac.barnard.LabRunner"
    case .restricted:
      return "bluetooth permission restricted for org.levarac.barnard.LabRunner"
    case .notDetermined:
      // The one-time TCC prompt was never answered. On a headless lab host
      // nobody is there to answer it, so this is the expected shape of "the
      // grant has not been done yet" and it is not a radio failure.
      return "bluetooth permission not determined; the one-time grant has not been made on this host"
    default:
      break
    }
    for state in [centralState, peripheralState].compactMap({ $0 }) {
      switch state {
      case .poweredOff: return "bluetooth is powered off"
      case .unsupported: return "bluetooth is unsupported on this host"
      case .unauthorized: return "bluetooth is unauthorized for this process"
      default: continue
      }
    }
    return nil
  }

  private func finish(_ code: LabExit, _ verdict: String, _ detail: String) {
    guard !finished else { return }
    finished = true
    relayTimer?.cancel()
    relayTimer = nil
    engine.dispose()
    reporter.emitResult(verdict, detail)
    exit(code.rawValue)
  }
}

// MARK: - Entry point

let reporter = LabReporter(logPath: LabOptions.logPathHint(CommandLine.arguments))

do {
  let options = try LabOptions.parse(Array(CommandLine.arguments.dropFirst()))
  let runner = LabRunner(options: options, reporter: reporter)
  runner.installSignalHandlers()
  runner.start()
  // CoreBluetooth delivers its callbacks on the main queue, which
  // `dispatchMain` services. Every exit path goes through `finish`, which
  // prints the `RESULT=` line and calls `exit`.
  dispatchMain()
} catch {
  FileHandle.standardError.write(Data((LabOptions.usage + "\n").utf8))
  reporter.emitResult("ERROR", "\(error)")
  exit(LabExit.harness.rawValue)
}
