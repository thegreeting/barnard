import "transport.dart";

class BarnardCapabilities {
  const BarnardCapabilities({
    required this.supportedTransports,
    required this.supportsConnectionlessRpid,
    required this.supportsGattFallback,
    required this.supportsBackground,
    required this.supportsHighRateRssi,
  });

  final Set<TransportKind> supportedTransports;

  /// Whether this Transport can carry `rpid` without connecting (connectionless).
  final bool supportsConnectionlessRpid;

  /// Whether this Transport supports an optional GATT-like connection fallback.
  final bool supportsGattFallback;

  /// Whether background operation is supported by the implementation.
  final bool supportsBackground;

  /// Whether this implementation can produce high-rate RSSI observations.
  final bool supportsHighRateRssi;
}
