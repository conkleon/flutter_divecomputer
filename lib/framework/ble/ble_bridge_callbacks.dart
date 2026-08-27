import 'dart:ffi' as ffi;
import 'package:logging/logging.dart';

import 'ble_bridge_state.dart';
import '../dive_computer_ffi_bindings_generated.dart';

final _log = Logger('BleBridge');

typedef _StatusOnlyNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);

typedef _IntArgNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int);

// `purge` takes a plain `int direction` in the generated struct (ffi.Int32),
// not the C `int` timeout-style arg that `poll`/`set_timeout` use (ffi.Int).
typedef _Int32ArgNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32);

typedef _UIntArgNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.UnsignedInt);

typedef _GetLinesNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.UnsignedInt>);

typedef _GetAvailableNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Size>);

typedef _ReadWriteNative = ffi.Int32 Function(ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<ffi.Void> data, ffi.Size size, ffi.Pointer<ffi.Size> actual);

typedef _IoctlNative = ffi.Int32 Function(ffi.Pointer<ffi.Void> userdata,
    ffi.UnsignedInt request, ffi.Pointer<ffi.Void> data, ffi.Size size);

typedef _ConfigureNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.UnsignedInt baudrate,
    ffi.UnsignedInt databits,
    ffi.Int32 parity,
    ffi.Int32 stopbits,
    ffi.Int32 flowcontrol);

/// Guards every callback body so a Dart exception can never escape into
/// native code (undefined behavior) — it's logged and turned into a
/// well-defined DC_STATUS_IO instead. See design spec's Defensive measures.
int _guard(String name, int Function() body) {
  try {
    return body();
  } catch (e, st) {
    _log.severe('$name() threw', e, st);
    return dc_status_t.DC_STATUS_IO;
  }
}

int _read(ffi.Pointer<ffi.Void> userdata, ffi.Pointer<ffi.Void> data,
    int size, ffi.Pointer<ffi.Size> actual) {
  return _guard('read', () {
    actual.value = 0;
    final bridge = BleBridge.fromRawPointer(userdata);
    final ready = bridge.waitForInbound(bridge.timeoutMs);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    if (!ready) {
      _log.finest('read(): timeout');
      return dc_status_t.DC_STATUS_TIMEOUT;
    }
    final n = bridge.popInbound(data.cast<ffi.Uint8>(), size);
    actual.value = n;
    _log.finest('read(): $n bytes');
    return dc_status_t.DC_STATUS_SUCCESS;
  });
}

int _write(ffi.Pointer<ffi.Void> userdata, ffi.Pointer<ffi.Void> data,
    int size, ffi.Pointer<ffi.Size> actual) {
  return _guard('write', () {
    actual.value = 0;
    final bridge = BleBridge.fromRawPointer(userdata);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    if (size > kOutboundCapacity) {
      // BleBridge.queueOutbound silently clamps to kOutboundCapacity;
      // truncating a protocol write would corrupt the device conversation,
      // so refuse it outright instead.
      _log.severe(
          'write(): payload $size exceeds outbound capacity $kOutboundCapacity');
      return dc_status_t.DC_STATUS_IO;
    }
    final seq = bridge.queueOutbound(data.cast<ffi.Uint8>(), size);
    final acked = bridge.waitForWriteAck(seq, bridge.timeoutMs);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    if (!acked) {
      _log.warning('write(): timeout waiting for ack');
      return dc_status_t.DC_STATUS_TIMEOUT;
    }
    actual.value = size;
    _log.finest('write(): $size bytes, status=${bridge.writeStatus}');
    return bridge.writeStatus;
  });
}

int _poll(ffi.Pointer<ffi.Void> userdata, int timeout) {
  return _guard('poll', () {
    final bridge = BleBridge.fromRawPointer(userdata);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    final ready = bridge.waitForInbound(timeout);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    return ready ? dc_status_t.DC_STATUS_SUCCESS : dc_status_t.DC_STATUS_TIMEOUT;
  });
}

int _getAvailable(ffi.Pointer<ffi.Void> userdata, ffi.Pointer<ffi.Size> value) {
  return _guard('get_available', () {
    value.value = BleBridge.fromRawPointer(userdata).inboundAvailable;
    return dc_status_t.DC_STATUS_SUCCESS;
  });
}

