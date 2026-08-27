import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';

import 'ble_bridge_state.dart';
import 'ble_central.dart';
import '../dive_computer_ffi_bindings_generated.dart';
import '../../types/ble_profile.dart';
import '../../types/ble_scan_result.dart';

final _log = Logger('BleTransport');

/// Drives BLE I/O on the main isolate on behalf of a [BleBridge] running
/// on the background isolate. See design spec's Components section.
class BleTransport {
  BleTransport(this._central);

  final BleCentral _central;
  BleConnection? _connection;
  BleBridge? _bridge;

  // Resolved once in connect() from the profile + discovered GATT layout;
  // non-null exactly while _connection is.
  String? _serviceUuid;
  String? _writeCharUuid;
  String? _notifyCharUuid;
  bool _writeWithResponse = false;

  Timer? _mailboxTimer;
  StreamSubscription<Uint8List>? _notifySub;
  StreamSubscription<bool>? _connStateSub;
  int _lastServicedWriteSeq = 0;
  bool _writeInFlight = false;

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

  /// Starts servicing [bridge]: forwards BLE notifications into it, and
  /// polls its outbound mailbox to perform queued writes. Must be called
  /// after [connect].
  void attachBridge(BleBridge bridge) {
    final connection = _connection;
    if (connection == null || _serviceUuid == null) {
      throw StateError('attachBridge() called before connect()');
    }
    _bridge = bridge;
    _lastServicedWriteSeq = 0;
    _notifySub = connection
        .subscribeNotifications(_serviceUuid!, _notifyCharUuid!)
        .listen((bytes) {
      // Read the FIELD, not the captured parameter: _teardown() nulls _bridge
      // and cancels this subscription unawaited, so an already-queued
      // notification can still arrive after the bridge's native memory was
      // freed. Matches _serviceMailbox().
      final b = _bridge;
      if (b == null || b.isClosed) return;
      final written = b.pushInbound(bytes);
      if (written < bytes.length) {
        _log.severe('Inbound ring buffer overflow: dropped '
            '${bytes.length - written} of ${bytes.length} bytes');
      }
    });
    _mailboxTimer =
        Timer.periodic(const Duration(milliseconds: 4), (_) => _serviceMailbox());
  }

  Future<void> _serviceMailbox() async {
    // The 4ms timer keeps firing while an await is outstanding; without this
    // guard a retry that bumps writeSeq mid-flight would start a second
    // concurrent GATT write on the same characteristic.
    if (_writeInFlight) return;
    final bridge = _bridge;
    final connection = _connection;
    if (bridge == null || connection == null || _serviceUuid == null) return;
    final seq = bridge.pendingWriteSeq;
    if (seq == _lastServicedWriteSeq) return;
    _lastServicedWriteSeq = seq;
    _writeInFlight = true;
    try {
      await connection.write(
        _serviceUuid!,
        _writeCharUuid!,
        bridge.pendingOutbound,
        withResponse: _writeWithResponse,
      );
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_SUCCESS);
    } catch (e, st) {
      _log.severe('Mailbox write failed', e, st);
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_IO);
    } finally {
      _writeInFlight = false;
    }
  }

  void _handleDisconnect() {
    _log.warning('BLE device disconnected unexpectedly');
    _bridge?.markClosed();
    _teardown();
  }

  Future<void> disconnect() async {
    _bridge?.markClosed();
    await _connection?.disconnect();
    _teardown();
  }

  void _teardown() {
    _mailboxTimer?.cancel();
    _mailboxTimer = null;
    _notifySub?.cancel();
    _notifySub = null;
    _connStateSub?.cancel();
    _connStateSub = null;
    _connection = null;
    _serviceUuid = null;
    _writeCharUuid = null;
    _notifyCharUuid = null;
    _writeWithResponse = false;
    _bridge = null;
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
