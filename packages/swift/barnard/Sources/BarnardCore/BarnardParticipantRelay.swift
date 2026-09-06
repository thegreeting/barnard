// Use of this source code is governed by a BSD-style license.

public protocol BarnardRelayMonotonicClock { func relayNowMilliseconds() -> Int64 }
public protocol BarnardRelayEninSource { func relayCurrentEnin() -> UInt32? }
public protocol BarnardRelayVerifier {
  func verifyRelayEnvelope(_ bytes: [UInt8], currentEnin: UInt32) -> BarnardRelayVerification
}
public protocol BarnardRelayOutputSink {
  func startServingRelayContainer(_ bytes: [UInt8])
  func stopServingRelayContainer()
}
public protocol BarnardRelayJoinedEventProvider { func relayJoinedEventId() -> [UInt8]? }

public enum BarnardRelayVerification: Equatable {
  case rejected
  case radioSelfVerified
  case registryVerified(eventId: [UInt8], validFromEnin: UInt32, validThroughEnin: UInt32, relayExpiresAtEnin: UInt32)
}

public enum BarnardRelayObservationResult: Equatable {
  case accepted, duplicate, saturated, rejected
}

/// Pure B005 participant-relay policy. Peer handles, neighborhood counts, and
/// election key material remain private implementation details.
public final class BarnardParticipantRelay {
  private struct Candidate {
    let digest: [UInt8]
    let envelope: [UInt8]
    var hop: UInt8
    let eventId: [UInt8]
    let verifiedAt: Int64
    let validFrom: UInt32
    let validThrough: UInt32
    let expires: UInt32
  }
  private let clock: any BarnardRelayMonotonicClock
  private let enin: any BarnardRelayEninSource
  private let verifier: any BarnardRelayVerifier
  private let sink: any BarnardRelayOutputSink
  private let joinedEventProvider: any BarnardRelayJoinedEventProvider
  private let electionKey: [UInt8]
  private var candidates: [[UInt8]: Candidate] = [:]
  private var selected: [UInt8]?
  private var pinUntil: Int64 = 0
  private var handles: [[UInt8]: Int64] = [:]
  private var overflowSeenAt: Int64?
  private var activeUntil: Int64?
  private var contentionUntil: Int64?
  private var lastDecisionEpoch: Int64?
  private var stopped = false

  public init(clock: any BarnardRelayMonotonicClock, eninSource: any BarnardRelayEninSource,
              verifier: any BarnardRelayVerifier, outputSink: any BarnardRelayOutputSink,
              joinedEventProvider: any BarnardRelayJoinedEventProvider,
              randomnessSeedMaterial: [UInt8]) {
    self.clock = clock; self.enin = eninSource; self.verifier = verifier
    self.sink = outputSink; self.joinedEventProvider = joinedEventProvider; self.electionKey = randomnessSeedMaterial
  }

  @discardableResult public func observe(container: [UInt8], peerHandle: [UInt8]) -> BarnardRelayObservationResult {
    guard !stopped, container.count >= 5, container.count <= 512, container[0] == 3,
      container[1] <= 2 else { return .rejected }
    let length = Int(container[2]) << 8 | Int(container[3])
    guard length > 0, length <= 508, length + 4 == container.count,
      let nowEnin = enin.relayCurrentEnin() else { return .rejected }
    let envelope = Array(container[4...])
    let digest = BarnardCorePrimitives.sha256(envelope)
    if var old = candidates[digest] {
      guard isWithinRelayWindow(old, current: nowEnin) else {
        candidates.removeValue(forKey: digest)
        if selected == digest { deselect() }
        return .rejected
      }
      old.hop = min(old.hop, container[1]); candidates[digest] = old
      if selected == digest, container[1] > 0 { retain(handle: peerHandle, now: clock.relayNowMilliseconds()) }
      return .duplicate
    }
    guard candidates.count < 32 else { return .saturated }
    guard case let .registryVerified(eventId, validFrom, validThrough, expires) = verifier.verifyRelayEnvelope(envelope, currentEnin: nowEnin),
      validFrom <= nowEnin, nowEnin < expires, expires <= validThrough,
      UInt64(expires) - UInt64(validFrom) <= 12 else { return .rejected }
    candidates[digest] = Candidate(digest: digest, envelope: envelope, hop: container[1], eventId: eventId,
      verifiedAt: clock.relayNowMilliseconds(), validFrom: validFrom, validThrough: validThrough, expires: expires)
    selectIfNeeded(force: selected == nil)
    if selected == digest, container[1] > 0 { retain(handle: peerHandle, now: clock.relayNowMilliseconds()) }
    return .accepted
  }
  private func isWithinRelayWindow(_ candidate: Candidate, current: UInt32) -> Bool {
    candidate.validFrom <= current && current < candidate.expires
  }

