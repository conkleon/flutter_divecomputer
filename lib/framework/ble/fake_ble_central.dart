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
      ..servicesToReturn = servicesForDevice[device.id] ?? [];
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

  void emitNotification(Uint8List bytes) => _notifications.add(bytes);
  void simulateDisconnect() => _connectionState.add(false);

  @override
  Stream<bool> get connectionState => _connectionState.stream;

  @override
  Future<List<BleGattService>> discoverServices() async => servicesToReturn;

  @override
  Future<void> write(String serviceUuid, String characteristicUuid,
      List<int> bytes, {required bool withResponse}) async {
    writes.add(bytes);
  }

  @override
  Stream<Uint8List> subscribeNotifications(
          String serviceUuid, String characteristicUuid) =>
      _notifications.stream;

  @override
  Future<void> disconnect() async {
    _connectionState.add(false);
  }
}
