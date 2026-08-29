import 'package:dive_computer/framework/utils/serial_ports.dart';
import 'package:test/test.dart';

void main() {
  group('dedupeSerialPorts', () {
    test('removes duplicates, preserving first-seen order', () {
      expect(
        dedupeSerialPorts(['COM7', 'COM5', 'COM4', 'COM3', 'COM6', 'COM7']),
        ['COM7', 'COM5', 'COM4', 'COM3', 'COM6'],
      );
    });

    test('leaves an already-unique list untouched', () {
      expect(dedupeSerialPorts(['COM1', 'COM2']), ['COM1', 'COM2']);
    });

    test('empty stays empty', () {
      expect(dedupeSerialPorts(const []), isEmpty);
    });
  });

  group('selectSerialPort', () {
    final ports = ['COM7', 'COM5', 'COM3'];

    test('no request → first port', () {
      expect(selectSerialPort(ports), 'COM7');
    });

    test('request present → that port', () {
      expect(selectSerialPort(ports, requested: 'COM5'), 'COM5');
    });

    test('request matched case-insensitively, returns the enumerated spelling',
        () {
      expect(selectSerialPort(ports, requested: 'com3'), 'COM3');
    });

    test('request absent → ArgumentError naming the available ports', () {
      expect(
        () => selectSerialPort(ports, requested: 'COM9'),
        throwsA(isA<ArgumentError>().having(
            (e) => e.message, 'message', allOf(contains('COM9'), contains('COM7')))),
      );
    });

    test('no ports at all → StateError', () {
      expect(() => selectSerialPort(const []), throwsStateError);
    });
  });
}
