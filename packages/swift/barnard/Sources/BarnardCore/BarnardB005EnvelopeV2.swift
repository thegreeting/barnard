// Use of this source code is governed by a BSD-style license.

// BarnardCore is stdlib-only: full Unicode NFC normalization needs composition and
// decomposition tables the bare standard library does not expose, so the NFC check spec 122
// step 3 requires is injected via this protocol rather than done in-tree. The concrete
// implementation backed by the platform's own Unicode support lives in the outer Barnard
// module (see `BarnardB005NativeDisplayNameNormalizer`), matching how
// `BarnardB005PublicKeyRecovering` keeps the crypto backend out of BarnardCore.
public protocol BarnardB005DisplayNameNormalizing {
  /// Returns whether `value` is already in Unicode Normalization Form C.
  func isNormalizedNFC(_ value: String) -> Bool
}

public enum BarnardB005ReceiverState: Equatable {
  case UNVERIFIED
  case RADIO_SELF_VERIFIED
  case REGISTRY_VERIFIED
}

public protocol BarnardB005PublicKeyRecovering {
  func recover(recoveryId: Int, r: [UInt8], s: [UInt8], digest: [UInt8]) -> [UInt8]?
  func isValidCompressedKey(_ key: [UInt8]) -> Bool
}

public struct BarnardB005NativeRecoverer: BarnardB005PublicKeyRecovering {
  public init() {}
  public func recover(recoveryId: Int, r: [UInt8], s: [UInt8], digest: [UInt8]) -> [UInt8]? {
    BarnardCoreSigning.recoverPublicKey(recoveryId: recoveryId, r: r, s: s, messageHash32: digest)
  }
  public func isValidCompressedKey(_ key: [UInt8]) -> Bool {
    BarnardCoreSigning.serializeUncompressedPublicKey(key) != nil
  }
}

/// A plain struct with an `internal` initializer -- not `public` -- so a consumer outside this
/// module cannot construct one (in particular, cannot fabricate `receiverState =
/// .REGISTRY_VERIFIED` directly). The only way to obtain one is `BarnardB005EnvelopeV2.verify`,
/// which always produces `.UNVERIFIED` or `.RADIO_SELF_VERIFIED`. This SDK never assigns
/// `.REGISTRY_VERIFIED`: doing so is the responsibility of the component that performed the
/// authenticated registry read (the host app), per spec 122's receiver policy; tracked as
/// beid#367 / dispatch#11 (P4).
public struct BarnardB005VerifiedEnvelope {
  public let receiverState: BarnardB005ReceiverState
  public let relayHopCount: UInt8
  public let eventId: [UInt8]
  public let keySetDigest: [UInt8]
  public let joinMode: UInt8
  public let eventCodeHash: [UInt8]
  public let eventDisplayName: String
  public let validFromEnin: Int64
  public let validThroughEnin: Int64
  public let eninSeconds: UInt16
  public let signedEnvelope: [UInt8]

  /// This SDK never assigns `.REGISTRY_VERIFIED`: doing so is the responsibility of the
  /// component that performed the authenticated registry read (the host app), per spec 122's
  /// receiver policy; tracked as beid#367 / dispatch#11 (P4).
  internal init(receiverState: BarnardB005ReceiverState, relayHopCount: UInt8, eventId: [UInt8], keySetDigest: [UInt8], joinMode: UInt8, eventCodeHash: [UInt8], eventDisplayName: String, validFromEnin: Int64, validThroughEnin: Int64, eninSeconds: UInt16, signedEnvelope: [UInt8]) {
    self.receiverState = receiverState
    self.relayHopCount = relayHopCount
    self.eventId = eventId
    self.keySetDigest = keySetDigest
    self.joinMode = joinMode
    self.eventCodeHash = eventCodeHash
    self.eventDisplayName = eventDisplayName
    self.validFromEnin = validFromEnin
    self.validThroughEnin = validThroughEnin
    self.eninSeconds = eninSeconds
    self.signedEnvelope = signedEnvelope
  }

}

