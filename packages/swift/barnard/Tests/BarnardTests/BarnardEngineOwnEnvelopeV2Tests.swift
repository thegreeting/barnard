// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
import BarnardCore
@testable import Barnard

/// Serving a host-supplied hop-zero B005 v2 container as this device's own
/// event-info value (issue #189).
///
/// The engine neither signs nor re-encodes what the host hands it, so these
/// tests assert byte identity rather than any derived field, plus the
/// structural gate that keeps a malformed or already-relayed container out.
/// The round-trip case feeds the served bytes back through the #186 receive
/// seam, which is the only way to show a peer would reach
/// `RADIO_SELF_VERIFIED` without a radio.
final class BarnardEngineOwnEnvelopeV2Tests: XCTestCase {
  /// Inside the conformance vectors' `[validFromEnin, relayExpiresAtEnin)`.
  private let vectorEnin: Int64 = 6_000_000

  // MARK: - 1. A supplied container is served byte for byte at hop zero

  func testSuppliedContainerIsServedByteIdenticalAtHopZero() throws {
    let container = try vectorContainer()
    let engine = BarnardEngine()

    try engine.configureOwnEventInfoEnvelopeV2(container: container)

    XCTAssertEqual(engine.ownEventInfoEnvelopeV2, container)
    let served = try XCTUnwrap(engine.eventInfoValueForRead())
    XCTAssertEqual(served, container, "the container must reach the wire unchanged")
    XCTAssertEqual(served.first, BarnardB005EnvelopeV2.formatVersion)
    XCTAssertEqual(served[1], 0, "the device's own value is a hop-zero source")
  }

  // MARK: - 2. The structural gate

  func testNonZeroHopIsRejected() throws {
    var container = try vectorContainer()
    container[1] = 1
    let engine = BarnardEngine()

    XCTAssertThrowsError(try engine.configureOwnEventInfoEnvelopeV2(container: container)) {
      XCTAssertEqual($0 as? BarnardOwnEnvelopeV2Error, .nonZeroHopCount)
    }
    XCTAssertNil(engine.ownEventInfoEnvelopeV2)
    XCTAssertNil(engine.eventInfoValueForRead())
  }

  func testNonV2FormatVersionIsRejected() throws {
    var container = try vectorContainer()
    container[0] = 0x02
    let engine = BarnardEngine()

    XCTAssertThrowsError(try engine.configureOwnEventInfoEnvelopeV2(container: container)) {
      XCTAssertEqual($0 as? BarnardOwnEnvelopeV2Error, .malformedContainer(.formatVersion))
    }
    XCTAssertNil(engine.ownEventInfoEnvelopeV2)
  }

  func testUnsupportedEnvelopeVersionIsRejected() throws {
    var container = try vectorContainer()
    container[4] = 0x02  // envelope version, the first byte after the container header
    let engine = BarnardEngine()

    XCTAssertThrowsError(try engine.configureOwnEventInfoEnvelopeV2(container: container)) {
      XCTAssertEqual($0 as? BarnardOwnEnvelopeV2Error, .malformedContainer(.envelopeVersion))
    }
    XCTAssertNil(engine.ownEventInfoEnvelopeV2)
  }

  func testAnEnvelopeBelowTheMinimumSizeIsRejected() throws {
    // A container whose declared length agrees with its byte count, so only
    // the 199-byte envelope floor can reject it.
    let short = Data([3, 0, 0, 8]) + Data(repeating: 1, count: 8)
    let engine = BarnardEngine()

    XCTAssertThrowsError(try engine.configureOwnEventInfoEnvelopeV2(container: short)) {
      XCTAssertEqual($0 as? BarnardOwnEnvelopeV2Error, .malformedContainer(.envelopeTooSmall))
    }
    XCTAssertNil(engine.ownEventInfoEnvelopeV2)
  }

  func testTruncatedAndOverlongContainersAreRejected() throws {
    let engine = BarnardEngine()
    let container = try vectorContainer()

    XCTAssertThrowsError(try engine.configureOwnEventInfoEnvelopeV2(container: Data([3, 0, 0]))) {
      XCTAssertEqual($0 as? BarnardOwnEnvelopeV2Error, .malformedContainer(.containerLength))
    }
    XCTAssertThrowsError(
      try engine.configureOwnEventInfoEnvelopeV2(container: container + Data([0]))
    ) {
      XCTAssertEqual($0 as? BarnardOwnEnvelopeV2Error, .malformedContainer(.envelopeLength))
    }
  }

  func testTheGateRefusesEveryShapeTheVerifierRefuses() throws {
    // The point of sharing one structural entry point: whatever the gate
    // accepts, a receiver's verify would also accept structurally. Sweep the
    // mutations that break structure and assert both agree.
    let engine = BarnardEngine()
    let base = try vectorContainer()
    // Byte 0 format version, byte 2 the envelope length's high byte (the
    // vector's envelope is 256, so the low byte alone is a no-op), byte 4
    // envelope version.
    for (index, value) in [(0, UInt8(2)), (2, 0), (4, 2)] {
      var mutated = base
      mutated[index] = value
      XCTAssertThrowsError(try engine.configureOwnEventInfoEnvelopeV2(container: mutated),
                           "byte \(index) should not pass the gate")
      XCTAssertNil(
        BarnardB005EnvelopeV2.verify(
          container: [UInt8](mutated), currentEnin: vectorEnin,
          nameValidator: BarnardB005NativeDisplayNameNormalizer()
        ),
        "byte \(index) should not pass verify either"
      )
    }
  }

