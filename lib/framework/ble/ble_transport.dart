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
  BleProfile? _profile;
  BleBridge? _bridge;
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
          final hasService = services.any((s) =>
              s.uuid.toLowerCase() ==
              device.profile!.serviceUuid.toLowerCase());
          if (!hasService) {
            throw StateError(
                'Device ${device.name} does not expose expected service '
                '${device.profile!.serviceUuid} (BleProfile mismatch)');
          }
          _connection = connection;
          _profile = device.profile;
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
    final profile = _profile;
    if (connection == null || profile == null) {
      throw StateError('attachBridge() called before connect()');
    }
    _bridge = bridge;
    _lastServicedWriteSeq = 0;
    _notifySub = connection
        .subscribeNotifications(profile.serviceUuid, profile.notifyCharUuid)
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
    final profile = _profile;
    if (bridge == null || connection == null || profile == null) return;
    final seq = bridge.pendingWriteSeq;
    if (seq == _lastServicedWriteSeq) return;
    _lastServicedWriteSeq = seq;
    _writeInFlight = true;
    try {
      await connection.write(
        profile.serviceUuid,
        profile.writeCharUuid,
        bridge.pendingOutbound,
        withResponse: profile.writeWithResponse,
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
    _profile = null;
    _bridge = null;
  }
}
