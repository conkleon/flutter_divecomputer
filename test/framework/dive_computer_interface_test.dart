import 'package:dive_computer/framework/dive_computer_interface.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:dive_computer/types/computer.dart';
import 'package:dive_computer/types/sync.dart';
import 'package:test/test.dart';

class _Bare extends DiveComputerInterface {}

void main() {
  final iface = _Bare();
  final computer = Computer('Shearwater', 'Petrel',
      transports: [ComputerTransport.bluetooth]);

  test('bluetoothDevices throws UnimplementedError by default', () {
    final Future<List<BtDevice>> Function(Computer) fn = iface.bluetoothDevices;
    expect(() => fn(computer), throwsUnimplementedError);
  });

  test('requestBluetoothPermissions defaults to true', () async {
    expect(await iface.requestBluetoothPermissions(), isTrue);
  });

  test('the deprecated download signature still accepts a positional address '
      'after the fingerprint', () {
    // Compile-time check: this must not be a syntax error.
    expect(
      // ignore: deprecated_member_use_from_same_package
      () => iface.download(computer, ComputerTransport.bluetooth, 'fp', 'COM7'),
      throwsUnimplementedError,
    );
  });

  test('sync/syncProgress/diveStream throw UnimplementedError by default', () {
    expect(
      () => iface.sync(SyncRequest(
          computer: computer, transport: ComputerTransport.bluetooth)),
      throwsUnimplementedError,
    );
    expect(() => iface.syncProgress, throwsUnimplementedError);
    expect(() => iface.diveStream, throwsUnimplementedError);
  });
}
