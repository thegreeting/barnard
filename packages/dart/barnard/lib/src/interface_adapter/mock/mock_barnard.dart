import "dart:async";
import "dart:convert";
import "dart:math";
import "dart:typed_data";

import "../../usecase/barnard_client.dart";
import "../../domain/capabilities.dart";
import "../../domain/config.dart";
import "../../domain/events.dart";
import "../../domain/rssi.dart";
import "../../domain/state.dart";
import "../../domain/transport.dart";
import "mock_peer.dart";
import "ring_buffer.dart";

class MockBarnardOverrides {
  const MockBarnardOverrides({
    this.rotationSeconds,
    this.minPushIntervalMs,
    this.bufferMaxSamples,
  });

  final int? rotationSeconds;
  final int? minPushIntervalMs;
  final int? bufferMaxSamples;
}

class MockBarnard implements BarnardClient {
  MockBarnard({
    int simulatedPeerCount = 50,
    int tickMs = 200,
    MockBarnardOverrides? overrides,
  })  : _tickMs = tickMs.clamp(50, 2000),
        _random = Random(),
        _overrides = overrides {
    _peers = List<MockPeer>.generate(simulatedPeerCount.clamp(1, 2000), (int i) {
      final int seed = _random.nextInt(1 << 31);
      return MockPeer(id: i, seed: seed, transport: TransportKind.ble);
    });

    _state = BarnardState.idle;
    _events = StreamController<BarnardEvent>.broadcast();
    _debugEvents = StreamController<BarnardDebugEvent>.broadcast();
    _debugBuffer = RingBuffer<BarnardDebugEvent>(2000);

    final int bufferMaxSamples = _overrides?.bufferMaxSamples ?? const RssiConfig().bufferMaxSamples;
    _rssiBuffer = RingBuffer<RssiSample>(bufferMaxSamples);
  }

  final int _tickMs;
  final Random _random;
  final MockBarnardOverrides? _overrides;

  late final List<MockPeer> _peers;

  late BarnardState _state;
  late final StreamController<BarnardEvent> _events;
  late final StreamController<BarnardDebugEvent> _debugEvents;

  late final RingBuffer<BarnardDebugEvent> _debugBuffer;
  late final RingBuffer<RssiSample> _rssiBuffer;

  Timer? _timer;
  bool _disposed = false;

  final Map<String, _RssiAgg> _aggByRpidKey = <String, _RssiAgg>{};
  int? _lastWindowIndex;

  int get _maxAggEntries => max(2000, min(10000, _peers.length * 3));

  @override
  BarnardCapabilities get capabilities => const BarnardCapabilities(
        supportedTransports: {TransportKind.ble},
        supportsConnectionlessRpid: true,
        supportsGattFallback: false,
        supportsBackground: false,
        supportsHighRateRssi: true,
      );

  @override
  BarnardState get state => _state;

  @override
  Stream<BarnardEvent> get events => _events.stream;

  @override
  Stream<BarnardDebugEvent> get debugEvents => _debugEvents.stream;

  @override
  Future<void> startScan([ScanConfig? config]) async {
    _ensureNotDisposed();
    if (_state.isScanning) return;
    _setState(BarnardState(isScanning: true, isAdvertising: _state.isAdvertising), reasonCode: "scan_start");
    _ensureTicker();
  }

  @override
  Future<void> stopScan() async {
    _ensureNotDisposed();
    if (!_state.isScanning) return;
    _setState(BarnardState(isScanning: false, isAdvertising: _state.isAdvertising), reasonCode: "scan_stop");
    _clearAggregation();
    _maybeStopTicker();
  }

  @override
  Future<void> startAdvertise([AdvertiseConfig? config]) async {
    _ensureNotDisposed();
    if (_state.isAdvertising) return;
    _setState(BarnardState(isScanning: _state.isScanning, isAdvertising: true), reasonCode: "advertise_start");
    _ensureTicker();
  }