  func testARejectedContainerLeavesAPreviouslySuppliedOneInPlace() throws {
    let container = try vectorContainer()
    let engine = BarnardEngine()
    try engine.configureOwnEventInfoEnvelopeV2(container: container)

    var relayed = container
    relayed[1] = 1
    XCTAssertThrowsError(try engine.configureOwnEventInfoEnvelopeV2(container: relayed))

    XCTAssertEqual(engine.eventInfoValueForRead(), container)
  }

  // MARK: - 3. The v1 fallback is unchanged

  func testWithoutASuppliedContainerTheV1PayloadIsServed() throws {
    let engine = BarnardEngine()
    // The joined event code lives in UserDefaults.standard, shared by every
    // engine in this process, so it must be cleared again.
    defer { engine.leaveEvent() }
    engine.joinEvent("BARNARD-OWN-V2-TEST")
    try engine.configureEventInfoServing(
      organizerDesignated: true, eventActiveForDiscovery: true, eventDisplayName: "Own Event"
    )

    let v1 = try XCTUnwrap(engine.eventInfoValueForRead())
    XCTAssertEqual(v1.first, 0x01, "with no v2 container the v1 payload is served as before")

    // Supplying and then clearing a container restores exactly those bytes.
    try engine.configureOwnEventInfoEnvelopeV2(container: try vectorContainer())
    XCTAssertEqual(engine.eventInfoValueForRead()?.first, BarnardB005EnvelopeV2.formatVersion)
    try engine.configureOwnEventInfoEnvelopeV2(container: nil)
    XCTAssertNil(engine.ownEventInfoEnvelopeV2)
    XCTAssertEqual(engine.eventInfoValueForRead(), v1)
  }

  func testStoppingAdvertiseKeepsTheHostSuppliedContainer() throws {
    let container = try vectorContainer()
    let engine = BarnardEngine()
    try engine.configureOwnEventInfoEnvelopeV2(container: container)

    // Deliberate asymmetry with the relay lease, which stopAdvertise tears
    // down: the lease is engine-elected state that spec 134 requires be
    // rechecked on resume, while this container is host state the engine was
    // handed. Only the host clears it.
    engine.stopAdvertise()

    XCTAssertEqual(engine.ownEventInfoEnvelopeV2, container)
    XCTAssertEqual(engine.eventInfoValueForRead(), container)
  }

  func testLeavingTheEventClearsTheSuppliedContainer() throws {
    let container = try vectorContainer()
    let engine = BarnardEngine()
    defer { engine.leaveEvent() }
    engine.joinEvent("BARNARD-OWN-V2-TEST")
    try engine.configureOwnEventInfoEnvelopeV2(container: container)
    XCTAssertEqual(engine.eventInfoValueForRead(), container)

    engine.leaveEvent()

    // Leaving is the one call that says this device is no longer part of the
    // event the container is signed for, so the container goes with it rather
    // than staying on the air. See DESIGN-NOTES 0.2d.
    XCTAssertNil(engine.ownEventInfoEnvelopeV2)
    XCTAssertNil(engine.eventInfoValueForRead())
  }

  func testJoiningAndReconfiguringKeepTheSuppliedContainer() throws {
    let container = try vectorContainer()
    let engine = BarnardEngine()
    defer { engine.leaveEvent() }
    try engine.configureOwnEventInfoEnvelopeV2(container: container)

    // Provisioning a container before joining is a normal order of operations,
    // and reconfiguring says nothing about the event having ended, so neither
    // call discards it. Only leaving does.
    engine.joinEvent("BARNARD-OWN-V2-TEST")
    XCTAssertEqual(engine.ownEventInfoEnvelopeV2, container)
    try engine.configureEventInfoServing(
      organizerDesignated: true, eventActiveForDiscovery: true, eventDisplayName: "Own Event"
    )
    XCTAssertEqual(engine.eventInfoValueForRead(), container)
  }

  // MARK: - 4. Precedence over a relayed container

