import "dart:async";
import "dart:convert";

import "../../domain/capabilities.dart";
import "../../domain/config.dart";
import "../../domain/events.dart";
import "../../domain/rssi.dart";
import "../../domain/state.dart";
import "../../domain/transport.dart";
import "../../usecase/barnard_client.dart";
import "package:flutter/services.dart";

class BarnardBleClient implements BarnardClient {
  BarnardBleClient._({
    required BarnardCapabilities capabilities,
    required BarnardState initialState,
  })  : _capabilities = capabilities,
        _state = initialState;

  static const MethodChannel _methods = MethodChannel("barnard/methods");
  static const EventChannel _eventsChannel = EventChannel("barnard/events");
  static const EventChannel _debugEventsChannel = EventChannel("barnard/debugEvents");

  final StreamController<BarnardEvent> _eventsController = StreamController<BarnardEvent>.broadcast();
  final StreamController<BarnardDebugEvent> _debugEventsController = StreamController<BarnardDebugEvent>.broadcast();

  late final StreamSubscription<dynamic> _eventsSub;
  late final StreamSubscription<dynamic> _debugEventsSub;

  final _BoundedBuffer<BarnardDebugEvent> _debugBuffer = _BoundedBuffer<BarnardDebugEvent>(2000);
  final _BoundedBuffer<RssiSample> _rssiBuffer = _BoundedBuffer<RssiSample>(const RssiConfig().bufferMaxSamples);

  final BarnardCapabilities _capabilities;
  BarnardState _state;
  bool _disposed = false;

  static Future<BarnardBleClient> create() async {
    final Map<Object?, Object?> capsMap =
        (await _methods.invokeMethod<Map<Object?, Object?>>("getCapabilities")) ?? <Object?, Object?>{};
    final Map<Object?, Object?> stateMap =
        (await _methods.invokeMethod<Map<Object?, Object?>>("getState")) ?? <Object?, Object?>{};

    final BarnardBleClient client = BarnardBleClient._(
      capabilities: _parseCapabilities(capsMap),
      initialState: _parseState(stateMap),
    );
    await client._attachStreams();
    return client;
  }

  Future<void> _attachStreams() async {
    _eventsSub = _eventsChannel.receiveBroadcastStream().listen((dynamic data) {
      final BarnardEvent event = _parseBarnardEvent(_expectMap(data));
      if (event is StateEvent) _state = event.state;
      if (event is DetectionEvent) {
        _rssiBuffer.add(RssiSample(timestamp: event.timestamp, rpid: event.rpid, rssi: event.rssi, transport: event.transport));
      }
      _eventsController.add(event);
    });

    _debugEventsSub = _debugEventsChannel.receiveBroadcastStream().listen((dynamic data) {
      final BarnardDebugEvent event = _parseDebugEvent(_expectMap(data));
      _debugBuffer.add(event);
      _debugEventsController.add(event);
    });
  }

  @override
  BarnardCapabilities get capabilities => _capabilities;

  @override
  BarnardState get state => _state;

  @override
  Stream<BarnardEvent> get events => _eventsController.stream;

  @override
  Stream<BarnardDebugEvent> get debugEvents => _debugEventsController.stream;

  @override
  Future<void> startScan([ScanConfig? config]) async {
    _ensureNotDisposed();
    await _methods.invokeMethod<void>("startScan", _encodeScanConfig(config));
  }

  @override
  Future<void> stopScan() async {
    _ensureNotDisposed();
    await _methods.invokeMethod<void>("stopScan");
  }

  @override
  Future<void> startAdvertise([AdvertiseConfig? config]) async {
    _ensureNotDisposed();
    await _methods.invokeMethod<void>("startAdvertise", _encodeAdvertiseConfig(config));
  }

  @override
  Future<void> stopAdvertise() async {
    _ensureNotDisposed();
    await _methods.invokeMethod<void>("stopAdvertise");
  }

  @override
  Future<BarnardStartResult> startAuto([AutoConfig? config]) async {
    _ensureNotDisposed();
    final Map<Object?, Object?>? out =
        await _methods.invokeMethod<Map<Object?, Object?>>("startAuto", _encodeAutoConfig(config));
    if (out == null) {
      return const BarnardStartResult(scanningStarted: false, advertisingStarted: false, issues: <BarnardIssue>[]);
    }
    return _parseStartResult(out);
  }

