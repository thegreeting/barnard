// Use of this source code is governed by a BSD-style license.

#if canImport(BarnardCore)
import BarnardCore
#endif
import CoreBluetooth
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Flutter-free, Swift-first public event/value types for `BarnardEngine`.
///
/// These mirror the shapes emitted on the Flutter `barnard/events` and
/// `barnard/debugEvents` channels (see
/// `packages/dart/barnard/ios/barnard/Sources/barnard/BarnardBleController.swift`)
/// but are expressed as native Swift types instead of untyped
/// `[String: Any]` dictionaries.

public struct BarnardBeaconChain: Equatable {
  public let chainId: String
  public let genesisUnixSeconds: Int
  public let slotSeconds: Int

  public static let ethereumMainnet = BarnardBeaconChain(
    chainId: "mainnet",
    genesisUnixSeconds: 1_606_824_023,
    slotSeconds: 12
  )

  public init(chainId: String, genesisUnixSeconds: Int, slotSeconds: Int) {
    self.chainId = chainId
    self.genesisUnixSeconds = genesisUnixSeconds
    self.slotSeconds = slotSeconds
  }

  fileprivate var internalConfig: BarnardCrypto.BeaconChainConfig {
    BarnardCrypto.BeaconChainConfig(
      chainId: chainId,
      genesisUnixSeconds: genesisUnixSeconds,
      slotSeconds: slotSeconds
    )
  }
}

public enum BarnardEninMode: String {
  case fixedLength
  case beaconSlot

  fileprivate var internalMode: BarnardCrypto.EninMode {
    switch self {
    case .fixedLength: return .fixedLength
    case .beaconSlot: return .beaconSlot
    }
  }
}

public struct BarnardCapabilities {
  public let supportedTransports: [String]
  public let supportsConnectionlessRpid: Bool
  public let supportsGattFallback: Bool
  public let supportsBackground: Bool
  public let supportsHighRateRssi: Bool
  public let eninMode: BarnardEninMode
  public let eninSeconds: Int
  public let beaconChain: BarnardBeaconChain
}

public struct BarnardState {
  public let isScanning: Bool
  public let isAdvertising: Bool
  public let eventCode: String?
  public let eninMode: BarnardEninMode
  public let eninSeconds: Int
  public let beaconChain: BarnardBeaconChain
  public let reasonCode: String?
}

public struct BarnardPermissionStatus {
  public let platform: String
  public let permissions: [String: String]
  public let requiredPermissions: [String]
  public let missingPermissions: [String]
  public let requestablePermissions: [String]
  public let blockedPermissions: [String]
  public let canScan: Bool
  public let canAdvertise: Bool
}

public struct BarnardDetectionEvent {
  public let timestamp: Date
  public let rssi: Int
  public let formatVersion: Int
  /// Lowercase hex, 17 bytes.
  public let rpid: String
  /// Lowercase hex, this device's own current RPID at `timestamp`.
  public let reporterRpid: String
  public let detectedDisplayId: String?
  public let enin: Int
  public let debugLocalName: String?
}

public struct BarnardRssiUpdateEvent {
  public let timestamp: Date
  public let rssi: Int
  public let rpid: String
  public let reporterRpid: String
  public let enin: Int
  public let detectedDisplayId: String?
  public let debugLocalName: String?
}

public struct BarnardErrorEvent {
  public let code: String
  public let message: String
  public let recoverable: Bool?
}

public struct BarnardConstraintEvent {
  public let code: String
  public let message: String?
}

public struct BarnardEventInfoHintEvent {
  public let peripheralId: UUID
  /// Empty for an overflow marker. Hosts must not retain hint data past the discovery session.
  public let eventInfo: BarnardEventInfo
  public let additionalNamesOmitted: Bool
  public let additionalEventsOmitted: Bool
}

/// Outcome of running a B005 v2 container (spec 122) through
/// `BarnardB005EnvelopeV2.verify` on the receive path.
///
/// Deliberately a two-case sum rather than a state field: `REGISTRY_VERIFIED`
/// is unrepresentable here, so the SDK cannot assign it even by mistake. That
/// tier is the host's to assign, and only after the host has performed an
/// authenticated registry read (spec 122, "Receiver policy").
public enum BarnardB005EnvelopeV2Receipt {
  /// Steps 1-7 passed: the signature verifies and `eventId` is self-consistent
  /// with the key set carried in the envelope. Registration is NOT confirmed,
  /// and this MUST NOT be presented to a user as "verified" or "registered".
  case radioSelfVerified(BarnardB005VerifiedEnvelope)
  /// Verification did not succeed. The SDK reports *that* it failed, not *why*:
  /// `verify` returns nothing for a malformed container and for a container
  /// whose signature does not check out, and the two are not distinguished.
  case unverified

  public var receiverState: BarnardB005ReceiverState {
    switch self {
    case .radioSelfVerified: return .RADIO_SELF_VERIFIED
    case .unverified: return .UNVERIFIED
    }
  }

  public var verifiedEnvelope: BarnardB005VerifiedEnvelope? {
    switch self {
    case .radioSelfVerified(let envelope): return envelope
    case .unverified: return nil
    }
  }
}

/// A B005 v2 signed envelope read from a peer's event-info characteristic.
///
/// Emitted for every container whose `formatVersion` is
/// `BarnardB005EnvelopeV2.formatVersion` (0x03), verified or not: a failed
/// envelope is surfaced to the host rather than silently dropped.
public struct BarnardEventInfoEnvelopeV2Event {
  public let peripheralId: UUID
  public let receipt: BarnardB005EnvelopeV2Receipt
  /// The container exactly as it came off the wire. Spec 134 re-broadcast
  /// copies the signature byte for byte, so this is never re-encoded.
  public let rawContainer: Data

  public var receiverState: BarnardB005ReceiverState { receipt.receiverState }
  public var verifiedEnvelope: BarnardB005VerifiedEnvelope? { receipt.verifiedEnvelope }
}

/// What the spec 134 density controller decided about the selected envelope.
///
/// The controller renews a lease by ending the old one and electing again, so
/// a `.keep` is always preceded by a `.stop` for the same digest. `.keep` is
/// the engine's name for "elected again with the digest that was just being
/// served"; the relay itself draws no distinction.
public enum BarnardRelayDecision: String {
  case broadcast
  case keep
  case stop
}

/// A spec 134 relay decision, surfaced so a host can observe whether and why
/// an envelope was re-broadcast. No peer handle, election secret, or density
/// count leaves the controller: the envelope is identified by its payload
/// digest, which is already derivable from the bytes on the wire.
public struct BarnardRelayDecisionEvent {
  public let decision: BarnardRelayDecision
  /// `SHA256(signedEnvelope)` of the envelope the decision is about.
  public let payloadDigest: Data
  /// The `relayHopCount` this device serves (observed minimum + 1). For
  /// `.stop` it is the hop last served.
  public let hop: Int
  /// `elected`, `renewed`, `lease_ended`, `host_stop`,
  /// `definition_invalidated`, or `own_value_precedence`.
  public let reason: String
}

/// Why a host-supplied own B005 v2 container was refused.
///
/// The checks are structural only: the SDK never signs, re-encodes, or
/// re-verifies what the host hands it, so a container that is well formed at
/// this layer is served byte for byte even if its signature or its validity
/// window would fail a peer's `BarnardB005EnvelopeV2.verify`.
public enum BarnardOwnEnvelopeV2Error: Error, Equatable {
  /// Byte 1 is not zero. The device's own value is a hop-zero source, and a
  /// container already carrying a hop is a relayed copy, not ours to serve.
  ///
  /// This is the one guard the shared structural validator does not supply:
  /// `BarnardB005EnvelopeV2.validateStructure` allows any hop within the spec
  /// 134 limit, because a receiver must accept relayed copies.
  case nonZeroHopCount
  /// The container failed a clock-independent structural check that
  /// `BarnardB005EnvelopeV2.verify` applies to any container it is given.
  case malformedContainer(BarnardB005StructureError)
}

public enum BarnardEvent {
  case state(BarnardState)
  case constraint(BarnardConstraintEvent)
  case error(BarnardErrorEvent)
  case detection(BarnardDetectionEvent)
  case rssiUpdate(BarnardRssiUpdateEvent)
  case eventInfoHint(BarnardEventInfoHintEvent)
  case eventInfoEnvelopeV2(BarnardEventInfoEnvelopeV2Event)
  case relayDecision(BarnardRelayDecisionEvent)
}

/// Default relay clock: uptime milliseconds, unaffected by wall-clock jumps.
internal final class BarnardEngineRelayUptimeClock: BarnardRelayMonotonicClock {
  func relayNowMilliseconds() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000.0) }
}

/// Default relay ENIN source: whatever the engine's own B004 clock reports.
internal final class BarnardEngineRelayEninSource: BarnardRelayEninSource {
  private let read: () -> UInt32?
  init(_ read: @escaping () -> UInt32?) { self.read = read }
  func relayCurrentEnin() -> UInt32? { read() }
}

/// Default joined-event provider: spec 134 decision 3 lets a verified but
/// unjoined receiver relay, so "no joined event" is a valid default.
internal final class BarnardEngineRelayNoJoinedEvent: BarnardRelayJoinedEventProvider {
  func relayJoinedEventId() -> [UInt8]? { nil }
}

/// Bridges the relay's start/stop output onto the engine's B005 serving path.
internal final class BarnardEngineRelaySink: BarnardRelayOutputSink {
  weak var engine: BarnardEngine?
  func startServingRelayContainer(_ bytes: [UInt8]) { engine?.relaySinkDidStart(Data(bytes)) }
  func stopServingRelayContainer() { engine?.relaySinkDidStop() }
}

public struct BarnardDebugEvent {
  public let timestamp: Date
  public let level: String
  public let name: String
  public let data: [String: Any]?
}

