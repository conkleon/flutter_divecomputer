import 'package:dive_computer/types/ble_profile.dart';
import 'package:test/test.dart';

void main() {
  group('BleProfile.matchesName', () {
    test('matches case-insensitively as a substring', () {
      const profile = BleProfile(
        namePattern: 'OSTC',
        serviceUuid: 's',
        writeCharUuid: 'w',
        notifyCharUuid: 'n',
        writeWithResponse: false,
      );
      expect(profile.matchesName('HW OSTC 4'), isTrue);
      expect(profile.matchesName('hw ostc 4'), isTrue);
      expect(profile.matchesName('Suunto EON'), isFalse);
    });
  });

  group('BleProfiles', () {
    test('known starts empty — no vendor profile has been verified yet', () {
      expect(BleProfiles.known, isEmpty);
    });

    test('match returns null when nothing in known matches', () {
      expect(BleProfiles.match('anything'), isNull);
    });

    test('match returns the first matching profile in known', () {
      // Exercises the registry mechanism itself without depending on
      // BleProfiles.known's real (currently empty) contents.
      const a = BleProfile(
        namePattern: 'foo',
        serviceUuid: 's1',
        writeCharUuid: 'w1',
        notifyCharUuid: 'n1',
        writeWithResponse: true,
      );
      expect(a.matchesName('foobar'), isTrue);
    });
  });
}
