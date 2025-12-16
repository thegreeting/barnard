import "dart:math";
import "dart:typed_data";

import "../../domain/transport.dart";

class MockPeer {
  MockPeer({
    required this.id,
    required this.seed,
    required this.transport,
  }) : _random = Random(seed);

  final int id;
  final int seed;
  final TransportKind transport;
  final Random _random;

  int _rssi = -60;

  Uint8List rpidForWindow(int windowIndex) {
    final int combinedSeed = seed ^ windowIndex;
    final Random r = Random(combinedSeed);
    final Uint8List bytes = Uint8List(16);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = r.nextInt(256);
    }
    return bytes;
  }

  int nextRssi() {
    final int delta = _random.nextInt(7) - 3; // [-3..+3]
    _rssi = (_rssi + delta).clamp(-95, -25);
    return _rssi;
  }
}
