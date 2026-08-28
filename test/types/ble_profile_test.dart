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

  group('BleProfiles.known registry', () {
    test('known contains exactly the Mares and Cressi profiles', () {
      expect(BleProfiles.known,
          orderedEquals([BleProfiles.maresBluelink, BleProfiles.cressiGoa]));
    });

    test('Mares BlueLink profile matches its advertised names', () {
      for (final name in const [
        'Mares bluelink pro',
        'Mares Genius',
        'Genius',
        'Mares Sirius',
      ]) {
        expect(BleProfiles.match(name), same(BleProfiles.maresBluelink),
            reason: name);
      }
      expect(BleProfiles.maresBluelink.serviceUuid,
          '544e326b-5b72-c6b0-1c46-41c1bc448118');
      expect(BleProfiles.maresBluelink.vendorHint, 'Mares');
      expect(BleProfiles.maresBluelink.productHint, 'Genius');
      // Characteristics + write mode left to property-based discovery.
      expect(BleProfiles.maresBluelink.writeCharUuid, isNull);
      expect(BleProfiles.maresBluelink.notifyCharUuid, isNull);
      expect(BleProfiles.maresBluelink.writeWithResponse, isNull);
    });

    test('Cressi Goa profile matches GOA_/CARESIO_/bare-model names', () {
      for (final name in const ['GOA_1A2B', 'CARESIO_09', '2_ab12', '13_00ff']) {
        expect(BleProfiles.match(name), same(BleProfiles.cressiGoa),
            reason: name);
      }
      expect(BleProfiles.cressiGoa.serviceUuid,
          '6e400001-b5a3-f393-e0a9-e50e24dc10b8');
      expect(BleProfiles.cressiGoa.vendorHint, 'Cressi');
      expect(BleProfiles.cressiGoa.productHint, 'Goa');
      expect(BleProfiles.cressiGoa.writeCharUuid, isNull);
      expect(BleProfiles.cressiGoa.notifyCharUuid, isNull);
    });

    test('an unrelated device name matches nothing', () {
      expect(BleProfiles.match('Garmin Descent Mk2'), isNull);
      expect(BleProfiles.match('Perdix AI'), isNull);
    });
  });
}
