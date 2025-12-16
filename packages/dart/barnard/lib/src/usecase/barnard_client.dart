import "../domain/rssi.dart";
import "../domain/capabilities.dart";
import "../domain/config.dart";
import "../domain/events.dart";
import "../domain/state.dart";

class BarnardStartResult {
  const BarnardStartResult({
    required this.scanningStarted,
    required this.advertisingStarted,
    required this.issues,
  });

  final bool scanningStarted;
  final bool advertisingStarted;
  final List<BarnardIssue> issues;
}

class BarnardIssue {
  const BarnardIssue({
    required this.severity,
    required this.code,
    this.message,
  });

  final BarnardIssueSeverity severity;
  final String code;
  final String? message;
}

enum BarnardIssueSeverity { info, warn, error }

abstract class BarnardClient {
  BarnardCapabilities get capabilities;
  BarnardState get state;

  Stream<BarnardEvent> get events;
  Stream<BarnardDebugEvent> get debugEvents;

  Future<void> startScan([ScanConfig? config]);
  Future<void> stopScan();

  Future<void> startAdvertise([AdvertiseConfig? config]);
  Future<void> stopAdvertise();

  /// Starts Scan + Advertise concurrently.
  ///
  /// Implementations should represent partial success via events and/or the
  /// returned result.
  Future<BarnardStartResult> startAuto([AutoConfig? config]);
  Future<void> stopAuto();

  /// Pull: read the in-memory debug buffer snapshot.
  List<BarnardDebugEvent> getDebugBuffer({int? limit});

  /// Pull: read RSSI time-series samples from the in-memory buffer.
  List<RssiSample> getRssiSamples({
    DateTime? since,
    int? limit,
    List<int>? rpidBytes,
  });

  Future<void> dispose();
}