  @override
  Future<void> stopAuto() async {
    _ensureNotDisposed();
    await _methods.invokeMethod<void>("stopAuto");
  }

  @override
  List<BarnardDebugEvent> getDebugBuffer({int? limit}) => _debugBuffer.toList(limit: limit);

  @override
  List<RssiSample> getRssiSamples({
    DateTime? since,
    int? limit,
    List<int>? rpidBytes,
  }) {
    final Uint8List? filterRpid = rpidBytes == null ? null : Uint8List.fromList(rpidBytes);
    Iterable<RssiSample> samples = _rssiBuffer.toList();
    if (since != null) {
      samples = samples.where((RssiSample s) => !s.timestamp.isBefore(since));
    }
    if (filterRpid != null) {
      samples = samples.where((RssiSample s) => _bytesEqual(s.rpid, filterRpid));
    }
    final List<RssiSample> out = samples.toList(growable: false);
    if (limit == null) return out;
    if (limit <= 0) return const <RssiSample>[];
    if (out.length <= limit) return out;
    return out.sublist(out.length - limit);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventsSub.cancel();
    await _debugEventsSub.cancel();
    await _eventsController.close();
    await _debugEventsController.close();
    await _methods.invokeMethod<void>("dispose");
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError("BarnardBleClient is disposed");
  }
}

Map<String, Object?> _encodeScanConfig(ScanConfig? config) => <String, Object?>{
      "transport": (config?.transport ?? TransportKind.ble).name,
      "allowDuplicates": config?.allowDuplicates ?? const ScanConfig().allowDuplicates,
    };

Map<String, Object?> _encodeAdvertiseConfig(AdvertiseConfig? config) => <String, Object?>{
      "transport": (config?.transport ?? TransportKind.ble).name,
      "formatVersion": config?.formatVersion ?? const AdvertiseConfig().formatVersion,
    };

Map<String, Object?> _encodeAutoConfig(AutoConfig? config) => <String, Object?>{
      "scan": _encodeScanConfig(config?.scan),
      "advertise": _encodeAdvertiseConfig(config?.advertise),
    };

BarnardStartResult _parseStartResult(Map<Object?, Object?> map) {
  final bool scanningStarted = map["scanningStarted"] == true;
  final bool advertisingStarted = map["advertisingStarted"] == true;
  final List<BarnardIssue> issues = <BarnardIssue>[];
  final Object? rawIssues = map["issues"];
  if (rawIssues is List) {
    for (final Object? item in rawIssues) {
      if (item is! Map) continue;
      final String? severity = item["severity"] as String?;
      final BarnardIssueSeverity sev = switch (severity) {
        "info" => BarnardIssueSeverity.info,
        "warn" => BarnardIssueSeverity.warn,
        _ => BarnardIssueSeverity.error,
      };
      final String code = (item["code"] as String?) ?? "unknown";
      final String? message = item["message"] as String?;
      issues.add(BarnardIssue(severity: sev, code: code, message: message));
    }
  }
  return BarnardStartResult(scanningStarted: scanningStarted, advertisingStarted: advertisingStarted, issues: issues);
}

BarnardCapabilities _parseCapabilities(Map<Object?, Object?> map) {
  final Object? raw = map["supportedTransports"];
  final List<Object?> transports = raw is List ? raw : const <Object?>["ble"];
  final Set<TransportKind> supportedTransports = transports
      .whereType<String>()
      .map((String s) => TransportKind.values.firstWhere((e) => e.name == s, orElse: () => TransportKind.unknown))
      .toSet();

  return BarnardCapabilities(
    supportedTransports: supportedTransports.isEmpty ? <TransportKind>{TransportKind.ble} : supportedTransports,
    supportsConnectionlessRpid: map["supportsConnectionlessRpid"] == true,
    supportsGattFallback: map["supportsGattFallback"] == true,
    supportsBackground: map["supportsBackground"] == true,
    supportsHighRateRssi: map["supportsHighRateRssi"] == true,
  );
}

BarnardState _parseState(Map<Object?, Object?> map) {
  final bool isScanning = map["isScanning"] == true;
  final bool isAdvertising = map["isAdvertising"] == true;
  return BarnardState(isScanning: isScanning, isAdvertising: isAdvertising);
}

