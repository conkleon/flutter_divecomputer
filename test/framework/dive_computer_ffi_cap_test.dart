import 'dart:io';
import 'package:test/test.dart';

void main() {
  final source =
      File('lib/framework/dive_computer_ffi.dart').readAsStringSync();

  test('the debug-build dive cap is not present in _dive_callback', () {
    expect(
      source.contains('_divesCache.length >= 5'),
      isFalse,
      reason: 'The kDebugMode 5-dive download cap must stay removed — '
          'the plugin downloads the full dive log. See '
          'docs/superpowers/specs/2026-08-28-mares-cressi-ble-example-design.md',
    );
  });

  test('_connectSerial picks a port via selectSerialPort, not a blind names[0]',
      () {
    expect(
      source.contains('names[0]'),
      isFalse,
      reason: 'Opening the first enumerated COM port is non-deterministic on '
          'Windows (Bluetooth SPP ports). The caller-chosen / first port must '
          'go through selectSerialPort().',
    );
    expect(source, contains('selectSerialPort(names, requested: serialPortName)'));
  });
}
