import 'dart:async';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';

import '../../types/ble_profile.dart';
import '../../types/ble_scan_result.dart';

class BleGattService {
  BleGattService(this.uuid, this.characteristicUuids);
  final String uuid;
  final List<String> characteristicUuids;
}

abstract class BleConnection {
  String get deviceId;
  Stream<bool> get connectionState;
  Future<List<BleGattService>> discoverServices();
  Future<void> write(String serviceUuid, String characteristicUuid,
      List<int> bytes, {required bool withResponse});
  Stream<Uint8List> subscribeNotifications(
      String serviceUuid, String characteristicUuid);
  Future<void> disconnect();
}

abstract class BleCentral {
  Stream<BleScanResult> scan();
  Future<void> stopScan();
  Future<BleConnection> connect(BleScanResult device);
}

class UniversalBleCentral implements BleCentral {
  // universal_ble hands out BleDevice objects from scan results; we keep a
  // lookup of devices seen during the current scan and resolve connect()
  // against it.
  final Map<String, BleDevice> _seen = {};

  @override
  Stream<BleScanResult> scan() {
    final controller = StreamController<BleScanResult>();
    UniversalBle.onScanResult = (device) {
      // Results can still arrive after the stream was cancelled/closed;
      // add()ing to a closed controller throws StateError.
      if (controller.isClosed) return;
      _seen[device.deviceId] = device;
      final profile = BleProfiles.match(device.name ?? '');
      if (profile == null) return; // only surface recognized devices
      controller.add(BleScanResult(
        id: device.deviceId,
        name: device.name ?? '',
        rssi: device.rssi ?? 0,
        profile: profile,
      ));
    };
    UniversalBle.startScan();
    controller.onCancel = () async {
      // onScanResult is a global static — clear it so a stale handler cannot
      // outlive this scan (or clobber a subsequent one).
      UniversalBle.onScanResult = null;
      _seen.clear();
      await UniversalBle.stopScan();
    };
    return controller.stream;
  }

  @override
  Future<void> stopScan() => UniversalBle.stopScan();

  @override
  Future<BleConnection> connect(BleScanResult device) async {
    final bleDevice = _seen[device.id];
    if (bleDevice == null) {
      throw StateError(
          'No scanned device with id ${device.id} — connect() must be '
          'called with a BleScanResult from an active/recent scan() call.');
    }
    await bleDevice.connect();
    return _UniversalBleConnection(bleDevice);
  }
}

class _UniversalBleConnection implements BleConnection {
  _UniversalBleConnection(this._device);
  final BleDevice _device;

  @override
  String get deviceId => _device.deviceId;

  @override
  Stream<bool> get connectionState => _device.connectionStream;

  @override
  Future<List<BleGattService>> discoverServices() async {
    final services = await _device.discoverServices();
    return [
      for (final s in services)
        BleGattService(s.uuid, [for (final c in s.characteristics) c.uuid]),
    ];
  }

  @override
  Future<void> write(String serviceUuid, String characteristicUuid,
      List<int> bytes, {required bool withResponse}) async {
    final characteristic = await _device.getCharacteristic(
      characteristicUuid,
      service: serviceUuid,
    );
    await characteristic.write(bytes, withResponse: withResponse);
  }

  @override
  Stream<Uint8List> subscribeNotifications(
      String serviceUuid, String characteristicUuid) {
    final controller = StreamController<Uint8List>();
    _device
        .getCharacteristic(characteristicUuid, service: serviceUuid)
        .then((characteristic) {
      final sub = characteristic.onValueReceived.listen(controller.add);
      characteristic.notifications.subscribe();
      controller.onCancel = () {
        sub.cancel();
        characteristic.notifications.unsubscribe();
      };
    }, onError: controller.addError);
    return controller.stream;
  }

  @override
  Future<void> disconnect() => _device.disconnect();
}