/// Barnard v2 BLE engine — Flutter-free, Swift-first port of
/// `BarnardBleController` (the Flutter plugin's native controller). Same
/// GATT service (fixed UUID), same v2 wire behavior:
///
/// - B002 RPID (Read, 17 bytes)
/// - B003 displayId (Read, 4 bytes when joined to an event) — `SHA256(TEK)[0:4]`. v2 no longer serves TEK.
/// - B004 EventCodeHash (Read, 0 or 8 bytes)
///
/// TEK is never transmitted over BLE in v2. No device-unique persistent
/// identifier is placed on the wire (same invariant as the Flutter plugin).
public final class BarnardEngine: NSObject {
  // MARK: - UUIDs

  private let discoveryServiceUUID = CBUUID(string: "0000B001-0000-1000-8000-00805F9B34FB")
  private let rpidCharacteristicUUID = CBUUID(string: "0000B002-0000-1000-8000-00805F9B34FB")
  private let displayIdCharacteristicUUID = CBUUID(string: "0000B003-0000-1000-8000-00805F9B34FB")
  private let eventCodeHashCharacteristicUUID = CBUUID(string: "0000B004-0000-1000-8000-00805F9B34FB")
  private let eventInfoCharacteristicUUID = CBUUID(string: "0000B005-0000-1000-8000-00805F9B34FB")
  private let localName = "BNRD"
  private let unavailableRssi = 127

  private var debugLocalName: String {
    #if DEBUG
    let suffix = debugDeviceSuffix()
    return "BND-\(suffix)"
    #else
    return localName
    #endif
  }

  private func debugDeviceSuffix() -> String {
    let deviceSecret = rpid.getDeviceSecret()
    let tail = deviceSecret.suffix(2)
    let hex = tail.map { String(format: "%02x", $0) }.joined().uppercased()
    return hex.isEmpty ? "DEAD" : hex
  }

  private let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  // MARK: - Components

  private let rpid: BarnardRpidGenerator

  // MARK: - BLE Managers

  private var centralManager: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?
  private var pendingPermissionCompletions: [(BarnardPermissionStatus) -> Void] = []

  // MARK: - GATT Characteristics (Peripheral)

  private var rpidCharacteristic: CBMutableCharacteristic?
  private var displayIdCharacteristic: CBMutableCharacteristic?
  private var eventCodeHashCharacteristic: CBMutableCharacteristic?
  private var eventInfoCharacteristic: CBMutableCharacteristic?

  // MARK: - State

  private var isScanning = false
  private var isAdvertising = false
  private var eventInfoServePolicy = BarnardEventInfoServePolicy()
  private var eventInfoDisplayName: String?
  private struct EventInfoSnapshot {
    var value: Data
    var lastRequest: Date
  }
  /// A host-supplied, host-signed hop-zero v2 container (spec 122), served in
  /// place of the v1 payload while it is set.
  private var ownEnvelopeV2Container: Data?
  private var eventInfoSnapshots: [UUID: EventInfoSnapshot] = [:]
  private let eventInfoRetryBudget = BarnardEventInfoRetryBudget()

  // MARK: - Spec 134 participant relay

  private var relayVerifier: (any BarnardRelayVerifier)?
  private var relayJoinedEventProvider: (any BarnardRelayJoinedEventProvider)?
  private var relaySeedMaterial: [UInt8] = []
  private var relayClock: (any BarnardRelayMonotonicClock)?
  private var relayEninSource: (any BarnardRelayEninSource)?
  private let relaySink = BarnardEngineRelaySink()
  private var participantRelay: BarnardParticipantRelay?
  private var relayTimer: DispatchSourceTimer?
  private var relayServedContainer: Data?
  private var relayLastServedDigest: Data?
  /// Set around each relay call so the sink can name the cause of a start or
  /// stop. The relay's sink protocol carries no reason of its own.
  private var relayDecisionReason = "elected"
  private var eventInfoDiscoverySession = BarnardEventInfoDiscoverySession(startedAt: Date().timeIntervalSince1970)
  private var shouldStartScanWhenReady = false
  private var shouldStartAdvertiseWhenReady = false
  private var allowDuplicates = true
  private var formatVersion: UInt8 = 1
  private var eninMode: BarnardCrypto.EninMode = .fixedLength
  private var eninSeconds: Int = 300
  private var beaconChain: BarnardCrypto.BeaconChainConfig = .ethereumMainnet

  private var lastDiscoveryNameById: [UUID: String] = [:]

  // MARK: - Discovery State

  private var discoveredRssi: [UUID: Int] = [:]
  private var discoveredAt: [UUID: Date] = [:]

  // MARK: - Connection Queue

  private var connectQueue: [UUID] = []
  private var peripheralsById: [UUID: CBPeripheral] = [:]
  private var lastConnectAttemptAt: [UUID: Date] = [:]
  private var resolutionBackoffUntil: [UUID: Date] = [:]
  private var pendingBoundaryRetryPeripherals: [UUID: CBPeripheral] = [:]
  private var activePeripheral: CBPeripheral?

  private let maxConcurrentConnections = 1
  private let cooldownPerPeerSeconds: TimeInterval = 10
  private let resolutionFailureBackoffSeconds: TimeInterval = 30
  private let resolutionRejectedBackoffSeconds: TimeInterval = 5 * 60
  private let rpidBoundaryRetryDelaySeconds: TimeInterval = 0.25
  private let maxConnectQueue = 20
  // See BarnardBleController (issue this mirrors): CoreBluetooth's
  // connection/GATT callbacks have no built-in deadline, so a manual
  // watchdog releases a hung `activePeripheral` pin after this many seconds.
  private let connectTimeoutSeconds: TimeInterval = 8
  private var connectWatchdog: DispatchWorkItem?
  private var connectCooldownWorkItem: DispatchWorkItem?

  // MARK: - Central GATT State (per connection)

  private var peripheralCharacteristics: [UUID: [CBUUID: CBCharacteristic]] = [:]
  private var peripheralReadValues: [UUID: PeripheralGattValues] = [:]
  private var b004ReadRetries: [UUID: Int] = [:]
  private let maxB004ReadRetries = 2
  private let b004ReadRetryDelaySeconds: TimeInterval = 0.25

  private struct PeripheralGattValues {
    var eventCodeHash: Data?
    var rpid: Data?
    var rpidReadStartedAt: Date?
    var rpidReadCompletedAt: Date?
    var detectedDisplayId: Data?
  }

  // MARK: - Known Peers (for high-rate RSSI updates)

  private struct KnownPeer {
    let rpid: Data
    let enin: UInt32
    var detectedDisplayId: String?
    var debugLocalName: String?
  }

  private var knownPeers: [UUID: KnownPeer] = [:]

  private func shouldServeGattDisplayId() -> Bool {
    BarnardV2Policy.shouldServeGattDisplayId(eventCode: rpid.eventCode)
  }

  private func currentEnin(_ date: Date = Date()) -> UInt32 {
    BarnardCrypto.calculateEnin(
      for: date,
      mode: eninMode,
      eninSeconds: eninSeconds,
      beaconChain: beaconChain
    )
  }

  private func currentPayload(now: Date) -> Data {
    rpid.currentPayload(
      formatVersion: formatVersion,
      now: now,
      eninMode: eninMode,
      eninSeconds: eninSeconds,
      beaconChain: beaconChain
    )
  }

  private func eninModeName() -> BarnardEninMode {
    switch eninMode {
    case .beaconSlot: return .beaconSlot
    case .fixedLength: return .fixedLength
    }
  }

  private func beaconChainInfo() -> BarnardBeaconChain {
    BarnardBeaconChain(
      chainId: beaconChain.chainId,
      genesisUnixSeconds: beaconChain.effectiveGenesisUnixSeconds,
      slotSeconds: beaconChain.effectiveSlotSeconds
    )
  }

  // MARK: - Event Delivery

  /// Called on the main queue with the same event stream the Flutter plugin
  /// exposes on the `barnard/events` channel.
  public var onEvent: ((BarnardEvent) -> Void)?
  /// Called on the main queue with the same event stream the Flutter plugin
  /// exposes on the `barnard/debugEvents` channel.
  public var onDebugEvent: ((BarnardDebugEvent) -> Void)?

  // MARK: - Initialization

  override public init() {
    rpid = BarnardRpidGenerator()
    super.init()

    registerForApplicationLifecycleNotifications()
  }

  /// Creates an engine whose RPID and TEK path reads and creates its
  /// DeviceSecret through `keyStorage` under the `barnard.rpidSeed` key.
  ///
  /// Inject the same storage instance into `BarnardIdentity` to keep the TEK
  /// and signing-identity roots aligned.
  public init(keyStorage: any BarnardCoreKeyStorage) {
    rpid = BarnardRpidGenerator(keyStorage: keyStorage)
    super.init()

    registerForApplicationLifecycleNotifications()
  }

  // UIKit-only. macOS AppKit has no equivalent worth observing here: the
  // advertising bounce below exists solely to undo iOS's backgrounding of our
  // service UUID into the AdvData overflow area, which macOS does not do. On
  // macOS this registers nothing and advertising simply keeps running.
  private func registerForApplicationLifecycleNotifications() {
    #if canImport(UIKit)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    #endif
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    // A resumed DispatchSourceTimer traps if it is released without being
    // cancelled, so this is required rather than tidiness.
    relayTimer?.cancel()
    relayTimer = nil
  }

  private func ensureCentralManager() -> CBCentralManager {
    if let manager = centralManager {
      return manager
    }
    let manager = CBCentralManager(delegate: self, queue: nil)
    centralManager = manager
    return manager
  }

  private func ensurePeripheralManager() -> CBPeripheralManager {
    if let manager = peripheralManager {
      return manager
    }
    let manager = CBPeripheralManager(delegate: self, queue: nil)
    peripheralManager = manager
    return manager
  }

  private func ensureBleManagers() {
    _ = ensureCentralManager()
    _ = ensurePeripheralManager()
  }

  private func bluetoothPermissionStatus() -> String {
    switch CBManager.authorization {
    case .allowedAlways:
      return "granted"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .notDetermined:
      return "notDetermined"
    @unknown default:
      return "unknown"
    }
  }