  /// Runs expiry, selection, contention, and lease decisions.
  ///
  /// This is the only entry point that consults the lease clock, so it must be
  /// driven on a timer, not only after observations: a device that stops
  /// hearing anything would otherwise keep serving a lease that has already
  /// run out. `observe` deliberately takes no lease decision.
  public func advance() {
    guard !stopped else { return }
    let now = clock.relayNowMilliseconds()
    guard let current = enin.relayCurrentEnin() else { teardownAll(); return }
    let invalid = candidates.filter { !isWithinRelayWindow($0.value, current: current) }.map(\.key)
    for key in invalid { candidates.removeValue(forKey: key) }
    if let choice = selected, candidates[choice] == nil { deselect() }
    selectIfNeeded(force: selected == nil || now >= pinUntil)
    handles = handles.filter { now - $0.value < 30_000 }
    var wasActive = false
    if let end = activeUntil, now >= end { wasActive = true; stopLease() }
    if let end = contentionUntil, now >= end {
      contentionUntil = nil
      if relayCount(now: now) < 3 { startLease(now: now) }
    }
    guard contentionUntil == nil, activeUntil == nil, let choice = selected,
      let candidate = candidates[choice], candidate.hop < 2 else { return }
    // Spec: "At each 30-second decision boundary, let r be distinct matching
    // relay sources heard during the preceding T" -- the decision is made once
    // per wall-clock epoch, not re-evaluated every time r changes within it.
    let epoch = now / 30_000
    guard lastDecisionEpoch != epoch else { return }
    lastDecisionEpoch = epoch
    let r = relayCount(now: now)
    let threshold = wasActive ? min(1.0, 3.0 / Double(r + 1)) : min(1.0, max(0.0, Double(3 - r) / 3.0))
    if randomUnit(digest: candidate.digest, epoch: epoch, purpose: 0) < threshold {
      contentionUntil = now + Int64(randomUnit(digest: candidate.digest, epoch: epoch, purpose: 1) * 15_001.0)
    }
  }

  public func invalidateDefinition() { teardownAll() }
  public func signatureFailed() { teardownAll() }
  public func hostStop() { stopped = true; teardownAll() }
  public var isServing: Bool { activeUntil != nil }

  private func selectIfNeeded(force: Bool) {
    guard force else { return }
    let old = selected
    let joined = joinedEventProvider.relayJoinedEventId()
    selected = candidates.values.sorted {
      let lhsJoined = joined != nil && $0.eventId == joined!
      let rhsJoined = joined != nil && $1.eventId == joined!
      if lhsJoined != rhsJoined { return lhsJoined }
      if $0.hop != $1.hop { return $0.hop < $1.hop }
      if $0.verifiedAt != $1.verifiedAt { return $0.verifiedAt < $1.verifiedAt }
      return $0.digest.lexicographicallyPrecedes($1.digest)
    }.first?.digest
    pinUntil = clock.relayNowMilliseconds() + 300_000
    if old != selected { stopLease(); handles.removeAll(); overflowSeenAt = nil; lastDecisionEpoch = nil }
  }
  private func retain(handle: [UInt8], now: Int64) {
    // Prune before checking the 32-handle cap so a handle observed T ago no
    // longer holds a slot. Spec line 231: "further handles saturate r >= k
    // without being retained" -- a new handle arriving while 32 are already
    // retained is neither retained nor allowed to evict an existing one; it
    // only marks overflowSeenAt so r reads as saturated until that overflow
    // itself ages out of the window.
    handles = handles.filter { now - $0.value < 30_000 }
    if handles[handle] != nil { handles[handle] = now; return }
    if handles.count >= 32 { overflowSeenAt = now; return }
    handles[handle] = now
  }
  private func relayCount(now: Int64) -> Int {
    let live = handles.values.filter { now - $0 < 30_000 }.count
    if let overflow = overflowSeenAt, now - overflow < 30_000 { return max(live, 3) }
    return live
  }
  private func startLease(now: Int64) {
    guard let key = selected, let c = candidates[key], c.hop < 2 else { return }
    let n = c.envelope.count
    sink.startServingRelayContainer([3, c.hop + 1, UInt8(n >> 8), UInt8(n & 255)] + c.envelope)
    activeUntil = now + 30_000
  }
  private func stopLease() { if activeUntil != nil { sink.stopServingRelayContainer() }; activeUntil = nil; contentionUntil = nil }
  private func deselect() { stopLease(); selected = nil; handles.removeAll(); overflowSeenAt = nil; lastDecisionEpoch = nil }
  private func teardownAll() { deselect(); candidates.removeAll() }
  private func randomUnit(digest: [UInt8], epoch: Int64, purpose: UInt8) -> Double {
    var bytes = electionKey + digest
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: epoch >> shift)) }
    bytes.append(purpose)
    let hash = BarnardCorePrimitives.sha256(bytes)
    var value: UInt64 = 0; for byte in hash.prefix(8) { value = (value << 8) | UInt64(byte) }
    return Double(value >> 11) / 9_007_199_254_740_992.0
  }
}
