import 'package:dive_computer/types/bt_device.dart';
import 'package:test/test.dart';

void main() {
  test('value equality on name + address', () {
    expect(const BtDevice('Petrel', '00:13:43:0A:A0:6F'),
        const BtDevice('Petrel', '00:13:43:0A:A0:6F'));
    expect(const BtDevice('Petrel', '00:13:43:0A:A0:6F'),
        isNot(const BtDevice('Petrel', '00:00:00:00:00:00')));
  });

  test('toString shows name and address', () {
    expect(const BtDevice('Petrel', '00:13:43:0A:A0:6F').toString(),
        contains('Petrel'));
    expect(const BtDevice('Petrel', '00:13:43:0A:A0:6F').toString(),
        contains('00:13:43:0A:A0:6F'));
  });
}
