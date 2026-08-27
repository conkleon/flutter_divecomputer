import 'package:dive_computer/types/ble_profile.dart';
import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:test/test.dart';

void main() {
  test('BleScanResult carries the matched profile, or null', () {
    const profile = BleProfile(
      namePattern: 'Test',
      serviceUuid: 's',
      writeCharUuid: 'w',
      notifyCharUuid: 'n',
      writeWithResponse: false,
    );
    final matched =
        BleScanResult(id: 'abc', name: 'Test Device', rssi: -60, profile: profile);
    final unmatched =
        BleScanResult(id: 'def', name: 'Other Device', rssi: -70, profile: null);

    expect(matched.profile, profile);
    expect(unmatched.profile, isNull);
    expect(matched.toString(), contains('Test Device'));
  });
}
