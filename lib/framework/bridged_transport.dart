import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'ble/ble_bridge_state.dart';
import 'dive_computer_ffi_bindings_generated.dart';

/// Shared machinery for a main-isolate transport driving a [BleBridge] on
/// behalf of libdivecomputer on the background isolate. `BleTransport` and
/// `RfcommTransport` differ only in how they open a connection and move
/// bytes; everything about servicing the bridge — the inbound pump, the
/// outbound mailbox, teardown ordering, the dangling-bridge guards — lives
/// here.
///
/// Outbound writes are normally triggered by a `WriteReady` port message
/// from the background isolate's `write` callback (see
/// `framework/sync/write_signal.dart`); [_safetyNet] is a slow fallback
/// for a lost message, not the primary path.
abstract class BridgedTransport {
  final Logger _log = Logger(_loggerName);
  static const _loggerName = 'BridgedTransport';

  BleBridge? _bridge;
  StreamSubscription<Uint8List>? _inboundSub;
  Timer? _safetyNet;
  int _lastServicedWriteSeq = 0;
  bool _writeInFlight = false;

  bool get hasBridge => _bridge != null;

  // --- subclass responsibilities -------------------------------------

  /// Perform the real device write (GATT write / socket write).
  Future<void> writeToDevice(Uint8List bytes);

  /// Inbound bytes from the device (GATT notifications / socket reads).
  Stream<Uint8List> get inboundBytes;

  /// Close the underlying connection. Called once during [teardown];
  /// must not throw (guard internally or expect the base to swallow it).
  Future<void> closeDevice();

  bool get isDeviceConnected;

  // --- base machinery ----------------------------------------------------

  void attachBridge(BleBridge bridge) {
    if (!isDeviceConnected) {
      throw StateError('attachBridge() called before a connection was open');
    }
    _bridge = bridge;
    _lastServicedWriteSeq = 0;
    _inboundSub = inboundBytes.listen(
      (bytes) {
        // Read the FIELD, not the captured param: teardown() nulls _bridge
        // and cancels this sub unawaited, so a queued notification can still
        // arrive after the bridge's native memory is freed.
        final b = _bridge;
        if (b == null || b.isClosed) return;
        final written = b.pushInbound(bytes);
        if (written < bytes.length) {
          _log.severe('Inbound ring buffer overflow: dropped '
              '${bytes.length - written} of ${bytes.length} bytes');
        }
      },
      onDone: handleDisconnect,
      onError: (Object e, StackTrace st) {
        _log.warning('Inbound stream error', e, st);
        handleDisconnect();
      },
    );
    _safetyNet = Timer.periodic(
        const Duration(milliseconds: 250), (_) => serviceMailbox());
  }

  /// Drain the outbound mailbox if it has a new payload. Invoked by a
  /// `WriteReady` message (fast path) and by [_safetyNet] (fallback).
  Future<void> serviceMailbox() async {
    if (_writeInFlight) return;
    final bridge = _bridge;
    if (bridge == null || !isDeviceConnected) return;
    if (bridge.isClosed) {
      await teardown();
      return;
    }
    final seq = bridge.pendingWriteSeq;
    if (seq == _lastServicedWriteSeq) return;
    _lastServicedWriteSeq = seq;
    _writeInFlight = true;
    try {
      await writeToDevice(bridge.pendingOutbound);
      // Re-check the FIELD, not the captured local: teardown() nulls _bridge
      // while this write is in flight, and sync()'s finally then disposes
      // (calloc.free) the bridge. Acking through the captured pointer after
      // that is a use-after-free.
      if (!identical(_bridge, bridge)) return;
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_SUCCESS);
    } catch (e, st) {
      _log.severe('Mailbox write failed', e, st);
      if (!identical(_bridge, bridge)) return;
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_IO);
    } finally {
      _writeInFlight = false;
      // A WriteReady that arrived while this write was in flight was dropped
      // by the _writeInFlight early-return; re-drive now instead of waiting
      // up to 250ms for the safety net. Bounded: the mailbox has one slot,
      // so at most one re-drive per settled write.
      final b = _bridge;
      if (b != null && !b.isClosed && b.pendingWriteSeq != _lastServicedWriteSeq) {
        unawaited(serviceMailbox().catchError((_) {}));
      }
    }
  }

  void handleDisconnect() {
    _log.warning('Bridged transport disconnected');
    _bridge?.markClosed();
    // teardown is async; callers of handleDisconnect don't await it.
    unawaited(teardown());
  }

  Future<void> teardown() async {
    // First: unblock any FFI callback still parked on the bridge. Idempotent
    // and safe from every call site (serviceMailbox-on-closed, handleDisconnect,
    // explicit disconnect) — restores the pre-refactor disconnect() semantics.
    _bridge?.markClosed();
    _safetyNet?.cancel();
    _safetyNet = null;
    await _inboundSub?.cancel();
    _inboundSub = null;
    try {
      if (isDeviceConnected) await closeDevice();
    } catch (_) {
      // best-effort; the bridge is already marked closed
    }
    _bridge = null;
  }
}