  @override
  Future<void> stopAdvertise() async {
    _ensureNotDisposed();
    if (!_state.isAdvertising) return;
    _setState(BarnardState(isScanning: _state.isScanning, isAdvertising: false), reasonCode: "advertise_stop");
    _maybeStopTicker();
  }

  @override
  Future<BarnardStartResult> startAuto([AutoConfig? config]) async {
    _ensureNotDisposed();
    final bool wasScanning = _state.isScanning;
    final bool wasAdvertising = _state.isAdvertising;

    await startScan(config?.scan);
    await startAdvertise(config?.advertise);

    return BarnardStartResult(
      scanningStarted: !wasScanning && _state.isScanning,
      advertisingStarted: !wasAdvertising && _state.isAdvertising,
      issues: const <BarnardIssue>[],
    );
  }

  @override
  Future<void> stopAuto() async {
    _ensureNotDisposed();
    await stopScan();
    await stopAdvertise();
  }

  @override
  List<BarnardDebugEvent> getDebugBuffer({int? limit}) => _debugBuffer.toList(limit: limit);

  @override
  List<RssiSample> getRssiSamples({
    DateTime? since,
    int? limit,
    List<int>? rpidBytes,
  }) {
    final List<RssiSample> all = _rssiBuffer.toList();
    final Uint8List? filterRpid = rpidBytes == null ? null : Uint8List.fromList(rpidBytes);

    Iterable<RssiSample> filtered = all;
    if (since != null) {
      filtered = filtered.where((RssiSample s) => !s.timestamp.isBefore(since));
    }
    if (filterRpid != null) {
      filtered = filtered.where((RssiSample s) => _bytesEqual(s.rpid, filterRpid));
    }

    final List<RssiSample> out = filtered.toList(growable: false);
    if (limit == null) return out;
    if (limit <= 0) return const <RssiSample>[];
    if (out.length <= limit) return out;
    return out.sublist(out.length - limit);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _clearAggregation();
    await _events.close();
    await _debugEvents.close();
  }

  void _ensureTicker() {
    _timer ??= Timer.periodic(Duration(milliseconds: _tickMs), (_) => _tick());
  }

  void _maybeStopTicker() {
    if (_state.isScanning || _state.isAdvertising) return;
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    if (_disposed) return;
    if (!_state.isScanning) return;

    final DateTime now = DateTime.now();
    final int rotationSeconds = _clampRotationSeconds();
    final int windowIndex = (now.millisecondsSinceEpoch ~/ 1000) ~/ rotationSeconds;
    if (_lastWindowIndex != windowIndex) {
      _lastWindowIndex = windowIndex;
      _clearAggregation();
      _emitDebug(DebugLevel.info, "mock_rotation_window", <String, Object?>{
        "windowIndex": windowIndex,
        "rotationSeconds": rotationSeconds,
      });
    }

    final int hits = 1 + _random.nextInt(5);
    for (int i = 0; i < hits; i++) {
      final MockPeer peer = _peers[_random.nextInt(_peers.length)];
      final Uint8List rpid = peer.rpidForWindow(windowIndex);
      final int rssi = peer.nextRssi();

      _rssiBuffer.add(RssiSample(timestamp: now, rpid: rpid, rssi: rssi, transport: peer.transport));
      _accumulateAndMaybeEmit(now: now, peer: peer, rpid: rpid, rssi: rssi);
    }
  }

