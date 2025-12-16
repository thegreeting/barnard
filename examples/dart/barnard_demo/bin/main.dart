import "dart:async";

import "package:barnard/barnard.dart";
import "package:barnard/mock_barnard.dart";

Future<void> main() async {
  final BarnardClient barnard = MockBarnard(simulatedPeerCount: 50);

  final StreamSubscription sub = barnard.events.listen((BarnardEvent e) {
    print("[event] ${e.runtimeType} @ ${e.timestamp.toIso8601String()}");
  });

  await barnard.startAuto();
  await Future<void>.delayed(const Duration(seconds: 3));

  final samples = barnard.getRssiSamples(limit: 10);
  print("samples(last10)=${samples.length}");

  await barnard.stopAuto();
  await barnard.dispose();
  await sub.cancel();
}
