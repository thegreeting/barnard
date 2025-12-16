import "dart:typed_data";

import "package:meta/meta.dart";

import "rssi.dart";
import "state.dart";
import "transport.dart";

@immutable
sealed class BarnardEvent {
  const BarnardEvent({required this.timestamp});

  final DateTime timestamp;
}

final class DetectionEvent extends BarnardEvent {
  const DetectionEvent({
    required super.timestamp,
    required this.rpid,
    required this.rssi,
    required this.transport,
    required this.formatVersion,
    required this.displayId,
    this.rssiSummary,
    this.payloadRaw,
  });

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
    required super.timestamp,
    required this.state,
    this.reasonCode,
  });

  final BarnardState state;
  final String? reasonCode;
}

final class ConstraintEvent extends BarnardEvent {
  const ConstraintEvent({
    required super.timestamp,
    required this.code,
    this.message,
    this.requiredAction,
  });

  final String code;
  final String? message;
  final String? requiredAction;
}

final class ErrorEvent extends BarnardEvent {
  const ErrorEvent({
    required super.timestamp,
    required this.code,
    required this.message,
    this.recoverable,
  });

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
    required super.timestamp,
    required super.level,
    required super.name,
    super.data,
  });
}