  private func permissionStatusPayload() -> BarnardPermissionStatus {
    let permissionName = "ios.bluetooth"
    let status = bluetoothPermissionStatus()
    let missing = status == "granted" ? [] : [permissionName]
    let blocked = (status == "denied" || status == "restricted") ? [permissionName] : []
    let requestable = missing.filter { !blocked.contains($0) }
    // iOS Simulator cannot scan or advertise over BLE even when CoreBluetooth
    // authorization is granted, so capability flags must reflect that gap
    // independently of authorization state. See issue #57.
    let canBle = status == "granted" && !Self.isIosSimulator
    return BarnardPermissionStatus(
      platform: "ios",
      permissions: [permissionName: status],
      requiredPermissions: [permissionName],
      missingPermissions: missing,
      requestablePermissions: requestable,
      blockedPermissions: blocked,
      canScan: canBle,
      canAdvertise: canBle
    )
  }

  private static var isIosSimulator: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }

  // MARK: - Public API

  public func getCapabilities() -> BarnardCapabilities {
    BarnardCapabilities(
      supportedTransports: ["ble"],
      supportsConnectionlessRpid: false,
      supportsGattFallback: true,
      supportsBackground: false,
      supportsHighRateRssi: false,
      eninMode: eninModeName(),
      eninSeconds: eninSeconds,
      beaconChain: beaconChainInfo()
    )
  }

  public func getState() -> BarnardState {
    BarnardState(
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      eventCode: rpid.eventCode,
      eninMode: eninModeName(),
      eninSeconds: eninSeconds,
      beaconChain: beaconChainInfo(),
      reasonCode: nil
    )
  }

  public func configure(
    eninMode: BarnardEninMode = .fixedLength,
    eninSeconds requestedSeconds: Int = 300,
    beaconChain requestedBeaconChain: BarnardBeaconChain = .ethereumMainnet,
    eventCode: String? = nil
  ) {
    self.eninMode = eninMode.internalMode
    self.eninSeconds = min(max(requestedSeconds, 12), 3600)
    beaconChain = requestedBeaconChain.internalConfig

    if let eventCode = eventCode, !eventCode.isEmpty, eventCode != rpid.eventCode {
      resetPeerDiscoveryState(reason: "configure_event")
      rpid.joinEvent(eventCode)
      rebuildGattServiceIfNeeded()
      emitState(reasonCode: "configure_event")
    }

    knownPeers.removeAll()
    emitDebug(level: "info", name: "configure", data: [
      "eninMode": eninModeName().rawValue,
      "eninSeconds": self.eninSeconds,
      "beaconChain": beaconChainInfo().chainId,
    ])
  }

  /// Sets B005's host-local serving state. Both booleans default to false and
  /// are never placed on wire.
  public func configureEventInfoServing(
    organizerDesignated: Bool = false,
    eventActiveForDiscovery: Bool = false,
    eventDisplayName: String? = nil
  ) throws {
    if let eventDisplayName { try BarnardEventInfoCodec.validateEventDisplayName(eventDisplayName) }
    eventInfoServePolicy = BarnardEventInfoServePolicy(
      organizerDesignated: organizerDesignated,
      eventActiveForDiscovery: eventActiveForDiscovery
    )
    eventInfoDisplayName = eventDisplayName
  }

  /// Supplies the pre-encoded, pre-signed B005 v2 container (spec 122) this
  /// device serves as its own event-info value, or clears it when `container`
  /// is nil.
  ///
  /// The host builds the container with `BarnardB005EnvelopeV2.encodeContainer`
  /// in either authority-direct or delegate mode. The SDK does not sign,
  /// re-encode, or re-verify it, and it never assigns `REGISTRY_VERIFIED`: it
  /// only checks that the bytes are a well-formed `0x03` container at hop zero
  /// and then serves them byte for byte.
  ///
  /// A supplied container is not gated on `configureEventInfoServing`. The v1
  /// payload needs that policy because it carries no signature of its own;
  /// supplying a signed container is itself the decision to serve.
  ///
  /// Call on the main queue, like every other engine method.
  ///
  /// - Throws: `BarnardOwnEnvelopeV2Error` when the bytes are not such a
  ///   container. Nothing is stored and any previous container stays in place.
  public func configureOwnEventInfoEnvelopeV2(container: Data?) throws {
    guard let container else {
      ownEnvelopeV2Container = nil
      emitDebug(level: "info", name: "own_envelope_v2", data: ["supplied": false])
      return
    }
    try Self.validateOwnEnvelopeV2Container(container)
    ownEnvelopeV2Container = container
    // This device now has an own value, so it can no longer put a relayed
    // container on the wire. Drop any lease here rather than at the next
    // `advanceParticipantRelay`, so `isRelayServing` never claims a broadcast
    // that has already stopped being possible. The teardown's relay decisions
    // are emitted before this call's own debug event, so a host reading the
    // debug stream sees the lease end and then the container take over.
    tearDownParticipantRelay(reason: "own_value_precedence")
    emitDebug(level: "info", name: "own_envelope_v2", data: [
      "supplied": true, "bytes": container.count,
    ])
  }

  /// The container this device serves as its own hop-zero value, if any.
  public var ownEventInfoEnvelopeV2: Data? { ownEnvelopeV2Container }

  /// Structural gate for a host-supplied own container: every clock-independent
  /// guard `BarnardB005EnvelopeV2.verify` applies, plus a hop-zero requirement.
  ///
  /// `verify` itself is deliberately not called — it needs the current ENIN and
  /// would reject a container provisioned ahead of its own validity window — but
  /// the structural half of it is shared rather than restated, so this gate
  /// cannot drift into accepting a shape a receiver would refuse.
  internal static func validateOwnEnvelopeV2Container(_ container: Data) throws {
    let bytes = [UInt8](container)
    if let structure = BarnardB005EnvelopeV2.validateStructure(container: bytes) {
      throw BarnardOwnEnvelopeV2Error.malformedContainer(structure)
    }
    guard bytes[1] == 0 else { throw BarnardOwnEnvelopeV2Error.nonZeroHopCount }
  }

  /// Enables spec 134 participant relay, or disables it when `verifier` is nil.
  ///
  /// The verifier is host-supplied on purpose. Spec 134 step 3 requires the
  /// authoritative on-chain definition before an envelope may be relayed, and
  /// the SDK has no registry access, so only a `.registryVerified` answer from
  /// the host unlocks re-broadcast. The engine pre-filters on its own radio
  /// verification: an unverified container never reaches this verifier.
  ///
  /// `clock` and `eninSource` default to the engine's uptime clock and its own
  /// B004 ENIN; they exist so tests can step 30-second decision epochs.
  ///
  /// Call on the main queue, like every other engine method. The relay state
  /// machine is not thread-safe, and the Swift engine serializes nothing on
  /// your behalf (the Kotlin engine holds a lock because its GATT server
  /// callbacks genuinely arrive on binder threads).
  public func configureParticipantRelay(
    verifier: (any BarnardRelayVerifier)?,
    joinedEventProvider: (any BarnardRelayJoinedEventProvider)? = nil,
    randomnessSeedMaterial: [UInt8]? = nil,
    clock: (any BarnardRelayMonotonicClock)? = nil,
    eninSource: (any BarnardRelayEninSource)? = nil
  ) {
    tearDownParticipantRelay(reason: "definition_invalidated")
    relayVerifier = verifier
    relayJoinedEventProvider = joinedEventProvider
    relayClock = clock
    relayEninSource = eninSource
    relaySeedMaterial = randomnessSeedMaterial ?? [UInt8](BarnardCrypto.sha256(rpid.getDeviceSecret()))
    relaySink.engine = self
    emitDebug(level: "info", name: "relay_configured", data: ["enabled": verifier != nil])
  }

  /// Runs the relay's expiry, selection, contention, and lease decisions.
  ///
  /// This is the only path that consults the lease clock. Observations do not
  /// take lease decisions, so it must be driven on a timer: a device that
  /// stops hearing anything would otherwise keep serving a lease that has
  /// already run out. The engine drives it internally while a relay is
  /// configured, and also calls it before answering a B005 read. A host that
  /// wants tighter control may call it as well, at least at the decision
  /// boundary cadence of `BarnardEngine.relayDecisionBoundaryMilliseconds`;
  /// calling it more often is harmless because the relay takes at most one
  /// election decision per 30-second epoch.
  ///
  /// Call on the main queue, like every other engine method: the relay state
  /// machine is not thread-safe and the engine serializes nothing for you.
  public func advanceParticipantRelay() {
    // Precedence is enforced here rather than at read time, so the relay never
    // holds a lease this device could not actually put on the wire.
    guard !isServingOwnEventInfo() else {
      tearDownParticipantRelay(reason: "own_value_precedence")
      return
    }
    relayDecisionReason = participantRelay?.isServing == true ? "lease_ended" : "elected"
    participantRelay?.advance()
  }

  /// True while this device is re-broadcasting a relayed envelope, and hence
  /// while a peer reading B005 gets the relayed container rather than nothing
  /// or this device's own value.
  ///
  /// Call on the main queue.
  public var isRelayServing: Bool { participantRelay?.isServing ?? false }

  /// This device's own B005 event-info value, when it has one to serve.
  ///
  /// Two forms, and the signed one wins: a host-supplied hop-zero v2 container
  /// (spec 122), else the v1 `BarnardEventInfoCodec` payload. Both count as an
  /// own value everywhere precedence is decided, including the election gate —
  /// a device serving a signed hop-zero container of its own cannot put a
  /// relayed one on the wire either, so it must not elect or hold density
  /// state for one.
  private func ownEventInfoValue() -> Data? {
    if let ownEnvelopeV2Container { return ownEnvelopeV2Container }
    return try? BarnardEventInfoCodec.payloadIfServing(
      policy: eventInfoServePolicy,
      eventCode: rpid.eventCode,
      eventDisplayName: eventInfoDisplayName,
      b004EventCodeHash: rpid.getEventCodeHash()
    )
  }

  private func isServingOwnEventInfo() -> Bool { ownEventInfoValue() != nil }

  /// Spec 134's decision boundary: `T` = 30 seconds.
  public static let relayDecisionBoundaryMilliseconds = 30_000

  /// How often the engine's internal timer runs the relay forward.
  ///
  /// Deliberately shorter than the decision boundary. A lease starts when a
  /// contention delay ends, so it expires at an arbitrary offset within an
  /// epoch rather than on the boundary; ticking only every 30 seconds would
  /// let a lease be served for up to twice its length before anything noticed.
  /// This bounds that overshoot to one tick. It does not make the device
  /// decide more often -- the relay still takes at most one election decision
  /// per epoch -- and it starts no radio work, so the cost is a timer wake-up
  /// while relaying and nothing at all when the relay is idle.
  internal static let relayTimerIntervalMilliseconds = 5_000

  /// Test seam: the engine's own timer callback, distinct from a host calling
  /// `advanceParticipantRelay`.
  internal func relayTimerDidFire() { advanceParticipantRelay() }

  /// Test seam: whether the self-protecting timer is currently armed.
  internal var relayTimerIsScheduled: Bool { relayTimer != nil }

  private func startRelayTimerIfNeeded() {
    guard relayTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    let interval = DispatchTimeInterval.milliseconds(Self.relayTimerIntervalMilliseconds)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler { [weak self] in self?.relayTimerDidFire() }
    relayTimer = timer
    timer.resume()
  }

  private func stopRelayTimer() {
    relayTimer?.cancel()
    relayTimer = nil
  }

  private func ensureParticipantRelay() -> BarnardParticipantRelay? {
    guard let verifier = relayVerifier else { return nil }
    if let existing = participantRelay { return existing }
    let relay = BarnardParticipantRelay(
      clock: relayClock ?? BarnardEngineRelayUptimeClock(),
      eninSource: relayEninSource ?? BarnardEngineRelayEninSource { [weak self] in self?.currentEnin() },
      verifier: verifier,
      outputSink: relaySink,
      joinedEventProvider: relayJoinedEventProvider ?? BarnardEngineRelayNoJoinedEvent(),
      randomnessSeedMaterial: relaySeedMaterial
    )
    participantRelay = relay
    startRelayTimerIfNeeded()
    return relay
  }

  /// Spec 134: stopping Scan or Advertise clears the lease and the cached
  /// envelope. `hostStop()` is terminal, so the instance is dropped and a
  /// later observation builds a fresh one that rechecks every guard.
  private func tearDownParticipantRelay(reason: String) {
    stopRelayTimer()
    guard let relay = participantRelay else { return }
    relayDecisionReason = reason
    relay.hostStop()
    participantRelay = nil
    relayServedContainer = nil
    relayLastServedDigest = nil
  }

  internal func relaySinkDidStart(_ container: Data) {
    relayServedContainer = container
    let envelope = container.count > 4 ? container.subdata(in: 4..<container.count) : Data()
    let digest = BarnardCrypto.sha256(envelope)
    let decision: BarnardRelayDecision = digest == relayLastServedDigest ? .keep : .broadcast
    relayLastServedDigest = digest
    let hop = container.count > 1 ? Int(container[1]) : 0
    let reason = decision == .keep ? "renewed" : relayDecisionReason
    emitDebug(level: "info", name: "relay_decision", data: [
      "decision": decision.rawValue, "hop": hop, "reason": reason,
    ])
    onEvent?(.relayDecision(BarnardRelayDecisionEvent(
      decision: decision, payloadDigest: digest, hop: hop, reason: reason
    )))
  }

  internal func relaySinkDidStop() {
    let container = relayServedContainer
    relayServedContainer = nil
    let digest = relayLastServedDigest ?? Data()
    let hop = (container?.count ?? 0) > 1 ? Int(container![1]) : 0
    emitDebug(level: "info", name: "relay_decision", data: [
      "decision": BarnardRelayDecision.stop.rawValue, "hop": hop, "reason": relayDecisionReason,
    ])
    onEvent?(.relayDecision(BarnardRelayDecisionEvent(
      decision: .stop, payloadDigest: digest, hop: hop, reason: relayDecisionReason
    )))
  }

  /// The relayed container this device is currently serving, if any.
  internal func relayContainerForServing() -> Data? { relayServedContainer }

  /// The value B005 answers a read at offset zero with.
  ///
  /// Precedence: this device's own event-info value wins over a relayed one.
  /// Spec 134 is silent on the collision, and this is the conservative
  /// reading -- a device that is itself an organizer-designated direct source
  /// must keep serving hop zero rather than demote itself to a forwarder, and
  /// the spec's one-payload-at-a-time rule forbids serving both.
  ///
  /// The own value itself has two forms, and the signed one wins: a
  /// host-supplied hop-zero v2 container, else the v1 `BarnardEventInfoCodec`
  /// payload, else the relayed container, else the read is refused.
  ///
  /// `advanceParticipantRelay` enforces the same precedence before this
  /// chooses, so a device with an own value has no lease left to fall back to.
  internal func eventInfoValueForRead() -> Data? {
    advanceParticipantRelay()
    return ownEventInfoValue() ?? relayServedContainer
  }

  public func getCurrentEventCode() -> String? {
    rpid.eventCode
  }

  public func getMyDisplayId() -> String {
    BarnardCrypto.displayIdString(from: rpid.getCurrentTek())
  }

  public func getCurrentRpi() -> String {
    let rpik = BarnardCrypto.deriveRpik(from: rpid.getCurrentTek())
    let rpi = BarnardCrypto.generateRpi(rpik: rpik, enin: currentEnin())
    return rpi.hexString
  }

  public func getCurrentEnin() -> Int {
    Int(currentEnin())
  }

  /// Explicit privacy egress. The SDK never transmits TEK over BLE; callers
  /// decide whether/how to transmit it via another channel. Deprecated
  /// (barnard#63): exposing the raw TEK lets anyone derive every RPID and
  /// the displayId for it. Prefer `BarnardIdentity.proveRpidOwnership`. Kept
  /// for parity with the Flutter plugin's `exportCurrentTek`.
  public func exportCurrentTek() -> String {
    rpid.getCurrentTek().hexString
  }

  public func getPermissionStatus() -> BarnardPermissionStatus {
    permissionStatusPayload()
  }

  public func requestPermissions(completion: @escaping (BarnardPermissionStatus) -> Void) {
    if bluetoothPermissionStatus() != "notDetermined" {
      completion(permissionStatusPayload())
      return
    }

    pendingPermissionCompletions.append(completion)
    ensureBleManagers()
    resolvePendingPermissionCompletionsIfPossible()
  }

  private func resolvePendingPermissionCompletionsIfPossible() {
    guard !pendingPermissionCompletions.isEmpty else { return }
    guard bluetoothPermissionStatus() != "notDetermined" else { return }

    let payload = permissionStatusPayload()
    let completions = pendingPermissionCompletions
    pendingPermissionCompletions.removeAll()
    for completion in completions {
      completion(payload)
    }
  }

  /// Opens the host app's system settings page.
  ///
  /// iOS only. On macOS this is a deliberate no-op: there is no per-app
  /// settings URL, and opening System Settings from a library call would be a
  /// surprising side effect for a headless or test process. macOS hosts should
  /// direct the user to System Settings > Privacy & Security > Bluetooth
  /// themselves.
  public func openAppSettings() {
    #if canImport(UIKit)
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    DispatchQueue.main.async {
      UIApplication.shared.open(url)
    }
    #endif
  }

  public func startScan(allowDuplicates: Bool = true) {
    if !isScanning {
      eventInfoRetryBudget.clearAll()
      eventInfoDiscoverySession = BarnardEventInfoDiscoverySession(startedAt: Date().timeIntervalSince1970)
    }
    self.allowDuplicates = allowDuplicates
    startScanInternal()
  }

  public func stopScan() {
    stopScanInternal()
  }

  public func startAdvertise(formatVersion: Int = 1) {
    self.formatVersion = acceptFormatVersion(formatVersion)
    startAdvertiseInternal()
  }

  public func stopAdvertise() {
    stopAdvertiseInternal()
  }

  @discardableResult
  public func startAuto(
    scanAllowDuplicates: Bool = true,
    advertiseFormatVersion: Int = 1
  ) -> (scanningStarted: Bool, advertisingStarted: Bool) {
    allowDuplicates = scanAllowDuplicates
    formatVersion = acceptFormatVersion(advertiseFormatVersion)

    let wasScanning = isScanning
    let wasAdvertising = isAdvertising
    startScanInternal()
    startAdvertiseInternal()
    return (
      scanningStarted: !wasScanning && isScanning,
      advertisingStarted: !wasAdvertising && isAdvertising
    )
  }

  public func stopAuto() {
    stopScanInternal()
    stopAdvertiseInternal()
  }

  public func dispose() {
    stopScanInternal()
    stopAdvertiseInternal()
    eventInfoSnapshots.removeAll()
  }

  public func joinEvent(_ eventCode: String) {
    resetPeerDiscoveryState(reason: "join_event")
    rpid.joinEvent(eventCode)
    rebuildGattServiceIfNeeded()
    emitState(reasonCode: "join_event")
    emitDebug(level: "info", name: "join_event", data: [
      "eventCode": eventCode,
      "myDisplayId": rpid.getCurrentDisplayId(),
    ])
  }

  public func leaveEvent() {
    resetPeerDiscoveryState(reason: "leave_event")
    // A supplied v2 container commits to one event. Leaving is the single call
    // that unambiguously says this device is no longer part of it, so the
    // container goes with it rather than staying on the air under a signature
    // for an event the device has left. Joining and reconfiguring do not clear
    // it: neither says the previous event ended, and a host that provisions a
    // container before joining would lose it.
    ownEnvelopeV2Container = nil
    rpid.leaveEvent()
    rebuildGattServiceIfNeeded()
    emitState(reasonCode: "leave_event")
    emitDebug(level: "info", name: "leave_event", data: nil)
  }

  // MARK: - Lifecycle

  // On background, iOS demotes our advertised service UUID from the AdvData
  // section to the overflow area (Apple-only scanners can still see it, but
  // generic centrals cannot). When the app returns to foreground, iOS does
  // not automatically repromote the UUID, so peers that started their scan
  // while we were backgrounded will never discover us. Bounce advertising on
  // foreground resume to repopulate the AdvData section. See issue #45.
  #if canImport(UIKit)
  @objc private func appDidBecomeActive() {
    guard isAdvertising else {
      emitDebug(level: "trace", name: "foreground_resume", data: ["isAdvertising": false])
      return
    }
    peripheralManager?.stopAdvertising()
    isAdvertising = false
    eventInfoSnapshots.removeAll()
    startAdvertiseInternal()
    emitDebug(level: "info", name: "advertise_restart_on_foreground", data: nil)
  }

  @objc private func appWillResignActive() {
    emitDebug(level: "info", name: "advertise_backgrounded", data: [
      "isAdvertising": isAdvertising,
    ])
  }
  #endif

  // MARK: - Scan Control

  private func startScanInternal() {
    let manager = ensureCentralManager()
    if isScanning {
      shouldStartScanWhenReady = false
      return
    }
    guard manager.state == .poweredOn else {
      if manager.state == .unknown || manager.state == .resetting {
        shouldStartScanWhenReady = true
        emitDebug(level: "info", name: "scan_waiting_for_powered_on", data: [
          "state": manager.state.rawValue,
        ])
      } else {
        shouldStartScanWhenReady = false
        emitConstraint(code: "bluetooth_not_ready", message: "CentralManager state=\(manager.state.rawValue)")
      }
      return
    }
    shouldStartScanWhenReady = false
    let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
    manager.scanForPeripherals(withServices: [discoveryServiceUUID], options: options)
    isScanning = true
    emitState(reasonCode: "scan_start")
    emitDebug(level: "info", name: "scan_start", data: ["allowDuplicates": allowDuplicates])
  }

  private func stopScanInternal() {
    shouldStartScanWhenReady = false
    // Spec 134: stopping Scan clears the relay lease, the density handles, and
    // the cached envelope, whether or not Scan was actually running.
    tearDownParticipantRelay(reason: "host_stop")
    if !isScanning { return }
    centralManager?.stopScan()
    isScanning = false
    resetPeerDiscoveryState(reason: "scan_stop")

    emitState(reasonCode: "scan_stop")
    emitDebug(level: "info", name: "scan_stop", data: nil)
  }

  private func resetPeerDiscoveryState(reason: String) {
    connectQueue.removeAll()
    if let active = activePeripheral {
      centralManager?.cancelPeripheralConnection(active)
    }
    activePeripheral = nil
    cancelConnectWatchdog()
    cancelConnectCooldownWorkItem()

    discoveredRssi.removeAll()
    discoveredAt.removeAll()
    peripheralsById.removeAll()
    lastConnectAttemptAt.removeAll()
    resolutionBackoffUntil.removeAll()
    pendingBoundaryRetryPeripherals.removeAll()
    peripheralCharacteristics.removeAll()
    peripheralReadValues.removeAll()
    b004ReadRetries.removeAll()
    eventInfoRetryBudget.clearAll()
    eventInfoDiscoverySession = BarnardEventInfoDiscoverySession(startedAt: Date().timeIntervalSince1970)
    lastDiscoveryNameById.removeAll()
    knownPeers.removeAll()

    emitDebug(level: "info", name: "peer_cache_reset", data: ["reason": reason])
  }

  // MARK: - Advertise Control

  private func startAdvertiseInternal() {
    let manager = ensurePeripheralManager()
    if isAdvertising {
      shouldStartAdvertiseWhenReady = false
      return
    }
    guard manager.state == .poweredOn else {
      if manager.state == .unknown || manager.state == .resetting {
        shouldStartAdvertiseWhenReady = true
        emitDebug(level: "info", name: "advertise_waiting_for_powered_on", data: [
          "state": manager.state.rawValue,
        ])
      } else {
        shouldStartAdvertiseWhenReady = false
        emitConstraint(code: "bluetooth_not_ready", message: "PeripheralManager state=\(manager.state.rawValue)")
      }
      return
    }
    shouldStartAdvertiseWhenReady = false
    ensureGattService()
    var ad: [String: Any] = [
      CBAdvertisementDataServiceUUIDsKey: [discoveryServiceUUID],
    ]
    #if DEBUG
    ad[CBAdvertisementDataLocalNameKey] = debugLocalName
    #endif
    manager.startAdvertising(ad)
    isAdvertising = true
    emitState(reasonCode: "advertise_start")
    emitDebug(
      level: "info",
      name: "advertise_start",
      data: [
        "formatVersion": Int(formatVersion),
        "serviceUuid": discoveryServiceUUID.uuidString,
        "localName": debugLocalName,
      ]
    )
  }

  private func stopAdvertiseInternal() {
    shouldStartAdvertiseWhenReady = false
    // Spec 134: without Advertise there is no way to serve a relayed value.
    tearDownParticipantRelay(reason: "host_stop")
    if !isAdvertising { return }
    peripheralManager?.stopAdvertising()
    isAdvertising = false
    emitState(reasonCode: "advertise_stop")
    emitDebug(level: "info", name: "advertise_stop", data: nil)
  }

  // MARK: - GATT Service Management

  private func ensureGattService() {
    _ = ensurePeripheralManager()
    if rpidCharacteristic != nil { return }
    buildAndAddGattService()
  }

  private func rebuildGattServiceIfNeeded() {
    guard let manager = peripheralManager, manager.state == .poweredOn else { return }

    manager.removeAllServices()
    rpidCharacteristic = nil
    displayIdCharacteristic = nil
    eventCodeHashCharacteristic = nil
    eventInfoCharacteristic = nil

    buildAndAddGattService()

    emitDebug(level: "info", name: "gatt_service_rebuilt", data: nil)
  }

  private func buildAndAddGattService() {
    guard let manager = peripheralManager else { return }

    // B002 RPID (Read only)
    let rpidCh = CBMutableCharacteristic(
      type: rpidCharacteristicUUID,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )

    // B003 displayId (Read only, 4 bytes) — v2: was TEK, now event-scoped SHA256(TEK)[0:4]
    let displayIdCh = CBMutableCharacteristic(
      type: displayIdCharacteristicUUID,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )

    // B004 EventCodeHash (Read only)
    let eventCodeHashCh = CBMutableCharacteristic(
      type: eventCodeHashCharacteristicUUID,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )
    let eventInfoCh = CBMutableCharacteristic(
      type: eventInfoCharacteristicUUID,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )

    let svc = CBMutableService(type: discoveryServiceUUID, primary: true)
    svc.characteristics = [rpidCh, displayIdCh, eventCodeHashCh, eventInfoCh]
    manager.add(svc)

    rpidCharacteristic = rpidCh
    displayIdCharacteristic = displayIdCh
    eventCodeHashCharacteristic = eventCodeHashCh
    eventInfoCharacteristic = eventInfoCh

    emitDebug(level: "info", name: "gatt_service_added", data: [
      "characteristics": ["RPID", "displayId", "EventCodeHash", "eventInfo"],
    ])
  }

  // MARK: - Connection Queue

  private func enqueueConnect(_ peripheral: CBPeripheral) {
    let id = peripheral.identifier
    peripheralsById[id] = peripheral

    let now = Date()
    if isResolutionBackedOff(id, now: now) {
      emitResolutionBackoff(id, now: now)
      return
    }

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
    if let last = lastConnectAttemptAt[nextId] {
      let remaining = cooldownPerPeerSeconds - now.timeIntervalSince(last)
      if remaining > 0 {
        connectQueue.removeFirst()
        connectQueue.append(nextId)
        scheduleConnectQueuePump(after: remaining)
        return
      }
    }

    guard let p = peripheralsById[nextId] else {
      connectQueue.removeFirst()
      return
    }
    guard let manager = centralManager else { return }

    connectQueue.removeFirst()
    activePeripheral = p
    lastConnectAttemptAt[nextId] = now

    peripheralReadValues[nextId] = PeripheralGattValues()
    b004ReadRetries[nextId] = 0

    p.delegate = self
    manager.connect(p, options: nil)
    emitDebug(level: "trace", name: "connect_attempt", data: ["id": nextId.uuidString])
    armConnectWatchdog(for: nextId)
  }

  private func armConnectWatchdog(for id: UUID) {
    connectWatchdog?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      guard let pinned = self.activePeripheral, pinned.identifier == id else {
        return
      }
      self.emitDebug(level: "warn", name: "gatt_exchange_timeout", data: [
        "id": id.uuidString,
        "seconds": self.connectTimeoutSeconds,
      ])
      self.markGattResolutionFailed(
        id,
        reason: "gatt_exchange_timeout",
        recoverable: true,
        extra: ["seconds": self.connectTimeoutSeconds]
      )
      self.centralManager?.cancelPeripheralConnection(pinned)
      self.peripheralCharacteristics.removeValue(forKey: id)
      self.peripheralReadValues.removeValue(forKey: id)
      self.lastDiscoveryNameById.removeValue(forKey: id)
      self.activePeripheral = nil
      self.pumpConnectQueue()
    }
    connectWatchdog = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + connectTimeoutSeconds,
      execute: work
    )
  }

  private func cancelConnectWatchdog() {
    connectWatchdog?.cancel()
    connectWatchdog = nil
  }

  private func scheduleConnectQueuePump(after delay: TimeInterval) {
    guard connectCooldownWorkItem == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.connectCooldownWorkItem = nil
      self.pumpConnectQueue()
    }
    connectCooldownWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func cancelConnectCooldownWorkItem() {
    connectCooldownWorkItem?.cancel()
    connectCooldownWorkItem = nil
  }

  private func isResolutionBackedOff(_ id: UUID, now: Date) -> Bool {
    guard let until = resolutionBackoffUntil[id] else { return false }
    if now < until { return true }
    resolutionBackoffUntil.removeValue(forKey: id)
    return false
  }

  private func emitResolutionBackoff(_ id: UUID, now: Date) {
    guard let until = resolutionBackoffUntil[id] else { return }
    emitDebug(level: "trace", name: "gatt_resolution_backoff", data: [
      "id": id.uuidString,
      "remainingMs": max(0, Int(until.timeIntervalSince(now) * 1000)),
    ])
  }

  private func markGattResolutionFailed(
    _ id: UUID,
    reason: String,
    recoverable: Bool,
    extra: [String: Any] = [:]
  ) {
    let backoffSeconds = recoverable ? resolutionFailureBackoffSeconds : resolutionRejectedBackoffSeconds
    resolutionBackoffUntil[id] = Date().addingTimeInterval(backoffSeconds)
    var data: [String: Any] = [
      "id": id.uuidString,
      "reason": reason,
      "recoverable": recoverable,
      "backoffMs": Int(backoffSeconds * 1000),
    ]
    for (key, value) in extra {
      data[key] = value
    }
    emitDebug(
      level: recoverable ? "warn" : "info",
      name: "gatt_resolution_failed",
      data: data
    )
  }

  // MARK: - GATT Exchange (Central side, v2 flow: B004 → B002 → B003)

  private func startGattExchange(for peripheral: CBPeripheral, service: CBService) {
    let id = peripheral.identifier
    var charMap: [CBUUID: CBCharacteristic] = [:]

    guard let characteristics = service.characteristics else {
      markGattResolutionFailed(id, reason: "characteristics_missing", recoverable: true)
      finishConnection(peripheral)
      return
    }

    for ch in characteristics {
      charMap[ch.uuid] = ch
    }
    peripheralCharacteristics[id] = charMap

    readEventCodeHash(for: peripheral)
  }

  private func readEventCodeHash(for peripheral: CBPeripheral) {
    let id = peripheral.identifier
    guard let eventCodeHashCh = peripheralCharacteristics[id]?[eventCodeHashCharacteristicUUID] else {
      markGattResolutionFailed(id, reason: "b004_missing", recoverable: true)
      emitDebug(level: "warn", name: "gatt_b004_missing", data: [
        "id": id.uuidString,
      ])
      finishConnection(peripheral)
      return
    }
    peripheral.readValue(for: eventCodeHashCh)
  }

  private func eventCodeHashMatches(_ peerHash: Data) -> Bool {
    peerHash == rpid.getEventCodeHash()
  }

  private func readRpidCharacteristic(for peripheral: CBPeripheral) {
    let id = peripheral.identifier
    guard let charMap = peripheralCharacteristics[id],
      let rpidCh = charMap[rpidCharacteristicUUID]
    else {
      markGattResolutionFailed(id, reason: "b002_missing", recoverable: true)
      readEventInfoAfterResolution(for: peripheral)
      return
    }
    peripheralReadValues[id]?.rpidReadStartedAt = Date()
    peripheral.readValue(for: rpidCh)
  }

  private func readDisplayIdCharacteristic(for peripheral: CBPeripheral) {
    let id = peripheral.identifier
    guard let charMap = peripheralCharacteristics[id],
      let displayIdCh = charMap[displayIdCharacteristicUUID]
    else {
      // Missing B003 — per v2 policy, still emit detection with null displayId.
      emitDebug(level: "warn", name: "gatt_b003_missing", data: [
        "id": id.uuidString,
      ])
      completeGattExchange(for: peripheral)
      return
    }
    peripheral.readValue(for: displayIdCh)
  }

  private func completeGattExchange(for peripheral: CBPeripheral) {
    let id = peripheral.identifier
    guard let values = peripheralReadValues[id] else {
      finishConnection(peripheral)
      return
    }

    if let rpidData = values.rpid {
      let rssi = discoveredRssi[id] ?? 0
      let completedAt = values.rpidReadCompletedAt ?? Date()
      guard let peerEnin = BarnardCrypto.stableReadEnin(
        startedAt: values.rpidReadStartedAt ?? completedAt,
        completedAt: completedAt,
        mode: eninMode,
        eninSeconds: eninSeconds,
        beaconChain: beaconChain
      ) else {
        emitDebug(level: "warn", name: "gatt_rpid_read_crossed_enin_boundary", data: [
          "id": id.uuidString,
          "startedAt": (values.rpidReadStartedAt ?? completedAt).timeIntervalSince1970,
          "completedAt": completedAt.timeIntervalSince1970,
        ])
        retryAfterRpidBoundaryCrossing(peripheral)
        return
      }
      let detectedDisplayId = values.detectedDisplayId?.hexString
      emitDetection(
        timestamp: completedAt,
        rssi: rssi,
        payload: rpidData,
        detectedDisplayId: detectedDisplayId,
        debugLocalName: lastDiscoveryNameById[id]
      )

      if rpidData.count == 17 {
        knownPeers[id] = KnownPeer(
          rpid: rpidData,
          enin: peerEnin,
          detectedDisplayId: detectedDisplayId,
          debugLocalName: lastDiscoveryNameById[id]
        )
        resolutionBackoffUntil.removeValue(forKey: id)
      }
    }

    readEventInfoAfterResolution(for: peripheral)
  }

  private func readEventInfoAfterResolution(for peripheral: CBPeripheral) {
    let id = peripheral.identifier
    guard let eventInfo = peripheralCharacteristics[id]?[eventInfoCharacteristicUUID] else {
      eventInfoRetryBudget.recordSemanticUnavailable(id)
      emitDebug(level: "info", name: "gatt_event_info_unavailable", data: ["id": id.uuidString, "reason": "missing"])
      finishConnection(peripheral)
      return
    }
    guard eventInfoRetryBudget.canStart(id, now: Date().timeIntervalSince1970) else {
      finishConnection(peripheral)
      return
    }
    peripheral.readValue(for: eventInfo)
  }

  private func retryEventInfoRead(for peripheral: CBPeripheral, error: Error) {
    let id = peripheral.identifier
    let now = Date().timeIntervalSince1970
    let deadline = eventInfoRetryBudget.recordRecoverableFailure(id, now: now)
    emitDebug(level: "info", name: "gatt_event_info_unavailable", data: ["id": id.uuidString, "error": error.localizedDescription])
    finishConnection(peripheral)
    guard let deadline else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now)) { [weak self, weak peripheral] in
      guard let self, let peripheral, self.isScanning else { return }
      self.lastConnectAttemptAt.removeValue(forKey: id)
      self.enqueueConnect(peripheral)
    }
  }

  private func finishConnection(_ peripheral: CBPeripheral) {
    let id = peripheral.identifier
    peripheralCharacteristics.removeValue(forKey: id)
    peripheralReadValues.removeValue(forKey: id)
    b004ReadRetries.removeValue(forKey: id)
    lastDiscoveryNameById.removeValue(forKey: id)
    centralManager?.cancelPeripheralConnection(peripheral)
  }

  private func retryAfterRpidBoundaryCrossing(_ peripheral: CBPeripheral) {
    let id = peripheral.identifier
    lastConnectAttemptAt.removeValue(forKey: id)
    pendingBoundaryRetryPeripherals[id] = peripheral
    finishConnection(peripheral)
  }

  private func schedulePendingBoundaryRetry(for id: UUID) {
    guard let peripheral = pendingBoundaryRetryPeripherals.removeValue(forKey: id) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + rpidBoundaryRetryDelaySeconds) { [weak self, weak peripheral] in
      guard let self = self, let peripheral = peripheral else { return }
      if self.isScanning {
        self.enqueueConnect(peripheral)
      }
    }
  }

  // MARK: - Event Emission

  private func emitState(reasonCode: String?) {
    onEvent?(.state(BarnardState(
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      eventCode: rpid.eventCode,
      eninMode: eninModeName(),
      eninSeconds: eninSeconds,
      beaconChain: beaconChainInfo(),
      reasonCode: reasonCode
    )))
  }

  private func emitConstraint(code: String, message: String?) {
    onEvent?(.constraint(BarnardConstraintEvent(code: code, message: message)))
  }

  private func emitError(code: String, message: String, recoverable: Bool? = nil) {
    onEvent?(.error(BarnardErrorEvent(code: code, message: message, recoverable: recoverable)))
  }

  private func emitEventInfoHint(peripheralId: UUID, eventInfo: BarnardEventInfo) {
    let observation = eventInfoDiscoverySession.observe(eventInfo, now: Date().timeIntervalSince1970)
    onEvent?(.eventInfoHint(BarnardEventInfoHintEvent(
      peripheralId: peripheralId,
      eventInfo: eventInfoForDiscoveryHint(
        eventInfo,
        shouldEmitGenericHint: observation.shouldEmitGenericHint
      ),
      additionalNamesOmitted: observation.additionalNamesOmitted,
      additionalEventsOmitted: observation.additionalEventsOmitted
    )))
  }

  /// The B005 event-info read path with the CoreBluetooth plumbing removed:
  /// everything the `didUpdateValueFor` delegate does with the characteristic
  /// value, minus tearing the connection down. `CBPeripheral` cannot be
  /// constructed in a unit test, so this is the seam the tests drive.
  ///
  /// A container whose first byte is `BarnardB005EnvelopeV2.formatVersion`
  /// (0x03) is a spec 122 v2 signed envelope and is verified in the SDK: hosts
  /// have no GATT access of their own, so leaving the verify call to them
  /// would make the verifier unreachable from the radio path. Everything else
  /// stays on the unchanged v1 hint path.
  internal func processEventInfoValue(
    peripheralId id: UUID,
    value: Data,
    b004EventCodeHash: Data,
    currentEnin: Int64
  ) {
    if value.first == BarnardB005EnvelopeV2.formatVersion {
      processEventInfoEnvelopeV2(peripheralId: id, container: value, currentEnin: currentEnin)
      return
    }

    do {
      let hint = try BarnardEventInfoCodec.parse(value)
      guard BarnardEventInfoCodec.matchesB004(hint, b004EventCodeHash: b004EventCodeHash) else {
        eventInfoRetryBudget.recordSemanticUnavailable(id)
        emitDebug(level: "info", name: "gatt_event_info_unavailable", data: ["id": id.uuidString, "reason": "b004_mismatch"])
        return
      }
      var data: [String: Any] = [
        "id": id.uuidString,
        "eventCodeHash": hint.eventCodeHash.hexString,
      ]
      #if DEBUG
      data["displayName"] = hint.eventDisplayName
      #endif
      emitDebug(level: "info", name: "gatt_event_info_hint", data: data)
      eventInfoRetryBudget.recordSuccessfulAttempt(id, now: Date().timeIntervalSince1970)
      emitEventInfoHint(peripheralId: id, eventInfo: hint)
    } catch {
      eventInfoRetryBudget.recordSemanticUnavailable(id)
      emitDebug(level: "info", name: "gatt_event_info_unavailable", data: ["id": id.uuidString])
    }
  }

  private func processEventInfoEnvelopeV2(peripheralId id: UUID, container: Data, currentEnin: Int64) {
    let verified = BarnardB005EnvelopeV2.verify(
      container: [UInt8](container),
      currentEnin: currentEnin,
      nameValidator: BarnardB005NativeDisplayNameNormalizer()
    )
    let receipt: BarnardB005EnvelopeV2Receipt = verified.map { .radioSelfVerified($0) } ?? .unverified

    // A container came back, so the GATT exchange succeeded, and this consumes
    // one of the peer's two session attempts exactly as a valid v1 hint does.
    // Verification failure is not radio unavailability: marking the peer
    // semantically unavailable would bar every further read of it for the rest
    // of the discovery session, including one whose envelope becomes valid in a
    // later ENIN.
    eventInfoRetryBudget.recordSuccessfulAttempt(id, now: Date().timeIntervalSince1970)
    emitDebug(level: "info", name: "gatt_event_info_envelope_v2", data: [
      "id": id.uuidString,
      "bytes": container.count,
      "receiverState": String(describing: receipt.receiverState),
    ])
    onEvent?(.eventInfoEnvelopeV2(BarnardEventInfoEnvelopeV2Event(
      peripheralId: id,
      receipt: receipt,
      rawContainer: container
    )))

    // Spec 134: only a receipt that this device verified from the radio is
    // offered to the relay. The relay's own host-supplied verifier then
    // applies step 3 (registry agreement) before any re-broadcast.
    guard case .radioSelfVerified = receipt else { return }
    // A device serving its own event-info value cannot put a relayed container
    // on the wire, so it does not observe, elect, or hold density state for one.
    guard !isServingOwnEventInfo() else {
      tearDownParticipantRelay(reason: "own_value_precedence")
      return
    }
    guard let relay = ensureParticipantRelay() else { return }
    // Observe only. Spec 134 takes lease decisions "at each 30-second decision
    // boundary", not on arrival, and `observe` already does the dedup, hop
    // retention and selection that an observation is responsible for.
    // Deciding here instead would fix each epoch's decision to the density
    // observed at that epoch's *first* arrival, so a burst of neighbours
    // arriving moments later could not suppress it. Decisions run in
    // `advanceParticipantRelay`, which the host calls at its scheduled wake-up
    // and which the B005 read path calls before answering.
    _ = relay.observe(container: [UInt8](container), peerHandle: relayPeerHandle(id))
  }

  /// Observer-local peer handle. Spec 134: never transmitted, never persisted
  /// beyond the density window, never interpreted as a person or a device.
  /// CoreBluetooth's peripheral identifier is already rotated per install.
  private func relayPeerHandle(_ id: UUID) -> [UInt8] {
    withUnsafeBytes(of: id.uuid) { Array($0) }
  }

  /// Emit v2 detection event. Byte fields are lowercase hex.
  private func emitDetection(
    timestamp: Date,
    rssi: Int,
    payload: Data,
    detectedDisplayId: String?,
    debugLocalName: String? = nil
  ) {
    guard payload.count == 17 else {
      emitDebug(level: "warn", name: "payload_invalid_length", data: ["length": payload.count])
      return
    }
    let version = Int(payload[0])
    if version != 1 {
      emitDebug(level: "warn", name: "payload_unsupported_version", data: ["formatVersion": version])
      return
    }

    // Atomic snapshot: use the observation timestamp for both reporterRpid
    // and enin, so they always agree across ENIN boundaries.
    let reporterPayload = currentPayload(now: timestamp)
    let enin = Int(currentEnin(timestamp))

    var resolvedDebugLocalName: String?
    #if DEBUG
    resolvedDebugLocalName = debugLocalName
    #endif

    onEvent?(.detection(BarnardDetectionEvent(
      timestamp: timestamp,
      rssi: rssi,
      formatVersion: version,
      rpid: payload.hexString,
      reporterRpid: reporterPayload.hexString,
      detectedDisplayId: detectedDisplayId,
      enin: enin,
      debugLocalName: resolvedDebugLocalName
    )))
  }

  private func emitRssiUpdate(peripheralId: UUID, rssi: Int, timestamp: Date) {
    guard isUsableRssi(rssi) else { return }
    guard let peer = knownPeers[peripheralId] else { return }

    // Atomic reporter snapshot (same contract as DetectionEvent).
    let reporterPayload = currentPayload(now: timestamp)
    let enin = Int(currentEnin(timestamp))

    onEvent?(.rssiUpdate(BarnardRssiUpdateEvent(
      timestamp: timestamp,
      rssi: rssi,
      rpid: peer.rpid.hexString,
      reporterRpid: reporterPayload.hexString,
      enin: enin,
      detectedDisplayId: peer.detectedDisplayId,
      debugLocalName: peer.debugLocalName
    )))
  }

  private func emitDebug(level: String, name: String, data: [String: Any]?) {
    onDebugEvent?(BarnardDebugEvent(timestamp: Date(), level: level, name: name, data: data))
  }

  /// Accept a caller-provided formatVersion. v2 only ships format 1, so
  /// clamp to 1 and emit a debug warning when callers request an
  /// unsupported value — advertising format 2+ would otherwise make the
  /// device silently undiscoverable to all v2 peers.
  private func acceptFormatVersion(_ raw: Int?) -> UInt8 {
    guard let v = raw else { return 1 }
    if v == 1 { return 1 }
    emitDebug(
      level: "warn",
      name: "format_version_clamped",
      data: ["requested": v, "applied": 1]
    )
    return 1
  }

  private func characteristicName(_ uuid: CBUUID) -> String {
    switch uuid {
    case rpidCharacteristicUUID:
      return "B002_RPID"
    case displayIdCharacteristicUUID:
      return "B003_displayId"
    case eventCodeHashCharacteristicUUID:
      return "B004_eventCodeHash"
    case eventInfoCharacteristicUUID:
      return "B005_eventInfo"
    default:
      return uuid.uuidString
    }
  }

  private func respondRead(
    _ peripheral: CBPeripheralManager,
    request: CBATTRequest,
    value: Data,
    debugName: String,
    debugData: [String: Any] = [:]
  ) {
    guard request.offset <= value.count else {
      peripheral.respond(to: request, withResult: .invalidOffset)
      emitDebug(level: "warn", name: "\(debugName)_invalid_offset", data: [
        "offset": request.offset,
        "bytes": value.count,
      ])
      return
    }
    request.value = value.subdata(in: request.offset..<value.count)
    peripheral.respond(to: request, withResult: .success)
    var data = debugData
    data["bytes"] = value.count
    data["offset"] = request.offset
    emitDebug(level: "trace", name: debugName, data: data)
  }

  private func isUsableRssi(_ rssi: Int) -> Bool {
    // CoreBluetooth uses 127 when RSSI is unavailable. Do not surface it as a
    // real dBm value because downstream timelines and aggregations treat RSSI
    // numerically.
    rssi != unavailableRssi
  }
}

