import 'dart:io';
import 'package:test/test.dart';

void main() {
  final src = File('lib/framework/dive_computer_ffi.dart').readAsStringSync();

  test('bluetoothDevices enumerates via dc_bluetooth_iterator_new', () {
    expect(src, contains('static List<BtDevice> bluetoothDevices('));
    expect(src, contains('dc_bluetooth_iterator_new'));
    expect(src, contains('dc_bluetooth_device_get_name'));
    expect(src, contains('dc_bluetooth_device_get_address'));
  });

  test('_connectBluetooth opens via dc_bluetooth_open with port 0', () {
    expect(src, contains('_connectBluetooth('));
    expect(src, contains('dc_bluetooth_str2addr'));
    expect(
      RegExp(r'dc_bluetooth_open\(\s*iostream,\s*context\.value,\s*\w+,\s*0\b')
          .hasMatch(src),
      isTrue,
      reason: 'port must be 0 (SDP auto-resolves the RFCOMM channel)',
    );
  });
}