/// The subset of parallax's anchored `EventDefinitionV1` (protocol/spec/v0.1/event-definition.md)
/// that spec 134 step 4 requires a receiver to agree against: `eventId`, the authority key-set
/// digest (signer-authority agreement), `joinMode`, `eventCodeHash`, and the registered Unix-time
/// validity window.
public struct BarnardEventDefinitionV1 {
  public let eventId: [UInt8]
  public let keySetDigest: [UInt8]
  public let joinMode: UInt8
  public let eventCodeHash: [UInt8]
  public let validFromUnixSeconds: Int64
  public let validUntilUnixSeconds: Int64

  public init(eventId: [UInt8], keySetDigest: [UInt8], joinMode: UInt8, eventCodeHash: [UInt8], validFromUnixSeconds: Int64, validUntilUnixSeconds: Int64) {
    self.eventId = eventId
    self.keySetDigest = keySetDigest
    self.joinMode = joinMode
    self.eventCodeHash = eventCodeHash
    self.validFromUnixSeconds = validFromUnixSeconds
    self.validUntilUnixSeconds = validUntilUnixSeconds
  }
}

/// A single field on which `registryAgreement` can find a mismatch between an envelope and a
/// registered `EventDefinitionV1`.
public enum BarnardRegistryMismatchField: Equatable {
  case EVENT_ID, EVENT_CODE_HASH, KEY_SET_DIGEST, JOIN_MODE, VALIDITY_WINDOW
}

/// The result of comparing a `.RADIO_SELF_VERIFIED` envelope against a registered
/// `EventDefinitionV1`: either the two agree, or `mismatchedFields` names every field that
/// disagreed. Either way this is a pure comparison -- it never changes the envelope's
/// `BarnardB005ReceiverState`. Assigning `.REGISTRY_VERIFIED` is the responsibility of the
/// component that performed the authenticated registry read (the host app), per spec 122's
/// receiver policy; tracked as beid#367 / dispatch#11 (P4).
public enum BarnardRegistryAgreement: Equatable {
  case agrees
  case mismatched(mismatchedFields: Set<BarnardRegistryMismatchField>)
}

/// Why a B005 v2 container failed the clock-independent structural checks.
///
/// These are exactly the guards that depend on nothing but the bytes: no
/// current ENIN, no signature or key recovery, no display-name normalisation.
/// `BarnardB005EnvelopeV2.verify` runs them first, and a host serving its own
/// container runs them on their own, so both paths accept and reject the same
/// shapes.
public enum BarnardB005StructureError: Equatable {
  /// Container outside `4...512` bytes.
  case containerLength
  /// Byte 0 is not `BarnardB005EnvelopeV2.formatVersion`.
  case formatVersion
  /// Byte 1 exceeds the spec 134 hop limit of 2.
  case hopCount
  /// The big-endian length at bytes 2-3 exceeds 508 or disagrees with the
  /// byte count.
  case envelopeLength
  /// Envelope byte 0 is not `BarnardB005EnvelopeV2.envelopeVersion`.
  case envelopeVersion
  /// The envelope is shorter than the 199-byte floor its fixed fields need.
  case envelopeTooSmall
  /// The authority key count is outside `1...8`.
  case keyCount
  /// A declared length runs past the envelope, or the total size disagrees
  /// with the sum of its parts.
  case fieldLayout
  /// `joinMode` is neither 0 nor 1.
  case joinMode
  /// `eninSeconds` is zero, which no ENIN arithmetic can use.
  case eninSeconds
  /// The event-code-hash TLV type byte is not 2.
  case eventCodeHashTlvType
  /// The display-name length is outside `1...64`.
  case displayNameLength
}

public enum BarnardB005EnvelopeV2 {
  public static let formatVersion: UInt8 = 3
  public static let envelopeVersion: UInt8 = 1

