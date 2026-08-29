import 'dart:typed_data';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_channel.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'dart:ffi' as ffi;

void main() {
  test('inbound socket bytes land in the bridge ring buffer', () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);

    await t.connect('00:13:43:0A:A0:6F');
    t.attachBridge(bridge);

    ch.emitInbound(Uint8List.fromList([1, 2, 3, 4]));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final dest = calloc<ffi.Uint8>(16);
    final n = bridge.popInbound(dest, 16);
    expect(n, 4);
    expect([for (var i = 0; i < 4; i++) dest[i]], [1, 2, 3, 4]);
    calloc.free(dest);
  });

  test('outbound mailbox is drained to channel.write and acked', () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    await t.connect('x');
    t.attachBridge(bridge);

    final data = calloc<ffi.Uint8>(3);
    data[0] = 10;
    data[1] = 20;
    data[2] = 30;
    final seq = bridge.queueOutbound(data, 3);
    calloc.free(data);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ch.writes, [
      [10, 20, 30]
    ]);
    expect(bridge.waitForWriteAck(seq, 0), isTrue);
  });

  test('a socket disconnect marks the bridge closed', () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    await t.connect('x');
    t.attachBridge(bridge);

    ch.emitDisconnect();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(bridge.isClosed, isTrue);
  });
}
