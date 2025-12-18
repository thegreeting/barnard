import "dart:async";
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

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _debugSub?.cancel();
    _client?.dispose();
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
      });
    });
    _debugSub = client.debugEvents.listen((BarnardDebugEvent e) {
      if (!mounted) return;
      setState(() {
        _debugEvents.add(e);
        if (_debugEvents.length > 200) _debugEvents.removeRange(0, _debugEvents.length - 200);
      });
    });

    setState(() {
      _client = client;
      _state = client.state;
    });
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;

    final List<Permission> perms = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.locationWhenInUse,
    ];

    print("--- Requesting permissions ---");
    final Map<Permission, PermissionStatus> results = await perms.request();
    results.forEach((p, s) {
      print("${p.toString()}: $s");
    });
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
                    const Divider(),
                    Expanded(
                      child: DefaultTabController(
                        length: 2,
                        child: Column(
                          children: <Widget>[
                            const TabBar(tabs: <Tab>[Tab(text: "Events"), Tab(text: "Debug")]),
                            Expanded(
                              child: TabBarView(
                                children: <Widget>[_EventList(events: _events), _DebugList(events: _debugEvents)],
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
}

class _EventList extends StatelessWidget {
  const _EventList({required this.events});

  final List<BarnardEvent> events;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: events.length,
      itemBuilder: (BuildContext context, int index) {
        final BarnardEvent e = events[events.length - 1 - index];
        if (e is DetectionEvent) {
          return ListTile(
            dense: true,
            title: Text("detection ${e.displayId} rssi=${e.rssi}"),
            subtitle: Text("${e.timestamp.toIso8601String()} transport=${e.transport.name}"),
          );
        }
        if (e is StateEvent) {
          return ListTile(
            dense: true,
            title: Text("state scan=${e.state.isScanning} adv=${e.state.isAdvertising}"),
            subtitle: Text("${e.timestamp.toIso8601String()} reason=${e.reasonCode ?? "-"}"),
          );
        }
        if (e is ConstraintEvent) {
          return ListTile(dense: true, title: Text("constraint ${e.code}"), subtitle: Text(e.message ?? "-"));
        }
        if (e is ErrorEvent) {
          return ListTile(dense: true, title: Text("error ${e.code}"), subtitle: Text(e.message));
        }
        return ListTile(dense: true, title: Text(e.runtimeType.toString()));
      },
    );
  }
}

class _DebugList extends StatelessWidget {
  const _DebugList({required this.events});

  final List<BarnardDebugEvent> events;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: events.length,
      itemBuilder: (BuildContext context, int index) {
        final BarnardDebugEvent e = events[events.length - 1 - index];
        return ListTile(
          dense: true,
          title: Text("${e.level.name} ${e.name}"),
          subtitle: Text(e.timestamp.toIso8601String()),
        );
      },
    );
  }
}