int _setTimeout(ffi.Pointer<ffi.Void> userdata, int timeout) {
  return _guard('set_timeout', () {
    BleBridge.fromRawPointer(userdata).timeoutMs = timeout;
    return dc_status_t.DC_STATUS_SUCCESS;
  });
}

int _close(ffi.Pointer<ffi.Void> userdata) {
  return _guard('close', () {
    BleBridge.fromRawPointer(userdata).markClosed();
    return dc_status_t.DC_STATUS_SUCCESS;
  });
}

// BLE has no serial control lines/baud rate/flow control — these are
// required members of dc_custom_cbs_t but are no-ops for us.
int _noop(ffi.Pointer<ffi.Void> userdata) => dc_status_t.DC_STATUS_SUCCESS;
int _noopArg(ffi.Pointer<ffi.Void> userdata, int value) =>
    dc_status_t.DC_STATUS_SUCCESS;
int _noopGetLines(
    ffi.Pointer<ffi.Void> userdata, ffi.Pointer<ffi.UnsignedInt> value) {
  value.value = 0;
  return dc_status_t.DC_STATUS_SUCCESS;
}
int _noopConfigure(ffi.Pointer<ffi.Void> userdata, int baudrate, int databits,
        int parity, int stopbits, int flowcontrol) =>
    dc_status_t.DC_STATUS_SUCCESS;
int _noopIoctl(ffi.Pointer<ffi.Void> userdata, int request,
        ffi.Pointer<ffi.Void> data, int size) =>
    dc_status_t.DC_STATUS_UNSUPPORTED;

/// Static function pointers matching every member of `dc_custom_cbs_t`
/// (native/include/libdivecomputer/custom.h), for use with `dc_custom_open`
/// (Task 11).
class BleBridgeCallbacks {
  BleBridgeCallbacks._();

  static final readPtr =
      ffi.Pointer.fromFunction<_ReadWriteNative>(_read, dc_status_t.DC_STATUS_IO);
  static final writePtr = ffi.Pointer.fromFunction<_ReadWriteNative>(
      _write, dc_status_t.DC_STATUS_IO);
  static final pollPtr =
      ffi.Pointer.fromFunction<_IntArgNative>(_poll, dc_status_t.DC_STATUS_IO);
  static final getAvailablePtr = ffi.Pointer.fromFunction<_GetAvailableNative>(
      _getAvailable, dc_status_t.DC_STATUS_IO);
  static final setTimeoutPtr = ffi.Pointer.fromFunction<_IntArgNative>(
      _setTimeout, dc_status_t.DC_STATUS_IO);
  static final closePtr = ffi.Pointer.fromFunction<_StatusOnlyNative>(
      _close, dc_status_t.DC_STATUS_IO);

  static final setBreakPtr = ffi.Pointer.fromFunction<_UIntArgNative>(
      _noopArg, dc_status_t.DC_STATUS_SUCCESS);
  static final setDtrPtr = ffi.Pointer.fromFunction<_UIntArgNative>(
      _noopArg, dc_status_t.DC_STATUS_SUCCESS);
  static final setRtsPtr = ffi.Pointer.fromFunction<_UIntArgNative>(
      _noopArg, dc_status_t.DC_STATUS_SUCCESS);
  static final getLinesPtr = ffi.Pointer.fromFunction<_GetLinesNative>(
      _noopGetLines, dc_status_t.DC_STATUS_SUCCESS);
  static final configurePtr = ffi.Pointer.fromFunction<_ConfigureNative>(
      _noopConfigure, dc_status_t.DC_STATUS_SUCCESS);
  static final flushPtr = ffi.Pointer.fromFunction<_StatusOnlyNative>(
      _noop, dc_status_t.DC_STATUS_SUCCESS);
  static final purgePtr = ffi.Pointer.fromFunction<_Int32ArgNative>(
      _noopArg, dc_status_t.DC_STATUS_SUCCESS);
  static final sleepPtr = ffi.Pointer.fromFunction<_UIntArgNative>(
      _noopArg, dc_status_t.DC_STATUS_SUCCESS);
  static final ioctlPtr = ffi.Pointer.fromFunction<_IoctlNative>(
      _noopIoctl, dc_status_t.DC_STATUS_UNSUPPORTED);
}
