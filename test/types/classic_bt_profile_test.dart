import 'package:dive_computer/types/classic_bt_profile.dart';
import 'package:test/test.dart';

void main() {
  group('ClassicBtProfile.matchesName', () {
    test('case-insensitive substring match on any pattern', () {
      const p = ClassicBtProfile(namePatterns: ['Petrel', 'Perdix']);
      expect(p.matchesName('Petrel'), isTrue);
      expect(p.matchesName('PETREL'), isTrue);
      expect(p.matchesName('Shearwater Perdix'), isTrue);
      expect(p.matchesName('Teric'), isFalse);
    });

    test('empty patterns never match', () {
      const p = ClassicBtProfile(namePatterns: []);
      expect(p.matchesName('anything'), isFalse);
    });
  });

  group('ClassicBtProfiles registry', () {
    test('shearwater matches the Classic-BT Shearwaters only', () {
      for (final n in const ['Predator', 'Petrel', 'Petrel 2', 'NERD', 'Perdix']) {
        expect(ClassicBtProfiles.match(n), same(ClassicBtProfiles.shearwater),
            reason: n);
      }
      // BLE-only Shearwaters and unrelated names must NOT match here.
      for (final n in const ['Teric', 'Peregrine', 'Garmin', 'Suunto EON']) {
        expect(ClassicBtProfiles.match(n), isNull, reason: n);
      }
      expect(ClassicBtProfiles.match('Garmin Descent'), isNull);
    });

    test('shearwater hints', () {
      expect(ClassicBtProfiles.shearwater.vendorHint, 'Shearwater');
      expect(ClassicBtProfiles.shearwater.productHint, 'Petrel');
    });

    test('known contains exactly the shearwater profile', () {
      expect(ClassicBtProfiles.known, [ClassicBtProfiles.shearwater]);
    });
  });
}