// MARK: - CBCentralManagerDelegate

extension BarnardEngine: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    resolvePendingPermissionCompletionsIfPossible()
    emitDebug(level: "info", name: "central_state", data: ["state": central.state.rawValue])
    if central.state == .poweredOn, shouldStartScanWhenReady {
      startScanInternal()
    } else if central.state != .poweredOn, isScanning {
      stopScanInternal()
    }
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let rssi = RSSI.intValue
    guard isUsableRssi(rssi) else {
      emitDebug(level: "trace", name: "ble_discovery_rssi_unavailable", data: [
        "id": peripheral.identifier.uuidString,
        "rssi": rssi,
        "name": (advertisementData[CBAdvertisementDataLocalNameKey] as? String) as Any,
      ])
      return
    }
    let now = Date()
    discoveredRssi[peripheral.identifier] = rssi
    discoveredAt[peripheral.identifier] = now

    emitDebug(level: "trace", name: "ble_discovery_result", data: [
      "id": peripheral.identifier.uuidString,
      "rssi": rssi,
      "name": (advertisementData[CBAdvertisementDataLocalNameKey] as? String) as Any,
    ])

    #if DEBUG
    if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty {
      lastDiscoveryNameById[peripheral.identifier] = name
    }
    #endif

    if let knownPeer = knownPeers[peripheral.identifier] {
      let currentEninValue = currentEnin(now)
      if BarnardV2Policy.shouldEmitRssiUpdate(cachedPeerEnin: knownPeer.enin, currentEnin: currentEninValue) {
        emitRssiUpdate(peripheralId: peripheral.identifier, rssi: rssi, timestamp: now)
      } else {
        knownPeers.removeValue(forKey: peripheral.identifier)
        emitDebug(level: "trace", name: "known_peer_rpid_expired", data: [
          "id": peripheral.identifier.uuidString,
          "cachedEnin": Int(knownPeer.enin),
          "currentEnin": Int(currentEninValue),
        ])
        // Force a fresh resolution. enqueueConnect dedups against in-flight /
        // queued connects, so following advertisements on the same identifier
        // remain safe.
        enqueueConnect(peripheral)
      }
    } else if isResolutionBackedOff(peripheral.identifier, now: now) {
      emitResolutionBackoff(peripheral.identifier, now: now)
    } else {
      enqueueConnect(peripheral)
    }
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard activePeripheral?.identifier == peripheral.identifier else {
      emitDebug(level: "trace", name: "stale_connect_ignored", data: [
        "id": peripheral.identifier.uuidString,
      ])
      return
    }
    emitDebug(level: "trace", name: "connected", data: ["id": peripheral.identifier.uuidString])
    peripheral.discoverServices([discoveryServiceUUID])
  }

  public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard activePeripheral?.identifier == peripheral.identifier else {
      emitDebug(level: "trace", name: "stale_connect_failed_ignored", data: [
        "id": peripheral.identifier.uuidString,
      ])
      return
    }
    cancelConnectWatchdog()
    emitError(code: "connect_failed", message: error?.localizedDescription ?? "unknown", recoverable: true)
    let id = peripheral.identifier
    markGattResolutionFailed(
      id,
      reason: "connect_failed",
      recoverable: true,
      extra: ["error": error?.localizedDescription ?? "unknown"]
    )
    peripheralCharacteristics.removeValue(forKey: id)
    peripheralReadValues.removeValue(forKey: id)
    activePeripheral = nil
    pumpConnectQueue()
  }

  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    guard activePeripheral?.identifier == peripheral.identifier else {
      emitDebug(level: "trace", name: "stale_disconnect_ignored", data: [
        "id": peripheral.identifier.uuidString,
      ])
      return
    }
    cancelConnectWatchdog()
    let id = peripheral.identifier
    peripheralCharacteristics.removeValue(forKey: id)
    peripheralReadValues.removeValue(forKey: id)
    activePeripheral = nil
    schedulePendingBoundaryRetry(for: id)
    pumpConnectQueue()
  }
}

