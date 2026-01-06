import "dart:async";
import "dart:convert";
import "dart:io";

import "package:barnard/barnard.dart";
import "package:barnard/barnard_ble.dart";
import "package:flutter/material.dart";
import "package:permission_handler/permission_handler.dart";

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  BarnardBleClient? _client;
  StreamSubscription<BarnardEvent>? _eventsSub;
  StreamSubscription<BarnardDebugEvent>? _debugSub;

  BarnardState _state = BarnardState.idle;
  final List<BarnardEvent> _events = <BarnardEvent>[];
  final List<BarnardDebugEvent> _debugEvents = <BarnardDebugEvent>[];
  final Map<String, _SeenEntry> _seenById = <String, _SeenEntry>{};
  final _SelfAdvertiseInfo _selfInfo = _SelfAdvertiseInfo();

  bool _busy = false;
  bool _eventsOnlyDetections = false;
  bool _eventsOnlyIssues = false;
  bool _debugOnlyIssues = false;
  bool _debugHideTrace = true;
  String _debugQuery = "";
  bool _diagExpanded = false;
  Timer? _uiTicker;

  static const Duration _staleAfter = Duration(seconds: 15);
  static const String _serviceUuid = "0000B001-0000-1000-8000-00805F9B34FB";
  static const String _localName = "BNRD";

  @override
  void initState() {
    super.initState();
    _init();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _debugSub?.cancel();
    _client?.dispose();
    _uiTicker?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    await _ensurePermissions();
    final BarnardBleClient client = await BarnardBleClient.create();

    _eventsSub = client.events.listen((BarnardEvent e) {
      if (!mounted) return;
      setState(() {
        _events.add(e);
        if (_events.length > 200) _events.removeRange(0, _events.length - 200);
        if (e is StateEvent) _state = e.state;
        if (e is DetectionEvent) _updateSeen(e);
      });
    });
    _debugSub = client.debugEvents.listen((BarnardDebugEvent e) {
      if (!mounted) return;
      setState(() {
        _debugEvents.add(e);
        if (_debugEvents.length > 200) _debugEvents.removeRange(0, _debugEvents.length - 200);
        _updateSelfInfo(e);
      });
    });

    setState(() {
      _client = client;
      _state = client.state;
    });
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;

    print("--- Requesting permissions ---");

    // With neverForLocation flag in manifest, only Bluetooth permissions are needed on Android 12+
    final List<Permission> perms = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ];
    final Map<Permission, PermissionStatus> results = await perms.request();
    results.forEach((p, s) => print("${p.toString()}: $s"));

    print("------------------------------");
  }

  Future<void> _run(Future<void> Function(BarnardBleClient client) action) async {
    final BarnardBleClient? client = _client;
    if (client == null) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(client);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final BarnardBleClient? client = _client;
    final int detections = _events.whereType<DetectionEvent>().length;
    final int issues = _events.where((BarnardEvent e) => e is ConstraintEvent || e is ErrorEvent).length;
    final int debugIssues = _debugEvents.where((BarnardDebugEvent e) => e.level == DebugLevel.warn || e.level == DebugLevel.error).length;
    final DateTime now = DateTime.now();
    final List<_SeenEntry> seen = _seenById.values.toList()
      ..sort((_SeenEntry a, _SeenEntry b) => b.lastSeen.compareTo(a.lastSeen));

    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text("Barnard BLE PoC (GATT-first)")),
        body:
            client == null
                ? const Center(child: CircularProgressIndicator())
                : Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          FilledButton(
                            onPressed:
                                _busy ? null : () => _run((c) => c.startScan(const ScanConfig(allowDuplicates: true))),
                            child: const Text("Start Scan"),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _run((c) => c.stopScan()),
                            child: const Text("Stop Scan"),
                          ),
                          FilledButton(
                            onPressed: _busy ? null : () => _run((c) => c.startAdvertise(const AdvertiseConfig())),
                            child: const Text("Start Advertise"),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _run((c) => c.stopAdvertise()),
                            child: const Text("Stop Advertise"),
                          ),
                          FilledButton(
                            onPressed: _busy ? null : () => _run((c) => c.startAuto(const AutoConfig())),
                            child: const Text("Start Auto"),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _run((c) => c.stopAuto()),
                            child: const Text("Stop Auto"),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: <Widget>[
                          Expanded(child: Text("State: $_state")),
                          Text("caps: ${client.capabilities.supportedTransports.map((e) => e.name).join(",")}"),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          _StatChip(label: "events", value: _events.length),
                          _StatChip(label: "detections", value: detections),
                          _StatChip(label: "issues", value: issues),
                          _StatChip(label: "debug", value: _debugEvents.length),
                          _StatChip(label: "debug issues", value: debugIssues),
                          TextButton(
                            onPressed:
                                _events.isEmpty
                                    ? null
                                    : () => setState(() => _events.clear()),
                            child: const Text("Clear Events"),
                          ),
                          TextButton(
                            onPressed:
                                _debugEvents.isEmpty
                                    ? null
                                    : () => setState(() => _debugEvents.clear()),
                            child: const Text("Clear Debug"),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Card(
                        child: ExpansionTile(
                          initiallyExpanded: _diagExpanded,
                          onExpansionChanged: (bool v) => setState(() => _diagExpanded = v),
                          title: const Text("Diagnostics"),
                          subtitle: const Text("Self advertise + recently seen"),
                          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          children: <Widget>[
                            _SelfAdvertiseCard(
                              isAdvertising: _state.isAdvertising,
                              serviceUuid: _selfInfo.serviceUuid ?? _serviceUuid,
                              localName: _selfInfo.localName ?? _localName,
                              formatVersion: _selfInfo.formatVersion ?? 1,
                              lastDisplayId: _selfInfo.lastDisplayId,
                              lastPayloadAt: _selfInfo.lastPayloadAt,
                              staleAfter: _staleAfter,
                              now: now,
                            ),
                            const SizedBox(height: 8),
                            _SeenCard(
                              seen: seen,
                              now: now,
                              staleAfter: _staleAfter,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: DefaultTabController(
                        length: 2,
                        child: Column(
                          children: <Widget>[
                            const TabBar(tabs: <Tab>[Tab(text: "Events"), Tab(text: "Debug")]),
                            Expanded(
                              child: TabBarView(
                                children: <Widget>[
                                  Column(
                                    children: <Widget>[
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        child: Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: <Widget>[
                                            FilterChip(
                                              label: const Text("Detections only"),
                                              selected: _eventsOnlyDetections,
                                              onSelected: (bool v) => setState(() => _eventsOnlyDetections = v),
                                            ),
                                            FilterChip(
                                              label: const Text("Issues only"),
                                              selected: _eventsOnlyIssues,
                                              onSelected: (bool v) => setState(() => _eventsOnlyIssues = v),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Expanded(
                                        child: _EventList(
                                          events: _events,
                                          onlyDetections: _eventsOnlyDetections,
                                          onlyIssues: _eventsOnlyIssues,
                                          seenById: _seenById,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Column(
                                    children: <Widget>[
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        child: Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          crossAxisAlignment: WrapCrossAlignment.center,
                                          children: <Widget>[
                                            FilterChip(
                                              label: const Text("Issues only"),
                                              selected: _debugOnlyIssues,
                                              onSelected: (bool v) => setState(() => _debugOnlyIssues = v),
                                            ),
                                            FilterChip(
                                              label: const Text("Hide trace"),
                                              selected: _debugHideTrace,
                                              onSelected: (bool v) => setState(() => _debugHideTrace = v),
                                            ),
                                            SizedBox(
                                              width: 220,
                                              child: TextField(
                                                decoration: const InputDecoration(
                                                  labelText: "Filter name",
                                                  isDense: true,
                                                  border: OutlineInputBorder(),
                                                ),
                                                onChanged: (String v) => setState(() => _debugQuery = v.trim()),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Expanded(
                                        child: _DebugList(
                                          events: _debugEvents,
                                          onlyIssues: _debugOnlyIssues,
                                          hideTrace: _debugHideTrace,
                                          query: _debugQuery,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
      ),
    );
  }

  void _updateSeen(DetectionEvent e) {
    final String key = base64UrlEncode(e.rpid);
    final _SeenEntry existing = _seenById[key] ?? _SeenEntry(displayId: e.displayId);
    existing.lastSeen = e.timestamp;
    existing.lastRssi = e.rssi;
    existing.displayId = e.displayId.isNotEmpty ? e.displayId : existing.displayId;
    existing.count += 1;
    _seenById[key] = existing;
    if (_seenById.length > 50) {
      final List<MapEntry<String, _SeenEntry>> entries = _seenById.entries.toList(growable: false)
        ..sort((MapEntry<String, _SeenEntry> a, MapEntry<String, _SeenEntry> b) => a.value.lastSeen.compareTo(b.value.lastSeen));
      final int removeCount = _seenById.length - 50;
      for (int i = 0; i < removeCount; i++) {
        _seenById.remove(entries[i].key);
      }
    }
  }

  void _updateSelfInfo(BarnardDebugEvent e) {
    final Map<String, Object?>? data = e.data;
    if (data == null) return;
    if (e.name == "advertise_start") {
      _selfInfo.formatVersion = _asInt(data["formatVersion"]) ?? _selfInfo.formatVersion;
      _selfInfo.serviceUuid = data["serviceUuid"] as String? ?? _selfInfo.serviceUuid;
      _selfInfo.localName = data["localName"] as String? ?? _selfInfo.localName;
    } else if (e.name == "gatt_read_rpid") {
      _selfInfo.lastDisplayId = data["displayId"] as String? ?? _selfInfo.lastDisplayId;
      _selfInfo.formatVersion = _asInt(data["formatVersion"]) ?? _selfInfo.formatVersion;
      _selfInfo.lastPayloadAt = e.timestamp;
    }
  }

  int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

class _EventList extends StatelessWidget {
  const _EventList({
    required this.events,
    required this.onlyDetections,
    required this.onlyIssues,
    required this.seenById,
  });

  final List<BarnardEvent> events;
  final bool onlyDetections;
  final bool onlyIssues;
  final Map<String, _SeenEntry> seenById;

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final List<BarnardEvent> filtered = events.where((BarnardEvent e) {
      if (onlyDetections && e is! DetectionEvent) return false;
      if (onlyIssues && e is! ConstraintEvent && e is! ErrorEvent) return false;
      return true;
    }).toList(growable: false);
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (BuildContext context, int index) {
        final BarnardEvent e = filtered[filtered.length - 1 - index];
        if (e is DetectionEvent) {
          final Duration age = now.difference(e.timestamp);
          final bool isStale = age > _MyAppState._staleAfter;
          final String rpidKey = base64UrlEncode(e.rpid);
          final _SeenEntry? latest = seenById[rpidKey];
          final bool isActive = latest != null && now.difference(latest.lastSeen) <= _MyAppState._staleAfter;
          return ListTile(
            dense: true,
            leading: const Icon(Icons.wifi_tethering, size: 18),
            title: Text(
              "detection ${e.displayId} rssi=${e.rssi} age=${age.inSeconds}s${isStale ? " STALE" : ""}${isActive ? " ACTIVE" : ""}",
            ),
            subtitle: Text("${e.timestamp.toIso8601String()} transport=${e.transport.name}"),
          );
        }
        if (e is StateEvent) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.tune, size: 18),
            title: Text("state scan=${e.state.isScanning} adv=${e.state.isAdvertising}"),
            subtitle: Text("${e.timestamp.toIso8601String()} reason=${e.reasonCode ?? "-"}"),
          );
        }
        if (e is ConstraintEvent) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.warning_amber, size: 18, color: Colors.orange),
            title: Text("constraint ${e.code}"),
            subtitle: Text(e.message ?? "-"),
          );
        }
        if (e is ErrorEvent) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.error, size: 18, color: Colors.red),
            title: Text("error ${e.code}"),
            subtitle: Text(e.message),
          );
        }
        return ListTile(dense: true, title: Text(e.runtimeType.toString()));
      },
    );
  }
}

class _DebugList extends StatelessWidget {
  const _DebugList({
    required this.events,
    required this.onlyIssues,
    required this.hideTrace,
    required this.query,
  });

  final List<BarnardDebugEvent> events;
  final bool onlyIssues;
  final bool hideTrace;
  final String query;

  @override
  Widget build(BuildContext context) {
    final String needle = query.toLowerCase();
    final List<BarnardDebugEvent> filtered = events.where((BarnardDebugEvent e) {
      if (hideTrace && e.level == DebugLevel.trace) return false;
      if (onlyIssues && e.level != DebugLevel.warn && e.level != DebugLevel.error) return false;
      if (needle.isEmpty) return true;
      return e.name.toLowerCase().contains(needle);
    }).toList(growable: false);
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (BuildContext context, int index) {
        final BarnardDebugEvent e = filtered[filtered.length - 1 - index];
        final Color? color = switch (e.level) {
          DebugLevel.error => Colors.red,
          DebugLevel.warn => Colors.orange,
          _ => null,
        };
        final String data = e.data == null ? "" : " data=${e.data}";
        return ListTile(
          dense: true,
          leading: Icon(
            e.level == DebugLevel.error
                ? Icons.error
                : e.level == DebugLevel.warn
                ? Icons.warning_amber
                : Icons.bug_report,
            size: 18,
            color: color,
          ),
          title: Text("${e.level.name} ${e.name}", style: TextStyle(color: color)),
          subtitle: Text("${e.timestamp.toIso8601String()}$data"),
        );
      },
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text("$label: $value"));
  }
}

class _SeenEntry {
  _SeenEntry({
    this.displayId = "",
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0);

  String displayId;
  DateTime lastSeen;
  int count = 0;
  int lastRssi = 0;
}

class _SelfAdvertiseInfo {
  int? formatVersion;
  String? serviceUuid;
  String? localName;
  String? lastDisplayId;
  DateTime? lastPayloadAt;
}

class _SelfAdvertiseCard extends StatelessWidget {
  const _SelfAdvertiseCard({
    required this.isAdvertising,
    required this.serviceUuid,
    required this.localName,
    required this.formatVersion,
    required this.lastDisplayId,
    required this.lastPayloadAt,
    required this.staleAfter,
    required this.now,
  });

  final bool isAdvertising;
  final String serviceUuid;
  final String localName;
  final int formatVersion;
  final String? lastDisplayId;
  final DateTime? lastPayloadAt;
  final Duration staleAfter;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final bool hasPayload = lastPayloadAt != null && lastDisplayId != null && lastDisplayId!.isNotEmpty;
    final Duration? age = hasPayload ? now.difference(lastPayloadAt!) : null;
    final bool isStale = age != null && age > staleAfter;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text("Self Advertise", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text("Advertising: ${isAdvertising ? "ON" : "OFF"}"),
            Text("Service UUID: $serviceUuid"),
            Text("Local Name: $localName"),
            Text("Format Version: $formatVersion"),
            Text(
              "Last payload: ${hasPayload ? lastDisplayId : "-"}${age == null ? "" : " age=${age.inSeconds}s${isStale ? " STALE" : ""}"}",
            ),
          ],
        ),
      ),
    );
  }
}

class _SeenCard extends StatelessWidget {
  const _SeenCard({
    required this.seen,
    required this.now,
    required this.staleAfter,
  });

  final List<_SeenEntry> seen;
  final DateTime now;
  final Duration staleAfter;

  @override
  Widget build(BuildContext context) {
    final List<_SeenEntry> top = seen.take(6).toList(growable: false);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              "Recently seen (stale > ${staleAfter.inSeconds}s)",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            if (top.isEmpty) const Text("No detections yet"),
            for (final _SeenEntry entry in top)
              Builder(builder: (BuildContext context) {
                final Duration age = now.difference(entry.lastSeen);
                final bool isStale = age > staleAfter;
                final bool isActive = !isStale;
                return Text(
                  "${entry.displayId.isEmpty ? "-" : entry.displayId} age=${age.inSeconds}s rssi=${entry.lastRssi} count=${entry.count}${isStale ? " STALE" : " ACTIVE"}",
                  style: TextStyle(color: isStale ? Colors.orange : Colors.green),
                );
              }),
          ],
        ),
      ),
    );
  }
}
