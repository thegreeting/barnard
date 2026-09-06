// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
import BarnardCore
@testable import Barnard

/// Engine-level receive path for the B005 v2 signed envelope (issue #186).
///
/// `CBPeripheral` cannot be constructed in a unit test, so these drive
/// `BarnardEngine.processEventInfoValue(...)` — the seam the
/// `didUpdateValueFor` delegate reduces to once the CoreBluetooth plumbing
/// (connection teardown) is removed. The ENIN is injected for the same
/// reason the vectors need it: the conformance envelopes sit at ENIN
/// ~6.0e6, which no wall clock reachable by CI produces.
final class BarnardEngineB005EnvelopeV2Tests: XCTestCase {
  /// Inside the vectors' `[validFromEnin, relayExpiresAtEnin)` window.
  private let vectorEnin: Int64 = 6_000_000

  private func collectEvents(
    value: Data,
    b004EventCodeHash: Data = Data(),
    currentEnin: Int64
  ) -> [BarnardEvent] {
    let engine = BarnardEngine()
    var events: [BarnardEvent] = []
    engine.onEvent = { events.append($0) }
    engine.processEventInfoValue(
      peripheralId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
      value: value,
      b004EventCodeHash: b004EventCodeHash,
      currentEnin: currentEnin
    )
    return events
  }

  private func envelopeV2Event(_ events: [BarnardEvent]) -> BarnardEventInfoEnvelopeV2Event? {
    for event in events {
      if case .eventInfoEnvelopeV2(let payload) = event { return payload }
    }
    return nil
  }

  private func hasHint(_ events: [BarnardEvent]) -> Bool {
    events.contains { if case .eventInfoHint = $0 { return true } else { return false } }
  }

  func testValidVectorContainerEmitsRadioSelfVerifiedWithByteIdenticalRawContainer() throws {
    for key in ["v1_container", "v2_container"] {
      let container = try XCTUnwrap(hexData(try vector(key)))
      let events = collectEvents(value: container, currentEnin: vectorEnin)

      let emitted = try XCTUnwrap(envelopeV2Event(events), "\(key): no v2 envelope event")
      XCTAssertEqual(emitted.receiverState, .RADIO_SELF_VERIFIED, key)
      let verified = try XCTUnwrap(emitted.verifiedEnvelope, key)
      XCTAssertEqual(verified.receiverState, .RADIO_SELF_VERIFIED, key)
      XCTAssertNotEqual(verified.receiverState, .REGISTRY_VERIFIED, key)
      // Raw bytes must survive unchanged: spec 134 re-broadcast copies the
      // signature byte for byte.
      XCTAssertEqual(emitted.rawContainer, container, key)
      XCTAssertFalse(hasHint(events), "\(key): v1 hint must not be emitted for a v2 container")
    }
  }

  func testMutatedSignatureContainerEmitsUnverified() throws {
    var container = try XCTUnwrap(hexData(try vector("v1_container")))
    // Flip a bit in the trailing signature; every other field stays valid.
    let last = container.count - 2
    container[last] ^= 0x01

    let events = collectEvents(value: container, currentEnin: vectorEnin)

    let emitted = try XCTUnwrap(envelopeV2Event(events), "a failed envelope must still reach the host")
    XCTAssertEqual(emitted.receiverState, .UNVERIFIED)
    XCTAssertNil(emitted.verifiedEnvelope)
    XCTAssertEqual(emitted.rawContainer, container)
    XCTAssertFalse(hasHint(events))
  }

  func testMalformedContainerLengthEmitsUnverified() throws {
    let container = try XCTUnwrap(hexData(try vector("v1_container")))
    // Truncate a valid vector by a few bytes without updating the declared
    // `signedEnvelopeLength` header field, so it no longer ends exactly at
    // the container boundary (spec 122 "Delivery container" table).
    let truncated = container.dropLast(4)

    let events = collectEvents(value: truncated, currentEnin: vectorEnin)

    let emitted = try XCTUnwrap(envelopeV2Event(events), "a malformed container must still reach the host")
    XCTAssertEqual(emitted.receiverState, .UNVERIFIED)
    XCTAssertNil(emitted.verifiedEnvelope)
    XCTAssertEqual(emitted.rawContainer, truncated)
    XCTAssertFalse(hasHint(events))
  }

  func testV1PayloadStillEmitsHintAndNeverTheV2Case() throws {
    // Golden v1 B005 payload from BarnardEventInfoTests, with its B004 hash.
    let payload = try XCTUnwrap(
      hexData("010100124261726e61726420436f72652053706c69740200080b9f14789f13968f")
    )
    let b004 = try XCTUnwrap(hexData("0b9f14789f13968f"))

    let events = collectEvents(value: payload, b004EventCodeHash: b004, currentEnin: vectorEnin)

    XCTAssertTrue(hasHint(events), "v1 traffic must still emit eventInfoHint")
    XCTAssertNil(envelopeV2Event(events), "v1 traffic must never emit the v2 case")
  }

  // MARK: - Vectors

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
