import "transport.dart";

class BarnardConfig {
  const BarnardConfig({
    this.transport = TransportKind.ble,
    this.rpid = const RpidConfig(),
    this.rssi = const RssiConfig(),
    this.connect = const ConnectConfig(),
  });

  final TransportKind transport;
  final RpidConfig rpid;
  final RssiConfig rssi;
  final ConnectConfig connect;
}

class ScanConfig {
  const ScanConfig({
    this.transport = TransportKind.ble,
    this.allowDuplicates = true,
  });

  final TransportKind transport;

  /// If true, the implementation may emit repeated observations for the same
  /// sender, which is useful for RSSI time-series. Implementations should still
  /// apply sampling/aggregation to remain stable.
  final bool allowDuplicates;
}

class AdvertiseConfig {
  const AdvertiseConfig({
    this.transport = TransportKind.ble,
    this.formatVersion = 1,
  });

  final TransportKind transport;
  final int formatVersion;
}

class AutoConfig {
  const AutoConfig({
    this.scan = const ScanConfig(),
    this.advertise = const AdvertiseConfig(),
  });

  final ScanConfig scan;
  final AdvertiseConfig advertise;
}

class RpidConfig {
  const RpidConfig({
    this.rotationSeconds = 600,
    this.minRotationSeconds = 60,
    this.maxRotationSeconds = 3600,
    this.epochOffsetSeconds,
  });

  final int rotationSeconds;
  final int minRotationSeconds;
  final int maxRotationSeconds;

  /// Optional per-device epoch offset to avoid synchronizing rotation boundaries.
  /// If null, the implementation may choose its own offset.
  final int? epochOffsetSeconds;
}

class RssiConfig {
  const RssiConfig({
    this.minPushIntervalMs = 1000,
    this.bufferMaxSamples = 20000,
  });

  /// Minimum interval for push events per `rpid`. Implementations may aggregate
  /// observations during the interval.
  final int minPushIntervalMs;

  /// Max number of RSSI samples to retain in memory (ring buffer).
  final int bufferMaxSamples;
}

class ConnectConfig {
  const ConnectConfig({
    this.enableGattFallback = false,
    this.maxConcurrentConnections = 1,
    this.cooldownPerPeerSeconds = 30,
    this.connectBudgetPerMinute = 30,
    this.maxConnectQueue = 20,
  });

  /// Optional fallback path. This should default to off for high-density
  /// environments.
  final bool enableGattFallback;

  final int maxConcurrentConnections;
  final int cooldownPerPeerSeconds;
  final int connectBudgetPerMinute;
  final int maxConnectQueue;
}
