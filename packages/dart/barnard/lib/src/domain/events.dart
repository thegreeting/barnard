import "dart:typed_data";

import "package:meta/meta.dart";

import "rssi.dart";
import "state.dart";
import "transport.dart";

@immutable
sealed class BarnardEvent {
  const BarnardEvent(this.timestamp);

  final DateTime timestamp;
}

final class DetectionEvent extends BarnardEvent {
  const DetectionEvent({
    required DateTime timestamp,
    required this.rpid,
    required this.rssi,
    required this.transport,
    required this.formatVersion,
    required this.displayId,
    this.rssiSummary,
    this.payloadRaw,
  }) : super(timestamp);

  final Uint8List rpid;
  final int rssi;
  final TransportKind transport;
  final int formatVersion;

  /// Short debug-only identifier derived from RPID (must not be persistent).
  final String displayId;

  /// Optional aggregation summary for push streams.
  final RssiSummary? rssiSummary;

  /// Optional raw payload bytes as observed (if available).
  final Uint8List? payloadRaw;
}

final class StateEvent extends BarnardEvent {
  const StateEvent({
    required DateTime timestamp,
    required this.state,
    this.reasonCode,
  }) : super(timestamp);

  final BarnardState state;
  final String? reasonCode;
}

final class ConstraintEvent extends BarnardEvent {
  const ConstraintEvent({
    required DateTime timestamp,
    required this.code,
    this.message,
    this.requiredAction,
  }) : super(timestamp);

  final String code;
  final String? message;
  final String? requiredAction;
}

final class ErrorEvent extends BarnardEvent {
  const ErrorEvent({
    required DateTime timestamp,
    required this.code,
    required this.message,
    this.recoverable,
  }) : super(timestamp);

  final String code;
  final String message;
  final bool? recoverable;
}

@immutable
sealed class BarnardDebugEvent {
  const BarnardDebugEvent({
    required this.timestamp,
    required this.level,
    required this.name,
    this.data,
  });

  final DateTime timestamp;
  final DebugLevel level;
  final String name;
  final Map<String, Object?>? data;
}

enum DebugLevel { trace, info, warn, error }

final class DebugEvent extends BarnardDebugEvent {
  const DebugEvent({
    required DateTime timestamp,
    required DebugLevel level,
    required String name,
    Map<String, Object?>? data,
  }) : super(timestamp: timestamp, level: level, name: name, data: data);
}
