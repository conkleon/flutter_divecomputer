import 'package:dive_computer/types/ble_profile.dart';
import 'package:test/test.dart';

void main() {
  group('BleProfile.matchesName', () {
    test('matches any of several patterns, case-insensitively, as substrings',
        () {
      const profile = BleProfile(
        namePatterns: ['Mares bluelink pro', 'Genius'],
        serviceUuid: 's',
      );
      expect(profile.matchesName('Mares bluelink pro'), isTrue);
      expect(profile.matchesName('MARES BLUELINK PRO'), isTrue);
      expect(profile.matchesName('Mares Genius'), isTrue);
      expect(profile.matchesName('Suunto EON'), isFalse);
    });

    test('matches via nameRegExp when provided', () {
      final profile = BleProfile(
        namePatterns: const ['GOA_'],
        nameRegExp: RegExp(r'^[1-9][0-9]?_[0-9a-f]{4}$'),
        serviceUuid: 's',
      );
      expect(profile.matchesName('GOA_1234'), isTrue); // substring
      expect(profile.matchesName('2_ab12'), isTrue); // regex
      expect(profile.matchesName('20_ffff'), isTrue); // regex
      expect(profile.matchesName('0_ab12'), isFalse); // regex: leading 0
      expect(profile.matchesName('2_abardvark'), isFalse);
    });

    test('empty patterns and null regex never match', () {
      const profile = BleProfile(namePatterns: [], serviceUuid: 's');
      expect(profile.matchesName(''), isFalse);
      expect(profile.matchesName('anything'), isFalse);
    });
  });

  group('BleProfiles.match', () {
    test('returns null when nothing in known matches', () {
      expect(BleProfiles.match('Suunto EON Steel'), isNull);
    });

    test('returns the first matching profile in known', () {
      const a = BleProfile(namePatterns: ['foo'], serviceUuid: 's1');
      expect(a.matchesName('foobar'), isTrue);
    });
  });
}