  func testSuppliedContainerBeatsARelayedOneAndEndsTheLease() throws {
    let engine = BarnardEngine()
    var events: [BarnardEvent] = []
    engine.onEvent = { events.append($0) }
    let clock = Clock(), enin = Enin()
    engine.configureParticipantRelay(
      verifier: RegistryVerifier(), randomnessSeedMaterial: [7, 8, 9], clock: clock, eninSource: enin
    )
    engine.processEventInfoValue(
      peripheralId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
      value: try vectorContainer(),
      b004EventCodeHash: Data(),
      currentEnin: vectorEnin
    )
    // Run the epoch decision, then let the <=15 s contention delay elapse.
    engine.advanceParticipantRelay()
    clock.now += 15_001
    engine.advanceParticipantRelay()
    if !engine.isRelayServing {
      clock.now = (clock.now / 30_000 + 1) * 30_000
      engine.advanceParticipantRelay()
      clock.now += 15_001
      engine.advanceParticipantRelay()
    }
    let relayed = try XCTUnwrap(engine.relayContainerForServing())
    XCTAssertEqual(relayed[1], 1, "the relayed copy sits one hop out")

    var own = try vectorContainer()
    // Flip a registrar byte: distinguishable from the relayed copy, and one of
    // the fields the structural gate does not constrain, so the tightened gate
    // still accepts it.
    own[5] ^= 0x01
    try engine.configureOwnEventInfoEnvelopeV2(container: own)

    XCTAssertEqual(engine.eventInfoValueForRead(), own)
    // A supplied container is an own value for the #187 election gate too, not
    // only for the read chooser: this device can no longer put a relayed
    // container on the wire, so the lease ends rather than lingering behind a
    // value that shadows it.
    XCTAssertFalse(engine.isRelayServing)
    XCTAssertNil(engine.relayContainerForServing())
    let stop = try XCTUnwrap(
      events.compactMap { if case .relayDecision(let d) = $0 { return d } else { return nil } }
        .last { $0.decision == .stop }
    )
    XCTAssertEqual(stop.reason, "own_value_precedence")
  }

  func testASuppliedContainerKeepsTheRelayFromElectingAtAll() throws {
    let engine = BarnardEngine()
    let clock = Clock(), enin = Enin()
    engine.configureParticipantRelay(
      verifier: RegistryVerifier(), randomnessSeedMaterial: [7, 8, 9], clock: clock, eninSource: enin
    )
    try engine.configureOwnEventInfoEnvelopeV2(container: try vectorContainer())

    engine.processEventInfoValue(
      peripheralId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
      value: try vectorContainer(),
      b004EventCodeHash: Data(),
      currentEnin: vectorEnin
    )
    engine.advanceParticipantRelay()
    clock.now += 15_001
    engine.advanceParticipantRelay()

    XCTAssertFalse(engine.isRelayServing, "an own value must not observe or elect")
    XCTAssertNil(engine.relayContainerForServing())
  }

  // MARK: - 5. A peer running the #186 receive path verifies what we serve

  func testServedContainerRoundTripsToRadioSelfVerifiedOnAPeer() throws {
    let source = BarnardEngine()
    try source.configureOwnEventInfoEnvelopeV2(container: try vectorContainer())
    let served = try XCTUnwrap(source.eventInfoValueForRead())

    let peer = BarnardEngine()
    var events: [BarnardEvent] = []
    peer.onEvent = { events.append($0) }
    peer.processEventInfoValue(
      peripheralId: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
      value: served,
      b004EventCodeHash: Data(),
      currentEnin: vectorEnin
    )

    var received: BarnardEventInfoEnvelopeV2Event?
    for event in events {
      if case .eventInfoEnvelopeV2(let payload) = event { received = payload }
    }
    let envelope = try XCTUnwrap(received, "the peer saw no v2 envelope")
    XCTAssertEqual(envelope.receiverState, .RADIO_SELF_VERIFIED)
    XCTAssertNotEqual(envelope.receiverState, .REGISTRY_VERIFIED, "the SDK never assigns it")
    XCTAssertEqual(envelope.rawContainer, served)
    XCTAssertEqual(try XCTUnwrap(envelope.verifiedEnvelope).relayHopCount, 0)
  }

  // MARK: - Relay dependencies

  private final class Clock: BarnardRelayMonotonicClock {
    var now: Int64 = 0
    func relayNowMilliseconds() -> Int64 { now }
  }

  private final class Enin: BarnardRelayEninSource {
    var value: UInt32? = 6_000_000
    func relayCurrentEnin() -> UInt32? { value }
  }

  private final class RegistryVerifier: BarnardRelayVerifier {
    func verifyRelayEnvelope(_ bytes: [UInt8], currentEnin: UInt32) -> BarnardRelayVerification {
      .registryVerified(
        eventId: [1], validFromEnin: 5_999_990, validThroughEnin: 6_000_010,
        relayExpiresAtEnin: 6_000_002
      )
    }
  }

  // MARK: - Vectors

  private func vectorContainer() throws -> Data {
    try XCTUnwrap(hexData(try vector("v1_container")))
  }

  private func hexData(_ hex: String) -> Data? {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return Data(bytes)
  }

  private func vector(_ key: String) throws -> String {
    try XCTUnwrap(Self.vectors[key], "missing vector \(key)")
  }

  private static let vectors: [String: String] = {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<20 {
      let candidate = directory.appendingPathComponent("test-vectors/b005-envelope-v2.txt")
      if let text = try? String(contentsOf: candidate, encoding: .utf8) {
        return Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
          let s = line.trimmingCharacters(in: .whitespaces)
          guard !s.isEmpty, !s.hasPrefix("#"), let i = s.firstIndex(of: "=") else { return nil }
          return (String(s[..<i]), String(s[s.index(after: i)...]))
        })
      }
      directory.deleteLastPathComponent()
    }
    return [:]
  }()
}