  /// Clock-independent structural validation of a container, shared by
  /// `verify` and by any caller that must judge a container's shape without a
  /// current ENIN, a signature check, or key recovery.
  ///
  /// Returns nil when the container is well formed at this layer. Passing says
  /// nothing about authenticity: the signature, the validity window, the key
  /// set and the display-name normalisation are all still unchecked, because
  /// each of those needs an input this function deliberately does not take.
  public static func validateStructure(container: [UInt8]) -> BarnardB005StructureError? {
    guard container.count >= 4, container.count <= 512 else { return .containerLength }
    guard container[0] == formatVersion else { return .formatVersion }
    guard container[1] <= 2 else { return .hopCount }
    let envelopeLength = Int(container[2]) << 8 | Int(container[3])
    guard envelopeLength <= 508, envelopeLength == container.count - 4 else { return .envelopeLength }
    let envelope = Array(container[4...])
    guard envelope.count >= 199 else { return .envelopeTooSmall }
    guard envelope[0] == envelopeVersion else { return .envelopeVersion }
    let n = Int(envelope[73])
    guard (1...8).contains(n) else { return .keyCount }
    let a = 74 + 33 * n
    guard a + 26 + 65 <= envelope.count else { return .fieldLayout }
    guard envelope[a] <= 1 else { return .joinMode }
    guard read16(envelope, a + 1) != 0 else { return .eninSeconds }
    guard envelope[a + 15] == 2 else { return .eventCodeHashTlvType }
    let nameLength = Int(envelope[a + 24])
    guard (1...64).contains(nameLength) else { return .displayNameLength }
    let certLengthOffset = a + 25 + nameLength
    guard certLengthOffset < envelope.count else { return .fieldLayout }
    let certLength = Int(envelope[certLengthOffset])
    guard 165 + 33 * n + nameLength + certLength == envelope.count else { return .fieldLayout }
    return nil
  }
  private static let signatureDomain = Array("barnard-b005-event-info:v1".utf8)

  public static func eventKeySetBytes(_ keys: [[UInt8]]) -> [UInt8]? {
    guard (1...8).contains(keys.count), keys.allSatisfy({ $0.count == 33 }) else { return nil }
    var out: [UInt8] = [0xa3, 0x01, 0x01, 0x02, 0x80 | UInt8(keys.count)]
    for key in keys { out += [0x58, 0x21] + key }
    return out + [0x03, 0x01]
  }

  public static func keySetDigest(_ keys: [[UInt8]]) -> [UInt8]? {
    guard let encoded = eventKeySetBytes(keys) else { return nil }
    return BarnardCoreCrypto.sha256(Array("levarac:event-key-set-digest:v1\0".utf8) + encoded)
  }

  public static func computeEventId(registrar: [UInt8], anchorOperator: [UInt8], nonce: [UInt8], keySetDigest: [UInt8]) -> [UInt8]? {
    guard registrar.count == 20, anchorOperator.count == 20, nonce.count == 32, keySetDigest.count == 32 else { return nil }
    let domain = BarnardCoreCrypto.keccak256(Array("levarac:event:v1".utf8))
    return BarnardCoreCrypto.keccak256(domain + [UInt8](repeating: 0, count: 12) + registrar + [UInt8](repeating: 0, count: 12) + anchorOperator + nonce + keySetDigest)
  }

  public static func openEventCodeHash(eventId: [UInt8]) -> [UInt8]? {
    guard eventId.count == 32 else { return nil }
    let code = eventId.map { String(formatByte: $0) }.joined()
    return Array(BarnardCoreCrypto.sha256(Array(code.utf8)).prefix(8))
  }

  public static func encodeContainer(relayHopCount: UInt8, signedEnvelope: [UInt8]) -> [UInt8]? {
    guard relayHopCount <= 2, signedEnvelope.count <= 508 else { return nil }
    return [3, relayHopCount, UInt8(signedEnvelope.count >> 8), UInt8(signedEnvelope.count & 255)] + signedEnvelope
  }

