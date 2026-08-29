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

  test('_connectBridged is transport-parameterised and used by both bridged '
      'transports', () {
    expect(source, contains('_connectBridged(int bridgeAddress, int transport)'));
    expect(source, isNot(contains('_connectBle(')));
    expect(source,
        contains('_connectBridged(bridgeAddress, dc_transport_t.DC_TRANSPORT_BLE)'));
    expect(
        source,
        contains(
            '_connectBridged(bridgeAddress, dc_transport_t.DC_TRANSPORT_BLUETOOTH)'));
  });

  test('download routes ComputerTransport.bluetooth to bridged (Android) or '
      '_connectBluetooth (Windows)', () {
    final dl = RegExp(r'case ComputerTransport\.bluetooth:(.+?)break;',
            dotAll: true)
        .firstMatch(source)
        ?.group(1);
    expect(dl, isNotNull);
    expect(dl, contains('bridgeAddress != null'));
    expect(dl, contains('_connectBridged(bridgeAddress'));
    expect(dl, contains('_connectBluetooth(computerDescriptor, address)'));
  });
}
