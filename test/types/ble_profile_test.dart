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
  });

  group('BleProfiles.known registry', () {
    test('known contains the Shearwater, Mares and Cressi profiles', () {
      expect(
          BleProfiles.known,
          orderedEquals([
            BleProfiles.shearwaterPerdix3,
            BleProfiles.shearwater,
            BleProfiles.maresBluelink,
            BleProfiles.cressiGoa,
          ]));
    });

    test('Shearwater profile matches its advertised names', () {
      for (final name in const [
        'Predator',
        'Petrel',
        'Petrel 2',
        'Petrel 3',
        'Perdix',
        'Perdix AI',
        'Perdix 2',
        'Teric',
        'Peregrine',
        'NERD',
        'NERD 2',
        'Tern',
      ]) {
        expect(BleProfiles.match(name), same(BleProfiles.shearwater),
            reason: name);
      }
      expect(BleProfiles.shearwater.serviceUuid,
          'fe25c237-0ece-443c-b0aa-e02033e7029d');
      expect(BleProfiles.shearwater.vendorHint, 'Shearwater');
      expect(BleProfiles.shearwater.productHint, 'Petrel 2');
      // Characteristics + write mode left to property-based discovery.
      expect(BleProfiles.shearwater.writeCharUuid, isNull);
      expect(BleProfiles.shearwater.notifyCharUuid, isNull);
      expect(BleProfiles.shearwater.writeWithResponse, isNull);
    });

    test('Perdix 3 resolves to its own profile, not the general one', () {
      // 'Perdix' is a substring of 'Perdix 3', so shearwaterPerdix3 must be
      // matched first — it carries the distinct Perdix 3 GATT service UUID.
      expect(BleProfiles.match('Perdix 3'), same(BleProfiles.shearwaterPerdix3));
      expect(BleProfiles.shearwaterPerdix3.serviceUuid,
          '1aa44039-1667-4b29-87cc-dfecaaf31d97');
      expect(BleProfiles.shearwaterPerdix3.vendorHint, 'Shearwater');
      expect(BleProfiles.shearwaterPerdix3.productHint, 'Perdix 2');
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
      for (final name in const [
        'GOA_1A2B',
        'CARESIO_09',
        '2_ab12',
        '13_00ff',
        '2_AB12', // uppercase hex — regex is case-insensitive
      ]) {
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
      expect(BleProfiles.match('Suunto EON Steel'), isNull);
    });
  });
}
