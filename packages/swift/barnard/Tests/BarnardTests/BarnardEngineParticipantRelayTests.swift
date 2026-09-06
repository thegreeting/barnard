// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
import BarnardCore
@testable import Barnard

/// Engine-level relay driving for B005 v2 (issue #187, spec 134).
///
/// The pure `BarnardParticipantRelay` already has its own vector tests. These
/// drive the same shared vectors through the *engine* seam
/// (`BarnardEngine.processEventInfoValue`), which is what issue #187 asks for:
/// a receipt produced by the #186 receive path must reach the relay, and the
/// relay's chosen container must reach the B005 serving path.
///
/// `relay-hop-dedup.txt` carries a four-byte placeholder envelope
/// (`01020304`). That envelope cannot cross the engine seam: the engine runs
/// the real `BarnardB005EnvelopeV2.verify`, which rejects it, so it never
/// becomes a receipt. The engine tests therefore drive the *relationships*
/// that file encodes -- container layout, served hop = observed minimum + 1,
/// no output at hop two, the 32-handle cap and the 12-ENIN lifetime -- using
/// the signed conformance envelope from `b005-envelope-v2.txt`, and assert
/// separately that the placeholder containers in the file agree with the same
/// container encoder the relay uses.
final class BarnardEngineParticipantRelayTests: XCTestCase {
  /// Inside the conformance vectors' `[validFromEnin, relayExpiresAtEnin)`.
  private let vectorEnin: Int64 = 6_000_000

  // MARK: - Injectable relay dependencies

  private final class Clock: BarnardRelayMonotonicClock {
    var now: Int64 = 0
    func relayNowMilliseconds() -> Int64 { now }
  }

  private final class Enin: BarnardRelayEninSource {
    var value: UInt32? = 6_000_000
    func relayCurrentEnin() -> UInt32? { value }
  }

  /// Stands in for the host's registry check. Spec 134 step 3 requires the
  /// on-chain definition, which the SDK cannot reach, so the relay's verifier
  /// is host-supplied and only `.registryVerified` unlocks relaying.
  private final class RegistryVerifier: BarnardRelayVerifier {
    var invocations = 0
    var result = BarnardRelayVerification.registryVerified(
      eventId: [1], validFromEnin: 5_999_990, validThroughEnin: 6_000_010, relayExpiresAtEnin: 6_000_002
    )
    func verifyRelayEnvelope(_ bytes: [UInt8], currentEnin: UInt32) -> BarnardRelayVerification {
      invocations += 1
      return result
    }
  }

  private final class JoinedEvent: BarnardRelayJoinedEventProvider {
    var eventId: [UInt8]?
    func relayJoinedEventId() -> [UInt8]? { eventId }
  }

  // MARK: - Harness

  private struct Harness {
    let engine: BarnardEngine
    let clock: Clock
    let enin: Enin
    let verifier: RegistryVerifier
    let joined: JoinedEvent
    var events: () -> [BarnardEvent]
  }

  private func harness(configureRelay: Bool = true) -> Harness {
    let engine = BarnardEngine()
    let clock = Clock(), enin = Enin(), verifier = RegistryVerifier(), joined = JoinedEvent()
    let box = EventBox()
    engine.onEvent = { box.events.append($0) }
    if configureRelay {
      engine.configureParticipantRelay(
        verifier: verifier,
        joinedEventProvider: joined,
        randomnessSeedMaterial: [7, 8, 9],
        clock: clock,
        eninSource: enin
      )
    }
    return Harness(engine: engine, clock: clock, enin: enin, verifier: verifier, joined: joined,
                   events: { box.events })
  }

  private final class EventBox { var events: [BarnardEvent] = [] }

  private func feed(_ h: Harness, _ container: [UInt8], peer: UInt8) {
    h.engine.processEventInfoValue(
      peripheralId: peerId(peer),
      value: Data(container),
      b004EventCodeHash: Data(),
      currentEnin: vectorEnin
    )
  }

  private func peerId(_ n: UInt8) -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[15] = n
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  /// Mirrors `BarnardParticipantRelayTests.finishContention`: run the epoch
  /// decision, then let the <=15 s contention delay elapse.
  private func finishContention(_ h: Harness) {
    h.engine.advanceParticipantRelay()
    h.clock.now += 15_001
    h.engine.advanceParticipantRelay()
    if !h.engine.isRelayServing {
      h.clock.now = (h.clock.now / 30_000 + 1) * 30_000
      h.engine.advanceParticipantRelay()
      h.clock.now += 15_001
      h.engine.advanceParticipantRelay()
    }
  }

  private func decisions(_ h: Harness) -> [BarnardRelayDecisionEvent] {
    h.events().compactMap { if case .relayDecision(let d) = $0 { return d } else { return nil } }
  }

  // MARK: - 1. A verified receipt drives the relay and is served unchanged

