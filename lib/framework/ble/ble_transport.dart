import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';

import 'ble_central.dart';
import '../bridged_transport.dart';
import '../../types/ble_profile.dart';
import '../../types/ble_scan_result.dart';

final _log = Logger('BleTransport');

/// Drives BLE I/O on the main isolate on behalf of a `BleBridge` running
/// on the background isolate. Connection setup (scan, GATT discovery,
/// characteristic resolution, the connection-state watch) lives here; the
/// bridge-servicing machinery is inherited from [BridgedTransport].
class BleTransport extends BridgedTransport {
  BleTransport(this._central);

  final BleCentral _central;
  BleConnection? _connection;

  // Resolved once in connect() from the profile + discovered GATT layout;
  // non-null exactly while _connection is.
  String? _serviceUuid;
  String? _writeCharUuid;
  String? _notifyCharUuid;
  bool _writeWithResponse = false;

  StreamSubscription<bool>? _connStateSub;

  bool get isConnected => _connection != null;

  /// Only yields devices matching a known [BleProfile] — see
  /// BleProfiles.known's doc comment for why an empty/unrecognized-device
  /// result set is expected, not a bug.
  Stream<BleScanResult> scanForDevices() => _central.scan();

  Future<void> connect(BleScanResult device, {int maxAttempts = 3}) async {
    if (device.profile == null) {
      throw StateError(
          'Cannot connect to a device with no matched BleProfile: ${device.name}');
    }
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final connection = await _central.connect(device);
        // Once we hold a live GATT connection, EVERY failure path below must
        // close it before the outer retry loop opens a new one — leaving a
        // half-open connection behind wedges the GATT stack on Windows.
        try {
          final services = await connection.discoverServices();
          final service =
              _firstServiceMatching(services, device.profile!.serviceUuid);
          if (service == null) {
            throw StateError(
                'Device ${device.name} does not expose expected service '
                '${device.profile!.serviceUuid} (BleProfile mismatch)');
          }
          final resolved =
              _resolveCharacteristics(service, device.profile!);
          _connection = connection;
          _serviceUuid = service.uuid;
          _writeCharUuid = resolved.writeCharUuid;
          _notifyCharUuid = resolved.notifyCharUuid;
          _writeWithResponse = resolved.writeWithResponse;
          _connStateSub = connection.connectionState.listen((connected) {
            if (!connected) _handleDisconnect();
          });
        } catch (_) {
          await connection.disconnect().catchError((_) {});
          rethrow;
        }
        _log.fine('Connected to ${device.name} (${device.id})');
        return;
      } catch (e) {
        lastError = e;
        _log.warning('connect() attempt $attempt/$maxAttempts failed: $e');
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 250 * attempt));
        }
      }
    }
    throw StateError(
        'Failed to connect to ${device.name} after $maxAttempts attempts: $lastError');
  }

  /// Explicit disconnect. Delegates to the base's [teardown], which marks
  /// the bridge closed, stops servicing, and closes the GATT link.
  Future<void> disconnect() async {
    await teardown();
  }

  /// Callback for the connection-state watch: an unexpected GATT drop.
  void _handleDisconnect() {
    handleDisconnect();
  }

  // --- BridgedTransport hooks ---

  @override
  bool get isDeviceConnected => _connection != null && _serviceUuid != null;

  @override
  Future<void> writeToDevice(Uint8List bytes) => _connection!.write(
        _serviceUuid!,
        _writeCharUuid!,
        bytes,
        withResponse: _writeWithResponse,
      );

  @override
  Stream<Uint8List> get inboundBytes =>
      _connection!.subscribeNotifications(_serviceUuid!, _notifyCharUuid!);

  @override
  Future<void> closeDevice() async {
    await _connStateSub?.cancel();
    _connStateSub = null;
    final c = _connection;
    _connection = null;
    _serviceUuid = null;
    _writeCharUuid = null;
    _notifyCharUuid = null;
    _writeWithResponse = false;
    await c?.disconnect().catchError((_) {});
  }

  static BleGattService? _firstServiceMatching(
      List<BleGattService> services, String serviceUuid) {
    final want = serviceUuid.toLowerCase();
    for (final s in services) {
      if (s.uuid.toLowerCase() == want) return s;
    }
    return null;
  }

  /// Resolves the write/notify characteristic pair for [service]: an explicit
  /// UUID in [profile] always wins; otherwise the first characteristic in the
  /// service advertising `write`/`writeWithoutResponse` (resp.
  /// `notify`/`indicate`) is used. `writeWithResponse` falls back to
  /// preferring write-without-response when the resolved characteristic
  /// offers it.
  ({String writeCharUuid, String notifyCharUuid, bool writeWithResponse})
      _resolveCharacteristics(BleGattService service, BleProfile profile) {
    BleGattCharacteristic? firstWhere(
        bool Function(BleGattCharacteristic) test) {
      for (final c in service.characteristics) {
        if (test(c)) return c;
      }
      return null;
    }

    final explicitWrite = profile.writeCharUuid;
    final writeChar = explicitWrite != null
        ? firstWhere((c) => c.uuid.toLowerCase() == explicitWrite.toLowerCase())
        : firstWhere((c) => c.canWrite || c.canWriteWithoutResponse);
    final writeCharUuid = explicitWrite ?? writeChar?.uuid;
    if (writeCharUuid == null) {
      throw StateError('Service ${service.uuid} exposes no writable '
          'characteristic (BleProfile mismatch)');
    }

    final explicitNotify = profile.notifyCharUuid;
    final notifyChar = explicitNotify != null
        ? firstWhere(
            (c) => c.uuid.toLowerCase() == explicitNotify.toLowerCase())
        : firstWhere((c) => c.canNotify || c.canIndicate);
    final notifyCharUuid = explicitNotify ?? notifyChar?.uuid;
    if (notifyCharUuid == null) {
      throw StateError('Service ${service.uuid} exposes no notify/indicate '
          'characteristic (BleProfile mismatch)');
    }

    final writeWithResponse = profile.writeWithResponse ??
        !(writeChar?.canWriteWithoutResponse ?? false);

    _log.fine('Resolved BLE characteristics on ${service.uuid}: '
        'write=$writeCharUuid (withResponse=$writeWithResponse), '
        'notify=$notifyCharUuid');
    return (
      writeCharUuid: writeCharUuid,
      notifyCharUuid: notifyCharUuid,
      writeWithResponse: writeWithResponse,
    );
  }
}
