import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../ble/ble_bridge_state.dart';
import '../dive_computer_ffi_bindings_generated.dart';
import 'rfcomm_channel.dart';

final _log = Logger('RfcommTransport');

/// Main-isolate driver for a Bluetooth-Classic RFCOMM connection on behalf of
/// a [BleBridge] running on the background isolate. RFCOMM is a plain byte
/// stream, so this is simpler than `BleTransport` — no service/characteristic
/// discovery. The mailbox pump / teardown mirror `BleTransport` (kept
/// duplicated deliberately; see the plan's Global Constraints).
class RfcommTransport {
  RfcommTransport(this._channel);

  final RfcommChannel _channel;
  BleBridge? _bridge;
  bool _connected = false;

  StreamSubscription<Uint8List>? _inboundSub;
  Timer? _mailboxTimer;
  int _lastServicedWriteSeq = 0;
  bool _writeInFlight = false;

  bool get isConnected => _connected;

  Future<void> connect(String address) async {
    await _channel.connect(address);
    _connected = true;
    _log.fine('RFCOMM connected to $address');
  }

  /// Starts servicing [bridge]: forwards inbound socket bytes into it, and
  /// polls its outbound mailbox to perform queued writes. Must be called
  /// after [connect].
  void attachBridge(BleBridge bridge) {
    if (!_connected) {
      throw StateError('attachBridge() called before connect()');
    }
    _bridge = bridge;
    _lastServicedWriteSeq = 0;
    _inboundSub = _channel.inbound.listen(
      (bytes) {
        // Read the FIELD, not the captured parameter: _teardown() nulls
        // _bridge and cancels this subscription unawaited, so an
        // already-queued notification can still arrive after the bridge's
        // native memory was freed. Matches _serviceMailbox().
        final b = _bridge;
        if (b == null || b.isClosed) return;
        final written = b.pushInbound(bytes);
        if (written < bytes.length) {
          _log.severe('Inbound ring buffer overflow: dropped '
              '${bytes.length - written} of ${bytes.length} bytes');
        }
      },
      onDone: _handleDisconnect,
      onError: (Object e, StackTrace st) {
        _log.warning('RFCOMM inbound error', e, st);
        _handleDisconnect();
      },
    );
    _mailboxTimer = Timer.periodic(
        const Duration(milliseconds: 4), (_) => _serviceMailbox());
  }

  Future<void> _serviceMailbox() async {
    // The 4ms timer keeps firing while an await is outstanding; without this
    // guard a retry that bumps writeSeq mid-flight would start a second
    // concurrent write on the socket.
    if (_writeInFlight) return;
    final bridge = _bridge;
    if (bridge == null || !_connected) return;
    // libdivecomputer's close callback set closed = 1. Stop our own 4ms timer
    // now instead of waiting for the facade's disconnect() — complements the
    // teardown-before-dispose ordering in DiveComputer.download.
    if (bridge.isClosed) {
      _teardown();
      return;
    }
    final seq = bridge.pendingWriteSeq;
    if (seq == _lastServicedWriteSeq) return;
    _lastServicedWriteSeq = seq;
    _writeInFlight = true;
    try {
      await _channel.write(bridge.pendingOutbound);
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_SUCCESS);
    } catch (e, st) {
      _log.severe('RFCOMM mailbox write failed', e, st);
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_IO);
    } finally {
      _writeInFlight = false;
    }
  }

  void _handleDisconnect() {
    _log.warning('RFCOMM socket disconnected');
    _bridge?.markClosed();
    _teardown();
  }

  Future<void> disconnect() async {
    _bridge?.markClosed();
    if (_connected) await _channel.disconnect().catchError((_) {});
    _teardown();
  }

  void _teardown() {
    _mailboxTimer?.cancel();
    _mailboxTimer = null;
    _inboundSub?.cancel();
    _inboundSub = null;
    _connected = false;
    _bridge = null;
  }
}
