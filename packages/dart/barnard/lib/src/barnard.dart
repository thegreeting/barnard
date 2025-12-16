import "usecase/barnard_client.dart";
import "interface_adapter/mock/mock_barnard.dart";

/// Factory entry points for Barnard implementations.
///
/// The long-term goal is to provide platform-backed implementations (BLE, etc.).
/// For early integration, use [mock].
abstract final class Barnard {
  static BarnardClient mock({
    int simulatedPeerCount = 50,
    int tickMs = 200,
    BarnardConfigOverrides? overrides,
  }) {
    return MockBarnard(
      simulatedPeerCount: simulatedPeerCount,
      tickMs: tickMs,
      overrides: overrides,
    );
  }
}

class BarnardConfigOverrides {
  const BarnardConfigOverrides({
    this.rotationSeconds,
    this.minPushIntervalMs,
    this.bufferMaxSamples,
  });

  final int? rotationSeconds;
  final int? minPushIntervalMs;
  final int? bufferMaxSamples;
}