// MARK: - CBPeripheralDelegate

extension BarnardEngine: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
      markGattResolutionFailed(
        peripheral.identifier,
        reason: "service_discovery_failed",
        recoverable: true,
        extra: ["error": error.localizedDescription]
      )
      emitError(code: "service_discovery_failed", message: error.localizedDescription, recoverable: true)
      finishConnection(peripheral)
      return
    }
    guard let services = peripheral.services, let svc = services.first(where: { $0.uuid == discoveryServiceUUID }) else {
      markGattResolutionFailed(peripheral.identifier, reason: "service_not_found", recoverable: true)
      emitError(code: "service_not_found", message: "Barnard service not found", recoverable: true)
      finishConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics(
      [rpidCharacteristicUUID, displayIdCharacteristicUUID, eventCodeHashCharacteristicUUID, eventInfoCharacteristicUUID],
      for: svc
    )
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let error = error {
      markGattResolutionFailed(
        peripheral.identifier,
        reason: "characteristic_discovery_failed",
        recoverable: true,
        extra: ["error": error.localizedDescription]
      )
      emitError(code: "characteristic_discovery_failed", message: error.localizedDescription, recoverable: true)
      finishConnection(peripheral)
      return
    }
    startGattExchange(for: peripheral, service: service)
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    let id = peripheral.identifier

    // Distinguish B003 read failure (still emit detection with null) from
    // B002 read failure (drop the detection — no RPID, nothing to emit).
    if let error = error {
      if characteristic.uuid == eventInfoCharacteristicUUID {
        if let attError = error as? CBATTError, attError.code == .readNotPermitted {
          eventInfoRetryBudget.recordSemanticUnavailable(id)
          emitDebug(level: "info", name: "gatt_event_info_unavailable", data: ["id": id.uuidString, "reason": "read_not_permitted"])
          finishConnection(peripheral)
        } else {
          retryEventInfoRead(for: peripheral, error: error)
        }
        return
      }
      if characteristic.uuid == displayIdCharacteristicUUID {
        emitDebug(level: "warn", name: "gatt_b003_read_failed", data: [
          "id": id.uuidString,
          "error": error.localizedDescription,
        ])
        peripheralReadValues[id]?.detectedDisplayId = nil
        completeGattExchange(for: peripheral)
        return
      }
      if characteristic.uuid == eventCodeHashCharacteristicUUID {
        let retries = b004ReadRetries[id] ?? 0
        if retries < maxB004ReadRetries {
          b004ReadRetries[id] = retries + 1
          emitDebug(level: "warn", name: "gatt_b004_read_retry", data: [
            "id": id.uuidString,
            "attempt": retries + 1,
            "max": maxB004ReadRetries,
            "error": error.localizedDescription,
          ])
          DispatchQueue.main.asyncAfter(deadline: .now() + b004ReadRetryDelaySeconds) { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral else { return }
            guard self.activePeripheral?.identifier == id else { return }
            peripheral.readValue(for: characteristic)
          }
          return
        }
      }
      let name = characteristicName(characteristic.uuid)
      markGattResolutionFailed(
        id,
        reason: "read_failed",
        recoverable: true,
        extra: [
          "characteristic": name,
          "error": error.localizedDescription,
        ]
      )
      emitDebug(level: "warn", name: "gatt_read_failed", data: [
        "id": id.uuidString,
        "characteristic": name,
        "error": error.localizedDescription,
      ])
      emitError(code: "read_failed", message: "\(name): \(error.localizedDescription)", recoverable: true)
      finishConnection(peripheral)
      return
    }

    let value = characteristic.value ?? Data()

    switch characteristic.uuid {
    case eventInfoCharacteristicUUID:
      processEventInfoValue(
        peripheralId: id,
        value: value,
        b004EventCodeHash: peripheralReadValues[id]?.eventCodeHash ?? Data(),
        currentEnin: Int64(currentEnin())
      )
      finishConnection(peripheral)
    case eventCodeHashCharacteristicUUID:
      peripheralReadValues[id]?.eventCodeHash = value
      let matches = eventCodeHashMatches(value)
      emitDebug(level: "trace", name: "gatt_read_event_code_hash", data: [
        "id": id.uuidString,
        "bytes": value.count,
        "isEmpty": value.isEmpty,
        "matches": matches,
      ])
      guard matches else {
        markGattResolutionFailed(
          id,
          reason: "b004_mismatch",
          recoverable: false,
          extra: ["bytes": value.count]
        )
        emitDebug(level: "info", name: "gatt_b004_mismatch", data: [
          "id": id.uuidString,
          "bytes": value.count,
        ])
        readEventInfoAfterResolution(for: peripheral)
        return
      }
      readRpidCharacteristic(for: peripheral)

    case rpidCharacteristicUUID:
      peripheralReadValues[id]?.rpid = value
      peripheralReadValues[id]?.rpidReadCompletedAt = Date()
      emitDebug(level: "trace", name: "gatt_read_rpid", data: [
        "id": id.uuidString,
        "bytes": value.count,
      ])
      readDisplayIdCharacteristic(for: peripheral)

    case displayIdCharacteristicUUID:
      if value.count == 4 {
        peripheralReadValues[id]?.detectedDisplayId = value
        emitDebug(level: "trace", name: "gatt_read_display_id", data: [
          "id": id.uuidString,
          "displayId": value.hexString,
        ])
      } else {
        emitDebug(level: "warn", name: "gatt_b003_invalid_length", data: [
          "id": id.uuidString,
          "length": value.count,
        ])
        peripheralReadValues[id]?.detectedDisplayId = nil
      }
      completeGattExchange(for: peripheral)

    default:
      break
    }
  }
}

