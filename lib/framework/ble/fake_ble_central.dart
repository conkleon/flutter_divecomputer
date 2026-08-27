import 'dart:async';
import 'dart:typed_data';

import 'ble_central.dart';
import '../../types/ble_scan_result.dart';

/// In-memory [BleCentral] for tests — no real Bluetooth radio or platform
/// channel involved.
class FakeBleCentral implements BleCentral {
  final _scanController = StreamController<BleScanResult>.broadcast();
  final Map<String, FakeBleConnection> connections = {};

  /// Services handed to the [FakeBleConnection] created for a given device id
  /// on [connect]. Pre-seed this before the transport calls
  /// `discoverServices()`.
  final Map<String, List<BleGattService>> servicesForDevice = {};

  int connectCallCount = 0;
  bool failNextConnect = false;

  /// Applied to every [FakeBleConnection] this central hands out.
  bool failDiscoverServices = false;

  void emitScanResult(BleScanResult result) => _scanController.add(result);

  @override
  Stream<BleScanResult> scan() => _scanController.stream;

  @override
  Future<void> stopScan() async {}

  @override
  Future<BleConnection> connect(BleScanResult device) async {
    connectCallCount++;
    if (failNextConnect) {
      failNextConnect = false;
      throw Exception('simulated connect failure');
    }
    final connection = FakeBleConnection(device.id)
      ..servicesToReturn = servicesForDevice[device.id] ?? []
      ..failDiscoverServices = failDiscoverServices;
    connections[device.id] = connection;
    return connection;
  }
}

class FakeBleConnection implements BleConnection {
  FakeBleConnection(this.deviceId);

  @override
  final String deviceId;

  final _connectionState = StreamController<bool>.broadcast();
  final _notifications = StreamController<Uint8List>.broadcast();
  final List<List<int>> writes = [];
  List<BleGattService> servicesToReturn = [];

  /// Artificial latency applied to [write], so tests can queue more outbound
  /// data while a write is still in flight.
  Duration writeDelay = Duration.zero;

  /// Number of [write] calls that have started but not yet completed. A value
  /// greater than 1 means the transport issued concurrent GATT writes.
  int concurrentWrites = 0;
  int maxConcurrentWrites = 0;

  void emitNotification(Uint8List bytes) => _notifications.add(bytes);
  void simulateDisconnect() => _connectionState.add(false);

  @override
  Stream<bool> get connectionState => _connectionState.stream;

  /// When true, [discoverServices] throws instead of returning.
  bool failDiscoverServices = false;
  int disconnectCallCount = 0;

  @override
  Future<List<BleGattService>> discoverServices() async {
    if (failDiscoverServices) {
      throw Exception('simulated discoverServices failure');
    }
    return servicesToReturn;
  }

  @override
  Future<void> write(String serviceUuid, String characteristicUuid,
      List<int> bytes, {required bool withResponse}) async {
    writes.add(bytes);
    concurrentWrites++;
    if (concurrentWrites > maxConcurrentWrites) {
      maxConcurrentWrites = concurrentWrites;
    }
    try {
      if (writeDelay > Duration.zero) await Future.delayed(writeDelay);
    } finally {
      concurrentWrites--;
    }
  }

  @override
  Stream<Uint8List> subscribeNotifications(
          String serviceUuid, String characteristicUuid) =>
      _notifications.stream;

  @override
  Future<void> disconnect() async {
    disconnectCallCount++;
    _connectionState.add(false);
  }
}