  public static func verify(container: [UInt8], currentEnin: Int64?, nameValidator: any BarnardB005DisplayNameNormalizing, recoverer: any BarnardB005PublicKeyRecovering = BarnardB005NativeRecoverer()) -> BarnardB005VerifiedEnvelope? {
    // Every clock-independent shape check lives in one place, so a host
    // serving its own container rejects exactly what a receiver would.
    guard validateStructure(container: container) == nil else { return nil }
    guard let now = currentEnin, now >= 0 else { return nil }
    let envelope = Array(container[4...])
    let registrar = Array(envelope[1..<21]), anchor = Array(envelope[21..<41]), nonce = Array(envelope[41..<73])
    let n = Int(envelope[73])
    let a = 74 + 33 * n
    var keys: [[UInt8]] = []
    for i in 0..<n {
      let key = Array(envelope[(74 + i * 33)..<(107 + i * 33)])
      guard recoverer.isValidCompressedKey(key), keys.last.map({ lexicographicallyLess($0, key) }) ?? true else { return nil }
      keys.append(key)
    }
    let joinMode = envelope[a]
    let eninSeconds = read16(envelope, a + 1)
    let validFrom = Int64(read32(envelope, a + 3)), validThrough = Int64(read32(envelope, a + 7)), expires = Int64(read32(envelope, a + 11))
    let codeHash = Array(envelope[(a + 16)..<(a + 24)])
    let nameLength = Int(envelope[a + 24])
    let nameStart = a + 25, certLengthOffset = nameStart + nameLength
    let certLength = Int(envelope[certLengthOffset])
    let nameBytes = Array(envelope[nameStart..<certLengthOffset])
    guard let name = strictDisplayName(nameBytes, nameValidator: nameValidator) else { return nil }
    guard let ksDigest = keySetDigest(keys), let eventId = computeEventId(registrar: registrar, anchorOperator: anchor, nonce: nonce, keySetDigest: ksDigest) else { return nil }
    guard validFrom <= now, now < expires, expires <= validThrough, expires >= validFrom, expires - validFrom <= 12 else { return nil }
    if joinMode == 0 {
      guard codeHash == openEventCodeHash(eventId: eventId) else { return nil }
    }
    let certStart = certLengthOffset + 1, signatureStart = certStart + certLength
    let expectedSigner: [UInt8]?
    if certLength == 0 { expectedSigner = nil }
    else {
      let cert = Array(envelope[certStart..<signatureStart])
      guard let parsed = parseCertificate(cert), parsed.eventId == eventId, parsed.roles == 1,
            parsed.eninStart <= UInt64(now), UInt64(now) <= parsed.eninEnd,
            recoverer.isValidCompressedKey(parsed.delegateKey) else { return nil }
      let candidates = keys.filter { key in
        Array(BarnardCoreCrypto.sha256(Array("levarac:cose-kid:v1\0".utf8) + key).prefix(8)) == parsed.kid
      }
      guard candidates.count == 1 else { return nil }
      guard let sigStructure = buildSigStructure(protected: parsed.protected, payload: parsed.payload) else { return nil }
      let certDigest = BarnardCoreCrypto.sha256(sigStructure)
      guard signatureMatches(parsed.signature, digest: certDigest, key: candidates[0], recoverer: recoverer, hasRecoveryByte: false) else { return nil }
      expectedSigner = parsed.delegateKey
    }
    let tbs = Array(envelope[..<signatureStart]), signature = Array(envelope[signatureStart...])
    let digest = BarnardCoreCrypto.sha256(signatureDomain + tbs)
    let signatureKey: [UInt8]?
    if let expectedSigner {
      signatureKey = signatureMatches(signature, digest: digest, key: expectedSigner, recoverer: recoverer, hasRecoveryByte: true) ? expectedSigner : nil
    } else {
      // Recover once: the recovered pubkey depends only on (r, s, v, digest), not on which
      // authority key it is compared against, so recovering per candidate key would recover the
      // identical point up to n times. Recover once and test set membership on the result.
      signatureKey = recoverMember(signature, digest: digest, keys: keys, recoverer: recoverer)
    }
    guard signatureKey != nil else { return nil }
    return BarnardB005VerifiedEnvelope(receiverState: .RADIO_SELF_VERIFIED, relayHopCount: container[1], eventId: eventId, keySetDigest: ksDigest, joinMode: joinMode, eventCodeHash: codeHash, eventDisplayName: name, validFromEnin: validFrom, validThroughEnin: validThrough, eninSeconds: eninSeconds, signedEnvelope: envelope)
  }

