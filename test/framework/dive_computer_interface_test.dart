import 'package:dive_computer/framework/dive_computer_interface.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:dive_computer/types/computer.dart';
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

  test('download signature accepts a positional address after fingerprint', () {
    // Compile-time check: this must not be a syntax error.
    expect(
      () => iface.download(computer, ComputerTransport.bluetooth, 'fp', 'COM7'),
      throwsUnimplementedError,
    );
  });
}