  void _accumulateAndMaybeEmit({
    required DateTime now,
    required MockPeer peer,
    required Uint8List rpid,
    required int rssi,
  }) {
    final String key = _rpidKey(rpid);
    final _RssiAgg agg = _aggByRpidKey.putIfAbsent(key, () => _RssiAgg());
    agg.add(rssi, now: now);
    _evictAggIfNeeded(now);

    final int minIntervalMs = (_overrides?.minPushIntervalMs ?? const RssiConfig().minPushIntervalMs).clamp(50, 60 * 1000);
    if (agg.lastEmitAt != null && now.difference(agg.lastEmitAt!).inMilliseconds < minIntervalMs) {
      return;
    }

    final RssiSummary summary = agg.toSummary();
    agg.resetAfterEmit(now);

    final DetectionEvent event = DetectionEvent(
      timestamp: now,
      rpid: rpid,
      rssi: rssi,
      transport: peer.transport,
      formatVersion: 1,
      displayId: _displayId(rpid),
      rssiSummary: summary,
      payloadRaw: null,
    );

    _events.add(event);
    _emitDebug(DebugLevel.trace, "mock_detection", <String, Object?>{
      "displayId": event.displayId,
      "rssi": rssi,
      "count": summary.count,
      "min": summary.min,
      "max": summary.max,
      "mean": summary.mean,
    });
  }

  void _setState(BarnardState next, {required String reasonCode}) {
    _state = next;
    final DateTime now = DateTime.now();
    _events.add(StateEvent(timestamp: now, state: next, reasonCode: reasonCode));
    _emitDebug(DebugLevel.info, "state", <String, Object?>{
      "isScanning": next.isScanning,
      "isAdvertising": next.isAdvertising,
      "reason": reasonCode,
    });
  }

  void _emitDebug(DebugLevel level, String name, Map<String, Object?> data) {
    final DebugEvent e = DebugEvent(timestamp: DateTime.now(), level: level, name: name, data: data);
    _debugBuffer.add(e);
    _debugEvents.add(e);
  }

  void _clearAggregation() {
    _aggByRpidKey.clear();
  }

  void _evictAggIfNeeded(DateTime now) {
    if (_aggByRpidKey.length <= _maxAggEntries) return;

    // Evict the least-recently-seen entries to keep the mock bounded.
    // This is O(n) but only triggers when the map exceeds the cap.
    final List<MapEntry<String, _RssiAgg>> entries = _aggByRpidKey.entries.toList(growable: false);
    entries.sort((a, b) {
      final DateTime aSeen = a.value.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime bSeen = b.value.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aSeen.compareTo(bSeen);
    });

    final int target = _maxAggEntries;
    final int removeCount = _aggByRpidKey.length - target;
    for (int i = 0; i < removeCount; i++) {
      _aggByRpidKey.remove(entries[i].key);
    }

    _emitDebug(DebugLevel.warn, "mock_agg_eviction", <String, Object?>{
      "removed": removeCount,
      "cap": target,
    });
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError("MockBarnard is disposed");
  }

  int _clampRotationSeconds() {
    final int rotationSeconds = _overrides?.rotationSeconds ?? const RpidConfig().rotationSeconds;
    return rotationSeconds.clamp(const RpidConfig().minRotationSeconds, const RpidConfig().maxRotationSeconds);
  }

  static String _displayId(Uint8List rpid) {
    final int take = min(4, rpid.length);
    final String hex = rpid.sublist(0, take).map((int b) => b.toRadixString(16).padLeft(2, "0")).join();
    return hex;
  }

  static String _rpidKey(Uint8List rpid) => base64UrlEncode(rpid);

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _RssiAgg {
  int _count = 0;
  int _min = 0;
  int _max = 0;
  int _sum = 0;
  DateTime? lastEmitAt;
  DateTime? lastSeenAt;

  void add(int rssi, {required DateTime now}) {
    if (_count == 0) {
      _min = rssi;
      _max = rssi;
    } else {
      if (rssi < _min) _min = rssi;
      if (rssi > _max) _max = rssi;
    }
    _count += 1;
    _sum += rssi;
    lastSeenAt = now;
  }

  RssiSummary toSummary() {
    final double mean = _count == 0 ? 0.0 : _sum / _count;
    return RssiSummary(count: _count, min: _min, max: _max, mean: mean);
  }

  void resetAfterEmit(DateTime emittedAt) {
    _count = 0;
    _min = 0;
    _max = 0;
    _sum = 0;
    lastEmitAt = emittedAt;
  }
}