  /// Pure comparison of a `.RADIO_SELF_VERIFIED` envelope against a registered
  /// `EventDefinitionV1` for this `eventId` (spec 122 receiver policy, step 8; spec 134 step 4 as
  /// amended by errata #173, which drops the unsatisfiable display-name agreement). This never
  /// changes the envelope's `receiverState` -- assigning `.REGISTRY_VERIFIED` is the
  /// responsibility of the component that performed the authenticated registry read (the host
  /// app), per spec 122's receiver policy; tracked as beid#367 / dispatch#11 (P4).
  ///
  /// Spec 134 step 4 requires "exact ... validity-window ... agreement", not containment.
  /// `validThroughEnin` is treated as the INCLUSIVE last valid ENIN (window `[validFromEnin,
  /// validThroughEnin]`): spec 122 never states its own convention for this field, but parallax's
  /// `event-definition.md` (`validFrom`/`validUntil`, lines 52-53) is explicitly inclusive on both
  /// ends, and spec 122's only other ENIN range (the delegation cert's `eninStart`/`eninEnd`, spec
  /// 122:211) is likewise inclusive -- this is an issuer derivation erratum, tracked in the spec
  /// 122 errata. `eninSeconds`-denominated ENINs each cover `eninSeconds` consecutive Unix seconds,
  /// so the registry's inclusive Unix-second window is converted to the same inclusive ENIN shape
  /// conservatively (start rounded up, end rounded down) before the two windows are compared for
  /// exact equality. A registry window that does not fall on ENIN boundaries converts to an empty
  /// range and can never agree with anything.
  ///
  /// The conversion is `expectedFrom = ceilDiv(validFromUnixSeconds, eninSeconds)` and
  /// `expectedThrough = floorDiv(validUntilUnixSeconds + 1, eninSeconds) - 1` (spec 122 erratum for
  /// the issuer-side derivation; see barnard#180). `expectedThrough` is computed without ever
  /// forming `validUntilUnixSeconds + 1`, so it stays overflow-safe for an adversarial registry
  /// read. A registry definition with `validFromUnixSeconds < 0`, `validUntilUnixSeconds < 0`,
  /// `validFromUnixSeconds > validUntilUnixSeconds`, or `eninSeconds <= 0` is rejected as a
  /// `.VALIDITY_WINDOW` mismatch before any of this arithmetic runs, so every input to it stays
  /// non-negative and the conversion never negates `Int64.min` (which traps in Swift).
  public static func registryAgreement(_ verified: BarnardB005VerifiedEnvelope, definition: BarnardEventDefinitionV1) -> BarnardRegistryAgreement {
    let eninPerSecond = Int64(verified.eninSeconds)
    let validFrom = definition.validFromUnixSeconds
    let validUntil = definition.validUntilUnixSeconds
    let windowIsWellFormed = eninPerSecond > 0 && validFrom >= 0 && validUntil >= 0 && validFrom <= validUntil
    let registryStartEnin: Int64? = windowIsWellFormed ? -floorDiv(-validFrom, eninPerSecond) : nil
    let registryEndEnin: Int64? = windowIsWellFormed ? {
      // expectedThrough = floorDiv(validUntil + 1, eninPerSecond) - 1, via the floorMod identity
      // (see the Kotlin counterpart's comment) so validUntil + 1 is never actually formed.
      let q = floorDiv(validUntil, eninPerSecond)
      let r = floorMod(validUntil, eninPerSecond)
      return r == eninPerSecond - 1 ? q : q - 1
    }() : nil
    var mismatches: Set<BarnardRegistryMismatchField> = []
    if verified.eventId != definition.eventId { mismatches.insert(.EVENT_ID) }
    if verified.eventCodeHash != definition.eventCodeHash { mismatches.insert(.EVENT_CODE_HASH) }
    if verified.keySetDigest != definition.keySetDigest { mismatches.insert(.KEY_SET_DIGEST) }
    if verified.joinMode != definition.joinMode { mismatches.insert(.JOIN_MODE) }
    if registryStartEnin != verified.validFromEnin || registryEndEnin != verified.validThroughEnin { mismatches.insert(.VALIDITY_WINDOW) }
    return mismatches.isEmpty ? .agrees : .mismatched(mismatchedFields: mismatches)
  }