// MARK: - CBPeripheralManagerDelegate

extension BarnardEngine: CBPeripheralManagerDelegate {
  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    resolvePendingPermissionCompletionsIfPossible()
    emitDebug(level: "info", name: "peripheral_state", data: ["state": peripheral.state.rawValue])
    if peripheral.state == .poweredOn, shouldStartAdvertiseWhenReady {
      startAdvertiseInternal()
    } else if peripheral.state != .poweredOn, isAdvertising {
      stopAdvertiseInternal()
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    if let error = error {
      emitError(code: "gatt_service_add_failed", message: error.localizedDescription, recoverable: false)
    }
  }

  public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error = error {
      emitError(code: "advertise_failed", message: error.localizedDescription, recoverable: true)
      isAdvertising = false
      emitState(reasonCode: "advertise_failed")
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    switch request.characteristic.uuid {
    case rpidCharacteristicUUID:
      let payload = currentPayload(now: Date())
      respondRead(
        peripheral,
        request: request,
        value: payload,
        debugName: "gatt_respond_rpid",
        debugData: ["formatVersion": Int(formatVersion)]
      )

    case displayIdCharacteristicUUID:
      guard shouldServeGattDisplayId() else {
        peripheral.respond(to: request, withResult: .readNotPermitted)
        emitDebug(level: "trace", name: "gatt_reject_display_id_read", data: [
          "reason": "not_joined_to_event",
        ])
        return
      }

      // v2: event-scoped B003 serves 4-byte SHA256(TEK)[0:4]. Read-only.
      let displayId = BarnardCrypto.displayId4(from: rpid.getCurrentTek())
      respondRead(
        peripheral,
        request: request,
        value: displayId,
        debugName: "gatt_respond_display_id"
      )

    case eventCodeHashCharacteristicUUID:
      let hash = rpid.getEventCodeHash()
      respondRead(
        peripheral,
        request: request,
        value: hash,
        debugName: "gatt_respond_event_code_hash",
        debugData: ["isEmpty": hash.isEmpty]
      )
    case eventInfoCharacteristicUUID:
      respondEventInfoRead(peripheral, request: request)

    default:
      peripheral.respond(to: request, withResult: .attributeNotFound)
    }
  }