  func testVerifiedReceiptIsRelayedWithHopIncrementedAndBytesUnchanged() throws {
    let container = try vectorContainer(hop: 0)
    let envelope = Array(container[4...])
    let h = harness()

    feed(h, container, peer: 1)
    XCTAssertEqual(h.verifier.invocations, 1, "a radioSelfVerified receipt must reach the relay verifier")
    finishContention(h)

    XCTAssertTrue(h.engine.isRelayServing)
    let served = try XCTUnwrap(h.engine.relayContainerForServing())
    XCTAssertEqual([UInt8](served), try XCTUnwrap(BarnardB005EnvelopeV2.encodeContainer(relayHopCount: 1, signedEnvelope: envelope)))
    // Signature preserving: the envelope is copied, never re-encoded.
    XCTAssertEqual(Array([UInt8](served)[4...]), envelope)

    let broadcast = try XCTUnwrap(decisions(h).last { $0.decision == .broadcast })
    XCTAssertEqual(broadcast.hop, 1)
    XCTAssertEqual(broadcast.reason, "elected")
    XCTAssertEqual(broadcast.payloadDigest, BarnardCrypto.sha256(Data(envelope)))
  }

  // MARK: - 2. Hop at the limit is never re-broadcast

  func testHopAtLimitIsNeverRebroadcast() throws {
    let h = harness()
    feed(h, try vectorContainer(hop: 2), peer: 1)
    finishContention(h)

    XCTAssertFalse(h.engine.isRelayServing)
    XCTAssertNil(h.engine.relayContainerForServing())
    XCTAssertTrue(decisions(h).isEmpty, "a hop-two observation must produce no broadcast decision")
  }

  // MARK: - 3. v1 traffic never reaches the relay

  func testV1EventInfoHintNeverReachesTheRelay() throws {
    let h = harness()
    let payload = try XCTUnwrap(hexBytes("010100124261726e61726420436f72652053706c69740200080b9f14789f13968f"))
    let b004 = try XCTUnwrap(hexBytes("0b9f14789f13968f"))

    h.engine.processEventInfoValue(
      peripheralId: peerId(1), value: Data(payload), b004EventCodeHash: Data(b004), currentEnin: vectorEnin
    )
    finishContention(h)

    XCTAssertEqual(h.verifier.invocations, 0, "v1 hint traffic must never be offered to the relay")
    XCTAssertFalse(h.engine.isRelayServing)
    XCTAssertNil(h.engine.relayContainerForServing())
  }

  // MARK: - 4. Unverified containers never reach the relay

  func testUnverifiedContainerNeverReachesTheRelay() throws {
    var container = try vectorContainer(hop: 0)
    container[container.count - 2] ^= 0x01  // corrupt the signature

    let h = harness()
    feed(h, container, peer: 1)
    finishContention(h)

    XCTAssertEqual(h.verifier.invocations, 0, "an unverified container must never be offered to the relay")
    XCTAssertFalse(h.engine.isRelayServing)
  }

  // MARK: - 5. Shared vectors through the engine seam

  func testRelayHopDedupVectorsThroughTheEngineSeam() throws {
    let hop = try vectors("relay-hop-dedup")
    XCTAssertEqual(hop["format_version"], "03")
    XCTAssertEqual(hop["handle_cap"], "32")
    XCTAssertEqual(hop["relay_lifetime_enins"], "12")

    // The file's own placeholder containers must agree with the encoder the
    // relay serves through, even though they cannot cross the engine seam.
    let placeholder = try XCTUnwrap(hexBytes(hop["envelope"]!))
    for (key, hopCount) in [("hop_zero_container", UInt8(0)), ("hop_one_container", 1), ("hop_two_container", 2)] {
      XCTAssertEqual(try XCTUnwrap(hexBytes(hop[key]!)),
                     try XCTUnwrap(BarnardB005EnvelopeV2.encodeContainer(relayHopCount: hopCount, signedEnvelope: placeholder)),
                     key)
    }
    XCTAssertEqual(try XCTUnwrap(hexBytes(hop["served_from_zero"]!)), try XCTUnwrap(hexBytes(hop["hop_one_container"]!)))
    XCTAssertEqual(try XCTUnwrap(hexBytes(hop["served_from_one"]!)), try XCTUnwrap(hexBytes(hop["hop_two_container"]!)))

    // served hop = observed minimum + 1, and nothing at hop two, driven with
    // the signed conformance envelope so the engine's verifier accepts it.
    let signedEnvelope = Array(try vectorContainer(hop: 0)[4...])
    for observed in [UInt8(0), 1] {
      let h = harness()
      feed(h, try vectorContainer(hop: observed), peer: 1)
      finishContention(h)
      let served = try XCTUnwrap(h.engine.relayContainerForServing(), "observed hop \(observed)")
      XCTAssertEqual([UInt8](served),
                     try XCTUnwrap(BarnardB005EnvelopeV2.encodeContainer(relayHopCount: observed + 1, signedEnvelope: signedEnvelope)))
    }

    // Duplicate at a lower hop wins: hop one then hop zero must serve hop one.
    let h = harness()
    feed(h, try vectorContainer(hop: 1), peer: 1)
    feed(h, try vectorContainer(hop: 0), peer: 2)
    finishContention(h)
    XCTAssertEqual([UInt8](try XCTUnwrap(h.engine.relayContainerForServing())),
                   try XCTUnwrap(BarnardB005EnvelopeV2.encodeContainer(relayHopCount: 1, signedEnvelope: signedEnvelope)))
  }