  /// Floor division for `Int64`, matching Kotlin's `Math.floorDiv`: rounds toward negative
  /// infinity rather than toward zero (Swift's `/` truncates toward zero).
  private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b, r = a % b
    return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
  }

  /// Floor modulo for `Int64`, matching Kotlin's `Math.floorMod`: the result always has the same
  /// sign as `b` (Swift's `%` can return a negative remainder for a positive `b`).
  private static func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
    let r = a % b
    return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
  }

  public static func buildSigStructure(protected: [UInt8], payload: [UInt8]) -> [UInt8]? {
    guard let p = cborBytes(protected), let pl = cborBytes(payload) else { return nil }
    return [0x84, 0x6a] + Array("Signature1".utf8) + p + [0x40] + pl
  }

  private struct Cert { let protected: [UInt8]; let payload: [UInt8]; let signature: [UInt8]; let kid: [UInt8]; let eventId: [UInt8]; let delegateKey: [UInt8]; let roles: UInt64; let eninStart: UInt64; let eninEnd: UInt64 }
  private static func parseCertificate(_ bytes: [UInt8]) -> Cert? {
    guard bytes.count <= 255 else { return nil }
    var r = CborReader(bytes)
    guard r.tag() == 18, r.array() == 4, let protected = r.bytes(), r.map() == 0, let payload = r.bytes(), let signature = r.bytes(), signature.count == 64, r.finished else { return nil }
    var h = CborReader(protected); guard h.map() == 3 else { return nil }
    guard h.uint() == 1, h.negative() == -47, h.uint() == 3, h.text() == "application/vnd.levarac.delegation-cert+cbor", h.uint() == 4, let kid = h.bytes(), kid.count == 8, h.finished else { return nil }
    var p = CborReader(payload); guard p.map() == 6,
      p.uint() == 1, p.uint() == 1,
      p.uint() == 2, let eventId = p.bytes(), eventId.count == 32,
      p.uint() == 3, let delegate = p.bytes(), delegate.count == 33,
      p.uint() == 4, let roles = p.uint(),
      p.uint() == 5, let start = p.uint(), start <= 9_007_199_254_740_991,
      p.uint() == 6, let end = p.uint(), end <= 9_007_199_254_740_991, start <= end, p.finished else { return nil }
    return Cert(protected: protected, payload: payload, signature: signature, kid: kid, eventId: eventId, delegateKey: delegate, roles: roles, eninStart: start, eninEnd: end)
  }

  // secp256k1 group order n, and n/2 (BIP-62/146 low-S bound), both big-endian.
  private static let curveOrder: [UInt8] = [
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
    0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b, 0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41,
  ]
  private static let curveOrderHalf: [UInt8] = [
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0x5d, 0x57, 0x6e, 0x73, 0x57, 0xa4, 0x50, 0x1d, 0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0,
  ]

  private static func isZero(_ b: [UInt8]) -> Bool { b.allSatisfy { $0 == 0 } }

  /// Enforces `0 < r < N` and `0 < s <= N/2` independent of the injected recoverer: the public
  /// `BarnardB005PublicKeyRecovering` protocol carries no contract that a conforming backend
  /// rejects a high-S or out-of-range signature on its own, so this MUST be checked here.
  private static func isLowSInRange(r: [UInt8], s: [UInt8]) -> Bool {
    !isZero(r) && lexicographicallyLess(r, curveOrder)
      && !isZero(s) && !lexicographicallyLess(curveOrderHalf, s)
  }

  private static func signatureMatches(_ signature: [UInt8], digest: [UInt8], key: [UInt8], recoverer: any BarnardB005PublicKeyRecovering, hasRecoveryByte: Bool) -> Bool {
    guard signature.count == (hasRecoveryByte ? 65 : 64) else { return false }
    let r = Array(signature[0..<32]), s = Array(signature[32..<64])
    guard isLowSInRange(r: r, s: s) else { return false }
    if hasRecoveryByte {
      let v = Int(signature[64]); guard v <= 1 else { return false }
      return recoverer.recover(recoveryId: v, r: r, s: s, digest: digest) == key
    }
    return (0...1).contains { recoverer.recover(recoveryId: $0, r: r, s: s, digest: digest) == key }
  }

  /// Recovers the signer exactly once (the recovery id is carried in the signature, so there is
  /// no ambiguity to resolve by trying candidates), then tests set membership on the result.
  private static func recoverMember(_ signature: [UInt8], digest: [UInt8], keys: [[UInt8]], recoverer: any BarnardB005PublicKeyRecovering) -> [UInt8]? {
    guard signature.count == 65 else { return nil }
    let r = Array(signature[0..<32]), s = Array(signature[32..<64])
    guard isLowSInRange(r: r, s: s) else { return nil }
    let v = Int(signature[64]); guard v <= 1 else { return nil }
    guard let recovered = recoverer.recover(recoveryId: v, r: r, s: s, digest: digest) else { return nil }
    return keys.contains(recovered) ? recovered : nil
  }

  private static func strictDisplayName(_ bytes: [UInt8], nameValidator: any BarnardB005DisplayNameNormalizing) -> String? {
    let value = String(decoding: bytes, as: UTF8.self)
    guard Array(value.utf8) == bytes else { return nil }
    for scalar in value.unicodeScalars {
      let v = scalar.value
      if v <= 0x1f || v == 0x7f { return nil }
    }
    guard nameValidator.isNormalizedNFC(value) else { return nil }
    return value
  }
  private static func lexicographicallyLess(_ a: [UInt8], _ b: [UInt8]) -> Bool { for i in a.indices { if a[i] != b[i] { return a[i] < b[i] } }; return false }
  private static func read16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
  private static func read32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
  private static func cborBytes(_ b: [UInt8]) -> [UInt8]? {
    switch b.count {
    case 0..<24: return [0x40 | UInt8(b.count)] + b
    case 24..<256: return [0x58, UInt8(b.count)] + b
    case 256..<65536: return [0x59, UInt8(b.count >> 8), UInt8(b.count & 0xff)] + b
    default: return nil
    }
  }
}

