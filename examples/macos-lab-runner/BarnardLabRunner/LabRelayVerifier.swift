// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import Foundation

/// Lab-only relay verifier. **Do not copy this into a product.**
///
/// Spec 134 lets a device re-broadcast someone else's event-info envelope only
/// after the host has read the authoritative on-chain definition and answered
/// `.registryVerified`. This verifier performs no registry read at all: it
/// re-runs the envelope's own signature check and then reports
/// `REGISTRY_VERIFIED` using the validity window the envelope carries about
/// itself. That answer is a fiction, useful only because the device lab needs
/// the relay path to actually fire between two machines it owns, on an event it
/// created. A real host must not report `REGISTRY_VERIFIED` from radio bytes.
///
/// The engine pre-filters: a container that fails radio verification never
/// reaches this method.
final class LabPermissiveRelayVerifier: BarnardRelayVerifier {
  func verifyRelayEnvelope(_ bytes: [UInt8], currentEnin: UInt32) -> BarnardRelayVerification {
    guard
      let verified = BarnardB005EnvelopeV2.verify(
        container: bytes,
        currentEnin: Int64(currentEnin),
        nameValidator: BarnardB005NativeDisplayNameNormalizer()
      )
    else {
      return .rejected
    }

    guard
      let validFrom = Self.clampToEnin(verified.validFromEnin),
      let validThrough = Self.clampToEnin(verified.validThroughEnin)
    else {
      return .rejected
    }

    return .registryVerified(
      eventId: verified.eventId,
      validFromEnin: validFrom,
      validThroughEnin: validThrough,
      // The lease may not outlive the envelope's own validity window.
      relayExpiresAtEnin: validThrough
    )
  }

  private static func clampToEnin(_ value: Int64) -> UInt32? {
    guard value >= 0 else { return nil }
    return value > Int64(UInt32.max) ? UInt32.max : UInt32(value)
  }
}
