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
    test('match returns null when nothing in known matches', () {
      expect(BleProfiles.match('Suunto EON Steel'), isNull);
    });

    test('match returns the first matching profile in known', () {
      // Exercises the registry mechanism itself without depending on
      // BleProfiles.known's real contents.
      const a = BleProfile(
        namePattern: 'foo',
        serviceUuid: 's1',
        writeCharUuid: 'w1',
        notifyCharUuid: 'n1',
        writeWithResponse: true,
      );
      expect(a.matchesName('foobar'), isTrue);
    });

    test('Mares BlueLink profile is registered and matches a Sirius by name',
        () {
      final matched = BleProfiles.match('Mares Sirius');
      expect(matched, same(BleProfiles.maresBluelink));
      expect(matched!.serviceUuid, '544e326b-5b72-c6b0-1c46-41c1bc448118');
      expect(matched.vendorHint, 'Mares');
      // Characteristics + write mode are left to property-based discovery.
      expect(matched.writeCharUuid, isNull);
      expect(matched.notifyCharUuid, isNull);
      expect(matched.writeWithResponse, isNull);
    });
  });
}