private struct CborReader {
  let input: [UInt8]; var offset = 0
  init(_ input: [UInt8]) { self.input = input }
  var finished: Bool { offset == input.count }
  mutating func head(_ major: UInt8) -> UInt64? {
    guard offset < input.count else { return nil }; let initial = input[offset]; offset += 1
    guard initial >> 5 == major else { return nil }; let ai = initial & 31
    if ai < 24 { return UInt64(ai) }
    let count: Int; switch ai { case 24: count = 1; case 25: count = 2; case 26: count = 4; case 27: count = 8; default: return nil }
    guard offset + count <= input.count else { return nil }; var v: UInt64 = 0
    for _ in 0..<count { v = (v << 8) | UInt64(input[offset]); offset += 1 }
    let minimum: UInt64 = count == 1 ? 24 : (count == 2 ? 256 : (count == 4 ? 65_536 : 4_294_967_296))
    return v >= minimum ? v : nil
  }
  mutating func uint() -> UInt64? { head(0) }
  mutating func negative() -> Int64? { guard let v = head(1), v <= UInt64(Int64.max) else { return nil }; return -1 - Int64(v) }
  mutating func bytes() -> [UInt8]? { guard let n = head(2), n <= UInt64(input.count - offset) else { return nil }; let end = offset + Int(n); defer { offset = end }; return Array(input[offset..<end]) }
  mutating func text() -> String? { guard let b = bytesMajor3() else { return nil }; let s = String(decoding: b, as: UTF8.self); return Array(s.utf8) == b ? s : nil }
  mutating func bytesMajor3() -> [UInt8]? { guard let n = head(3), n <= UInt64(input.count - offset) else { return nil }; let end = offset + Int(n); defer { offset = end }; return Array(input[offset..<end]) }
  mutating func array() -> UInt64? { head(4) }
  mutating func map() -> UInt64? { head(5) }
  mutating func tag() -> UInt64? { head(6) }
}

private extension String {
  init(formatByte byte: UInt8) {
    let digits = Array("0123456789abcdef".utf8)
    self = String(decoding: [digits[Int(byte >> 4)], digits[Int(byte & 15)]], as: UTF8.self)
  }
}