  func testDensityDecisionVectorsThroughTheEngineSeam() throws {
    let density = try vectors("density-decisions")
    let k = Int(density["k"]!)!
    let contentionMax = Int64(density["contention_max_ms"]!)!
    XCTAssertEqual(k, 3)
    XCTAssertEqual(Int64(density["window_ms"]!)!, 30_000)

    for r in 0...4 {
      let enterNumerator = Int(density["r\(r)_enter_numerator"]!)!
      XCTAssertEqual(enterNumerator, max(0, k - r))

      let h = harness()
      // Establish the candidate from a direct source (hop 0): hop-zero peers
      // do not count toward r.
      feed(h, try vectorContainer(hop: 0), peer: 1)
      // r distinct hop-positive relay sources inside the density window.
      for i in 0..<r { feed(h, try vectorContainer(hop: 1), peer: UInt8(100 + i)) }

      h.engine.advanceParticipantRelay()
      h.clock.now += contentionMax + 1
      h.engine.advanceParticipantRelay()

      XCTAssertEqual(h.engine.isRelayServing, enterNumerator > 0, "r=\(r) enter decision mismatch")
    }
  }

  func testThirtyThreeHandlesSaturateThroughTheEngineSeam() throws {
    let h = harness()
    feed(h, try vectorContainer(hop: 1), peer: 0)
    for i in 1...32 { feed(h, try vectorContainer(hop: 1), peer: UInt8(i)) }
    h.engine.advanceParticipantRelay()
    h.clock.now += 15_001
    h.engine.advanceParticipantRelay()
    XCTAssertFalse(h.engine.isRelayServing, "32 handles plus overflow must saturate r >= k")
  }

  // MARK: - 6. Serving precedence and lease teardown

  func testOwnEventInfoValueTakesPrecedenceOverTheRelayedContainer() throws {
    let h = harness()
    feed(h, try vectorContainer(hop: 0), peer: 1)
    finishContention(h)
    XCTAssertNotNil(h.engine.relayContainerForServing())
    // With no own value configured, the relayed container is what B005 serves.
    XCTAssertEqual(h.engine.eventInfoValueForRead(), h.engine.relayContainerForServing())

    // Once this device serves its own event-info value, that wins.
    // The joined event code lives in UserDefaults.standard, which every other
    // engine in this process shares, so it must be cleared again.
    defer { h.engine.leaveEvent() }
    h.engine.joinEvent("BARNARD-RELAY-TEST")
    try h.engine.configureEventInfoServing(
      organizerDesignated: true, eventActiveForDiscovery: true, eventDisplayName: "Own Event"
    )
    let own = try XCTUnwrap(h.engine.eventInfoValueForRead())
    XCTAssertNotEqual(own, h.engine.relayContainerForServing())
    XCTAssertEqual(own.first, 0x01, "the own value is the unchanged v1 event-info payload")
  }

  func testStoppingScanClearsTheRelayLease() throws {
    let h = harness()
    feed(h, try vectorContainer(hop: 0), peer: 1)
    finishContention(h)
    XCTAssertTrue(h.engine.isRelayServing)

    h.engine.stopScan()

    XCTAssertFalse(h.engine.isRelayServing)
    XCTAssertNil(h.engine.relayContainerForServing())
    let stop = try XCTUnwrap(decisions(h).last { $0.decision == .stop })
    XCTAssertEqual(stop.reason, "host_stop")
  }

  func testRelayIsInertUntilAVerifierIsConfigured() throws {
    let h = harness(configureRelay: false)
    feed(h, try vectorContainer(hop: 0), peer: 1)
    h.engine.advanceParticipantRelay()
    XCTAssertFalse(h.engine.isRelayServing)
    XCTAssertNil(h.engine.relayContainerForServing())
    XCTAssertTrue(decisions(h).isEmpty)
  }

  // MARK: - Vectors

  private func vectorContainer(hop: UInt8) throws -> [UInt8] {
    let base = try XCTUnwrap(hexBytes(try envelopeVector("v1_container")))
    var out = base
    out[1] = hop
    return out
  }

  private func hexBytes(_ hex: String) -> [UInt8]? {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  private func envelopeVector(_ key: String) throws -> String {
    try XCTUnwrap(try vectors("b005-envelope-v2")[key], "missing vector \(key)")
  }

  private func vectors(_ name: String) throws -> [String: String] {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<20 {
      let candidate = directory.appendingPathComponent("test-vectors/\(name).txt")
      if let text = try? String(contentsOf: candidate, encoding: .utf8) {
        return Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
          let s = line.trimmingCharacters(in: .whitespaces)
          guard !s.isEmpty, !s.hasPrefix("#"), let i = s.firstIndex(of: "=") else { return nil }
          return (String(s[..<i]), String(s[s.index(after: i)...]))
        })
      }
      directory.deleteLastPathComponent()
    }
    throw XCTSkip("test-vectors/\(name).txt not found")
  }
}
