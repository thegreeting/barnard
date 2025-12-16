import "dart:async";

import "package:barnard/barnard.dart";
import "package:test/test.dart";

void main() {
  test("mock emits DetectionEvent and stores RSSI samples", () async {
    final BarnardClient barnard = Barnard.mock(simulatedPeerCount: 10, tickMs: 100);

    final List<DetectionEvent> detections = <DetectionEvent>[];
    final StreamSubscription sub = barnard.events.listen((BarnardEvent e) {
      if (e is DetectionEvent) detections.add(e);
    });

    await barnard.startScan();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await barnard.stopScan();

    expect(detections.isNotEmpty, isTrue);
    final List<RssiSample> samples = barnard.getRssiSamples(limit: 50);
    expect(samples.isNotEmpty, isTrue);

    await barnard.dispose();
    await sub.cancel();
  });
}