  private func respondEventInfoRead(_ peripheral: CBPeripheralManager, request: CBATTRequest) {
    let id = request.central.identifier
    let now = Date()
    eventInfoSnapshots = eventInfoSnapshots.filter { now.timeIntervalSince($0.value.lastRequest) <= 30 }
    if request.offset == 0 {
      guard let value = eventInfoValueForRead() else {
        peripheral.respond(to: request, withResult: .readNotPermitted)
        return
      }
      eventInfoSnapshots[id] = EventInfoSnapshot(
        value: value,
        lastRequest: now
      )
    }
    guard var snapshot = eventInfoSnapshots[id] else {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    guard request.offset <= snapshot.value.count else {
      eventInfoSnapshots.removeValue(forKey: id)
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    request.value = snapshot.value.subdata(in: request.offset..<snapshot.value.count)
    peripheral.respond(to: request, withResult: .success)
    if request.offset == snapshot.value.count {
      eventInfoSnapshots.removeValue(forKey: id)
    } else {
      snapshot.lastRequest = now
      eventInfoSnapshots[id] = snapshot
    }
  }

  // v2 has no writable characteristics. Reject any write attempt.
  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for request in requests {
      peripheral.respond(to: request, withResult: .writeNotPermitted)
    }
    emitDebug(level: "warn", name: "gatt_write_rejected", data: [
      "count": requests.count,
    ])
  }
}
