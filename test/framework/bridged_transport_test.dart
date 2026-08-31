import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:dive_computer/framework/bridged_transport.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:fake_async/fake_async.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTransport extends BridgedTransport {
  final _inbound = StreamController<Uint8List>();
  final writes = <List<int>>[];
  int writeCalls = 0;
  Completer<void>? gate; // when set, writeToDevice awaits it
  bool connected = true;
  int closeCalls = 0;

  void emitInbound(List<int> b) => _inbound.add(Uint8List.fromList(b));

  @override
  Stream<Uint8List> get inboundBytes => _inbound.stream;
  @override
  bool get isDeviceConnected => connected;
  @override
  Future<void> writeToDevice(Uint8List bytes) async {
    writeCalls++;
    if (gate != null) await gate!.future;
    writes.add(bytes.toList());
  }
  @override
  Future<void> closeDevice() async {
    closeCalls++;
    connected = false;
  }
}

int _queue(BleBridge bridge, List<int> bytes) {
  final p = calloc<ffi.Uint8>(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    p[i] = bytes[i];
  }
  final seq = bridge.queueOutbound(p, bytes.length);
  calloc.free(p);
  return seq;
}

void main() {
  test('serviceMailbox writes the mailbox and acks the captured seq', () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(() => t.teardown());
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);

    final seq = _queue(bridge, [1, 2, 3]);
    await t.serviceMailbox();

    expect(t.writes, [[1, 2, 3]]);
    expect(bridge.waitForWriteAck(seq, 0), isTrue);
  });

  test('a retry that bumps writeSeq mid-write does not double-write', () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(() => t.teardown());
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);

    t.gate = Completer<void>();
    _queue(bridge, [1]);
    final first = t.serviceMailbox();       // enters writeToDevice, awaits gate
    _queue(bridge, [2]);                      // bump writeSeq mid-flight
    await t.serviceMailbox();                 // must early-return on _writeInFlight
    expect(t.writeCalls, 1);
    t.gate!.complete();
    await first;
  });

  test('the 250ms safety-net timer services a write on its own', () {
    fakeAsync((async) {
      final t = _FakeTransport();
      final bridge = BleBridge.allocate();
      t.attachBridge(bridge);
      _queue(bridge, [7, 7]);
      async.elapse(const Duration(milliseconds: 300));
      expect(t.writes, [[7, 7]]);
      t.teardown();
      bridge.dispose();
    });
  });

  test('a write that settles after teardown does not ack the freed bridge',
      () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    t.attachBridge(bridge);

    t.gate = Completer<void>();
    _queue(bridge, [1, 2, 3]);
    final inFlight = t.serviceMailbox(); // parked inside writeToDevice
    await t.teardown(); // nulls _bridge; sync()'s finally would dispose next
    t.gate!.complete();
    await inFlight; // must not throw

    // Assert BEFORE dispose(): the ack must not have been written through the
    // (about to be freed) pointer. waitForWriteAck() is no good here — it
    // reports true for a closed bridge — so read writeAckSeq directly.
    expect(bridge.pointer.ref.writeAckSeq, 0);
    bridge.dispose();
  });

  test('a WriteReady during an in-flight write is drained, not dropped',
      () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(() => t.teardown());
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);

    final firstGate = Completer<void>();
    t.gate = firstGate;
    _queue(bridge, [1]);
    final first = t.serviceMailbox(); // parked inside writeToDevice
    final seq2 = _queue(bridge, [2]); // WriteReady arrives mid-flight...
    await t.serviceMailbox(); // ...and is dropped by the _writeInFlight guard
    expect(t.writeCalls, 1);

    t.gate = null; // let the re-drive complete without gating
    firstGate.complete();
    await first;
    // The finally re-drove the mailbox: no 250ms safety-net wait needed.
    await Future<void>.delayed(Duration.zero);
    expect(t.writes, [
      [1],
      [2]
    ]);
    expect(bridge.waitForWriteAck(seq2, 0), isTrue);
  });

  test('inbound bytes land in the ring buffer', () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(() => t.teardown());
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);

    t.emitInbound([9, 8, 7]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final dest = calloc<ffi.Uint8>(8);
    expect(bridge.popInbound(dest, 8), 3);
    calloc.free(dest);
  });

  test('an inbound event after teardown is a no-op (field read, not capture)',
      () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    t.attachBridge(bridge);
    await t.teardown();
    // must not throw even though the bridge is about to be freed
    t.emitInbound([1]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    bridge.dispose();
  });

  test('bridge.isClosed makes serviceMailbox tear the transport down', () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);
    bridge.markClosed();
    await t.serviceMailbox();
    expect(t.closeCalls, 1);
    expect(t.hasBridge, isFalse);
  });
}
