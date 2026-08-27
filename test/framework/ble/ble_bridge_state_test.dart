import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:test/test.dart';

void main() {
  group('BleBridge inbound ring buffer', () {
    late BleBridge bridge;
    setUp(() => bridge = BleBridge.allocate());
    tearDown(() => bridge.dispose());

    test('push then pop round-trips bytes in order', () {
      bridge.pushInbound(Uint8List.fromList([1, 2, 3]));
      expect(bridge.inboundAvailable, 3);

      final dest = calloc<ffi.Uint8>(8);
      addTearDown(() => calloc.free(dest));
      final n = bridge.popInbound(dest, 8);

      expect(n, 3);
      expect([dest[0], dest[1], dest[2]], [1, 2, 3]);
      expect(bridge.inboundAvailable, 0);
    });

    test('wraps around the buffer boundary correctly', () {
      // Push/pop repeatedly near the capacity boundary to force wraparound.
      final dest = calloc<ffi.Uint8>(kInboundCapacity);
      addTearDown(() => calloc.free(dest));
      for (var round = 0; round < 3; round++) {
        final chunk = Uint8List.fromList(
            List.generate(kInboundCapacity - 10, (i) => i % 256));
        bridge.pushInbound(chunk);
        final n = bridge.popInbound(dest, chunk.length);
        expect(n, chunk.length);
        expect(dest.asTypedList(chunk.length), chunk);
      }
    });

    test('push beyond free space is truncated, not corrupted', () {
      final huge = Uint8List(kInboundCapacity + 100);
      final written = bridge.pushInbound(huge);
      expect(written, lessThan(huge.length));
      expect(bridge.inboundAvailable, written);
    });
  });

  group('BleBridge outbound mailbox', () {
    late BleBridge bridge;
    setUp(() => bridge = BleBridge.allocate());
    tearDown(() => bridge.dispose());

    test('queueOutbound then ackOutbound updates sequence and status', () {
      final data = calloc<ffi.Uint8>(3);
      addTearDown(() => calloc.free(data));
      data.asTypedList(3).setAll(0, [9, 8, 7]);

      final seq = bridge.queueOutbound(data, 3);
      expect(bridge.pendingOutbound, [9, 8, 7]);
      expect(bridge.pendingWriteSeq, seq);

      bridge.ackOutbound(0);
      expect(bridge.waitForWriteAck(seq, 100), isTrue);
      expect(bridge.writeStatus, 0);
    });
  });

  group('BleBridge waits', () {
    test('waitForInbound(0) is non-blocking and reflects current state', () {
      final bridge = BleBridge.allocate();
      addTearDown(bridge.dispose);
      expect(bridge.waitForInbound(0), isFalse);
      bridge.pushInbound(Uint8List.fromList([1]));
      expect(bridge.waitForInbound(0), isTrue);
    });

    test('waitForInbound times out when nothing arrives', () {
      final bridge = BleBridge.allocate();
      addTearDown(bridge.dispose);
      final sw = Stopwatch()..start();
      final ready = bridge.waitForInbound(30);
      sw.stop();
      expect(ready, isFalse);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(30));
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('closed unblocks a wait immediately', () {
      final bridge = BleBridge.allocate();
      addTearDown(bridge.dispose);
      bridge.markClosed();
      final sw = Stopwatch()..start();
      final ready = bridge.waitForInbound(5000); // would hang if not for closed
      sw.stop();
      expect(ready, isTrue); // "ready" here just means "stopped waiting"
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });

  test('fromAddress reconstructs the same shared memory', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.pushInbound(Uint8List.fromList([42]));

    final reconstructed = BleBridge.fromAddress(bridge.address);
    expect(reconstructed.inboundAvailable, 1);
  });
}
