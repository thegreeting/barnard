import "dart:typed_data";

import "transport.dart";

class RssiSample {
  const RssiSample({
    required this.timestamp,
    required this.rpid,
    required this.rssi,
    required this.transport,
  });

  final DateTime timestamp;
  final Uint8List rpid;
  final int rssi;
  final TransportKind transport;
}

class RssiSummary {
  const RssiSummary({
    required this.count,
    required this.min,
    required this.max,
    required this.mean,
  });

  final int count;
  final int min;
  final int max;
  final double mean;
}
