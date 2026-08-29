import 'dart:typed_data';
import 'package:dive_computer/framework/rfcomm/rfcomm_channel.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FakeRfcommChannel records connect/write and replays inbound', () async {
    final ch = FakeRfcommChannel();
    ch.bonded = [const BtDevice('Petrel', '00:13:43:0A:A0:6F')];

    expect(await ch.requestPermissions(), isTrue);
    expect(await ch.bondedDevices(), ch.bonded);

    await ch.connect('00:13:43:0A:A0:6F');
    expect(ch.connectedAddress, '00:13:43:0A:A0:6F');

    final received = <List<int>>[];
    final sub = ch.inbound.listen(received.add);

    await ch.write([1, 2, 3]);
    expect(ch.writes, [
      [1, 2, 3]
    ]);

    ch.emitInbound(Uint8List.fromList([9, 8, 7]));
    await Future<void>.delayed(Duration.zero);
    expect(received, [
      [9, 8, 7]
    ]);

    await ch.disconnect();
    expect(ch.disconnected, isTrue);
    await sub.cancel();
  });
}
