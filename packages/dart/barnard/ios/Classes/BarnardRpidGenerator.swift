import CryptoKit
import Foundation
import Security

final class BarnardRpidGenerator {
  private let storageKey = "barnard.rpidSeed"

  func currentPayload(formatVersion: UInt8, now: Date) -> Data {
    let rotationSeconds: Int64 = 600
    let unix = Int64(now.timeIntervalSince1970)
    let window = unix / rotationSeconds

    let seed = getOrCreateSeed()
    let key = SymmetricKey(data: seed)
    var be = window.bigEndian
    let msg = Data(bytes: &be, count: MemoryLayout.size(ofValue: be))
    let mac = HMAC<SHA256>.authenticationCode(for: msg, using: key)
    let rpid = Data(mac).prefix(16)

    var out = Data([formatVersion])
    out.append(rpid)
    return out
  }

  private func getOrCreateSeed() -> Data {
    let defaults = UserDefaults.standard
    if let existing = defaults.data(forKey: storageKey), existing.count >= 16 {
      return existing
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let seed = Data(bytes)
    defaults.set(seed, forKey: storageKey)
    return seed
  }
}