BarnardEvent _parseBarnardEvent(Map<Object?, Object?> map) {
  final String? type = map["type"] as String?;
  final DateTime ts = DateTime.parse((map["timestamp"] as String?) ?? DateTime.now().toIso8601String());
  switch (type) {
    case "state":
      final Map<Object?, Object?> state = _expectMap(map["state"]);
      return StateEvent(
        timestamp: ts,
        state: BarnardState(isScanning: state["isScanning"] == true, isAdvertising: state["isAdvertising"] == true),
        reasonCode: map["reasonCode"] as String?,
      );
    case "constraint":
      return ConstraintEvent(
        timestamp: ts,
        code: (map["code"] as String?) ?? "unknown",
        message: map["message"] as String?,
        requiredAction: map["requiredAction"] as String?,
      );
    case "error":
      return ErrorEvent(
        timestamp: ts,
        code: (map["code"] as String?) ?? "unknown",
        message: (map["message"] as String?) ?? "unknown",
        recoverable: map["recoverable"] as bool?,
      );
    case "detection":
    default:
      final TransportKind transport = TransportKind.values.firstWhere(
        (e) => e.name == (map["transport"] as String?),
        orElse: () => TransportKind.unknown,
      );
      final Uint8List rpid = Uint8List.fromList(base64Decode((map["rpid"] as String?) ?? ""));
      final String displayId = (map["displayId"] as String?) ?? "";
      final int rssi = (map["rssi"] as int?) ?? 0;
      final int formatVersion = (map["formatVersion"] as int?) ?? 0;
      final String? payloadRawB64 = map["payloadRaw"] as String?;
      final Uint8List? payloadRaw = payloadRawB64 == null ? null : Uint8List.fromList(base64Decode(payloadRawB64));

      final Map<Object?, Object?>? summaryMap = map["rssiSummary"] is Map ? map["rssiSummary"] as Map<Object?, Object?> : null;
      final RssiSummary? summary = summaryMap == null
          ? null
          : RssiSummary(
              count: (summaryMap["count"] as int?) ?? 0,
              min: (summaryMap["min"] as int?) ?? 0,
              max: (summaryMap["max"] as int?) ?? 0,
              mean: (summaryMap["mean"] as num?)?.toDouble() ?? 0.0,
            );

      return DetectionEvent(
        timestamp: ts,
        rpid: rpid,
        rssi: rssi,
        transport: transport,
        formatVersion: formatVersion,
        displayId: displayId,
        rssiSummary: summary,
        payloadRaw: payloadRaw,
      );
  }
}

BarnardDebugEvent _parseDebugEvent(Map<Object?, Object?> map) {
  final DateTime ts = DateTime.parse((map["timestamp"] as String?) ?? DateTime.now().toIso8601String());
  final String? levelStr = map["level"] as String?;
  final DebugLevel level = switch (levelStr) {
    "trace" => DebugLevel.trace,
    "warn" => DebugLevel.warn,
    "error" => DebugLevel.error,
    _ => DebugLevel.info,
  };
  final String name = (map["name"] as String?) ?? "debug";
  final Map<Object?, Object?>? rawData = map["data"] is Map ? map["data"] as Map<Object?, Object?> : null;
  final Map<String, Object?>? data = rawData?.map((k, v) => MapEntry(k.toString(), v));
  return DebugEvent(timestamp: ts, level: level, name: name, data: data);
}

Map<Object?, Object?> _expectMap(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return Map<Object?, Object?>.from(value);
  throw FormatException("Expected map, got ${value.runtimeType}");
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _BoundedBuffer<T> {
  _BoundedBuffer(this._cap) : _items = <T>[];

  final int _cap;
  final List<T> _items;

  void add(T item) {
    _items.add(item);
    final int overflow = _items.length - _cap;
    if (overflow > 0) {
      _items.removeRange(0, overflow);
    }
  }

  List<T> toList({int? limit}) {
    if (limit == null) return List<T>.unmodifiable(_items);
    if (limit <= 0) return List<T>.empty(growable: false);
    if (_items.length <= limit) return List<T>.unmodifiable(_items);
    return List<T>.unmodifiable(_items.sublist(_items.length - limit));
  }
}
