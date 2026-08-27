import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_bridge_callbacks.dart';
import 'package:dive_computer/framework/dive_computer_ffi_bindings_generated.dart';
import 'package:test/test.dart';

typedef _ReadWriteDart = int Function(ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<ffi.Void> data, int size, ffi.Pointer<ffi.Size> actual);

void main() {
  test('read() returns queued inbound bytes', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.pushInbound(Uint8List.fromList([1, 2, 3]));

    final read = BleBridgeCallbacks.readPtr.asFunction<_ReadWriteDart>();
    final buf = calloc<ffi.Uint8>(8);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(buf);
      calloc.free(actual);
    });

    final status =
        read(bridge.pointer.cast(), buf.cast(), 8, actual);

    expect(status, dc_status_t.DC_STATUS_SUCCESS);
    expect(actual.value, 3);
    expect([buf[0], buf[1], buf[2]], [1, 2, 3]);
  });

  test('read() times out when no data arrives', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.timeoutMs = 20;

    final read = BleBridgeCallbacks.readPtr.asFunction<_ReadWriteDart>();
    final buf = calloc<ffi.Uint8>(8);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(buf);
      calloc.free(actual);
    });

    final status = read(bridge.pointer.cast(), buf.cast(), 8, actual);

    expect(status, dc_status_t.DC_STATUS_TIMEOUT);
  });

  test('read() unblocks immediately when closed, instead of hanging', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.timeoutMs = 5000; // would hang the test if `closed` didn't interrupt it
    bridge.markClosed();

    final read = BleBridgeCallbacks.readPtr.asFunction<_ReadWriteDart>();
    final buf = calloc<ffi.Uint8>(8);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(buf);
      calloc.free(actual);
    });

    final sw = Stopwatch()..start();
    final status = read(bridge.pointer.cast(), buf.cast(), 8, actual);
    sw.stop();

    expect(status, dc_status_t.DC_STATUS_IO);
    expect(sw.elapsedMilliseconds, lessThan(500));
  });

  test(
      'write() blocks until another isolate acks it via the shared memory',
      () async {
    // NOTE: this must use a real Isolate, not a Timer — write()'s spin
    // loop calls dart:io's sleep(), which blocks this thread WITHOUT
    // yielding to the event loop, so a Timer scheduled on this same
    // isolate would never fire while write() is waiting. This is exactly
    // the constraint the whole bridge design exists to work around (see
    // design spec's "core technical constraint" section) — so this test
    // doubles as verification that cross-isolate shared memory actually
    // works, which is the riskiest assumption in the whole feature.
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.timeoutMs = 2000;

    final ackFuture = Isolate.run(() async {
      await Future.delayed(const Duration(milliseconds: 30));
      BleBridge.fromAddress(bridge.address)
          .ackOutbound(1, dc_status_t.DC_STATUS_SUCCESS);
    });

    final write = BleBridgeCallbacks.writePtr.asFunction<_ReadWriteDart>();
    final data = calloc<ffi.Uint8>(3);
    data.asTypedList(3).setAll(0, [9, 8, 7]);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(data);
      calloc.free(actual);
    });

    final status = write(bridge.pointer.cast(), data.cast(), 3, actual);
    await ackFuture;

    expect(status, dc_status_t.DC_STATUS_SUCCESS);
    expect(actual.value, 3);
  });

  test('write() rejects a payload larger than the outbound capacity', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.timeoutMs = 2000;

    final write = BleBridgeCallbacks.writePtr.asFunction<_ReadWriteDart>();
    final size = kOutboundCapacity + 1;
    final data = calloc<ffi.Uint8>(size);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(data);
      calloc.free(actual);
    });

    final status = write(bridge.pointer.cast(), data.cast(), size, actual);

    expect(status, dc_status_t.DC_STATUS_IO);
    expect(actual.value, 0);
    expect(bridge.pendingWriteSeq, 0);
  });

  test('close() sets the closed flag', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    final close = BleBridgeCallbacks.closePtr
        .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

    final status = close(bridge.pointer.cast());

    expect(status, dc_status_t.DC_STATUS_SUCCESS);
    expect(bridge.isClosed, isTrue);
  });

  test('setTimeout() updates the bridge timeout', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    final setTimeout = BleBridgeCallbacks.setTimeoutPtr
        .asFunction<int Function(ffi.Pointer<ffi.Void>, int)>();

    final status = setTimeout(bridge.pointer.cast(), 1234);

    expect(status, dc_status_t.DC_STATUS_SUCCESS);
    expect(bridge.timeoutMs, 1234);
  });
}
