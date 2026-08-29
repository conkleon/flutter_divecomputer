import 'package:dive_computer/dive_computer.dart';
import 'package:dive_computer_example/ble_download_support.dart';
import 'package:flutter_test/flutter_test.dart';

BleScanResult _scan(BleProfile profile) =>
    BleScanResult(id: 'x', name: 'n', rssi: -50, profile: profile);

void main() {
  // NB: Computer's constructor is not const (see lib/types/computer.dart),
  // so these are `final`, not `const` as the task brief had them.
  final maresBle = Computer('Mares', 'Genius',
      transports: [ComputerTransport.ble]);
  final maresQuadBle = Computer('Mares', 'Quad',
      transports: [ComputerTransport.ble, ComputerTransport.serial]);
  final maresSerialOnly = Computer('Mares', 'Puck',
      transports: [ComputerTransport.serial]);
  final cressiSerialOnly = Computer('Cressi', 'Leonardo',
      transports: [ComputerTransport.serial]);
  final supported = [maresBle, maresQuadBle, maresSerialOnly, cressiSerialOnly];

  group('candidateComputersFor', () {
    test('same-vendor BLE-capable computers', () {
      final c = candidateComputersFor(_scan(BleProfiles.maresBluelink), supported);
      expect(c, containsAll([maresBle, maresQuadBle]));
      expect(c, isNot(contains(maresSerialOnly)));
      expect(c, isNot(contains(cressiSerialOnly)));
    });

    test('falls back to all same-vendor when none advertise BLE', () {
      final c = candidateComputersFor(
          _scan(BleProfiles.cressiGoa), [cressiSerialOnly, maresBle]);
      expect(c, [cressiSerialOnly]);
    });

    test('empty when the profile has no vendorHint', () {
      const noHint = BleProfile(namePatterns: ['x'], serviceUuid: 's');
      expect(candidateComputersFor(_scan(noHint), supported), isEmpty);
    });

    test('dedupes duplicate vendor+product descriptors', () {
      final dupA = Computer('Mares', 'Genius',
          transports: [ComputerTransport.ble]);
      final dupB = Computer('Mares', 'Genius',
          transports: [ComputerTransport.ble]);
      final c = candidateComputersFor(
          _scan(BleProfiles.maresBluelink), [dupA, dupB]);
      expect(c, hasLength(1));
    });
  });

  group('defaultComputerFor', () {
    test('prefers the productHint match', () {
      expect(defaultComputerFor(_scan(BleProfiles.maresBluelink), supported),
          maresBle); // productHint 'Genius'
    });

    test('first candidate when productHint does not match', () {
      const profile = BleProfile(
          namePatterns: ['x'], serviceUuid: 's',
          vendorHint: 'Mares', productHint: 'Nonesuch');
      expect(defaultComputerFor(_scan(profile), supported), maresBle);
    });

    test('null when nothing matches the vendor', () {
      const profile = BleProfile(
          namePatterns: ['x'], serviceUuid: 's', vendorHint: 'Suunto');
      expect(defaultComputerFor(_scan(profile), supported), isNull);
    });
  });

  group('bluetoothCandidates', () {
    test('filters bonded devices by the Shearwater Classic-BT profile', () {
      const petrel = BtDevice('Petrel', '00:13:43:0A:A0:6F');
      const earbuds = BtDevice('Baseus Encok', '11:22:33:44:55:66');
      final out = bluetoothCandidates(
          isShearwater: true, bonded: [petrel, earbuds]);
      expect(out, [petrel]);
    });

    test('no profile -> all bonded devices', () {
      const a = BtDevice('A', '00:00:00:00:00:01');
      expect(bluetoothCandidates(isShearwater: false, bonded: [a]), [a]);
    });
  });

  group('formatDiveSummary', () {
    test('renders fields and dashes for nulls', () {
      final dive = Dive('AABB',
          diveTime: 125, maxDepth: 18.4, avgDepth: null, atmospheric: null,
          temperatureSurface: null, temperatureMinimum: 12.0,
          temperatureMaximum: 21.0, diveMode: null,
          dateTime: DateTime(2026, 5, 1, 9, 30),
          salinity: null, gasmixes: null, tanks: null, samples: const []);
      final s = formatDiveSummary(dive);
      expect(s, contains('2026-05-01'));
      expect(s, contains('2:05')); // 125 s
      expect(s, contains('18.4'));
      // Both temp ends carry spacing and a unit.
      expect(s, contains('temp 12.0 °C – 21.0 °C'));
    });

    test('renders — for null date, duration and max depth', () {
      final dive = Dive('AABB',
          diveTime: null, maxDepth: null, avgDepth: null, atmospheric: null,
          temperatureSurface: null, temperatureMinimum: null,
          temperatureMaximum: null, diveMode: null, dateTime: null,
          salinity: null, gasmixes: null, tanks: null, samples: const []);
      final s = formatDiveSummary(dive);
      expect(s, contains('—'));
      expect(s, contains('max —'));
      expect(s, contains('gas 0'));
      expect(s, contains('0 samples'));
    });
  });

  group('describeDiveVerbose', () {
    test('one line per sample plus the dive header lines', () {
      final dive = Dive('AABB',
          diveTime: 60, maxDepth: 5.0, avgDepth: 3.0, atmospheric: 1.01,
          temperatureSurface: 20.0, temperatureMinimum: 18.0,
          temperatureMaximum: 20.0, diveMode: 0,
          dateTime: DateTime(2026, 1, 1),
          salinity: null, gasmixes: null, tanks: null,
          samples: [Sample(0)..depth = 0.0, Sample(10)..depth = 5.0]);
      final lines = describeDiveVerbose(dive);
      expect(lines.first, contains('AABB'));
      expect(lines.where((l) => l.contains('sample t=')).length, 2);
      // null Dive field renders a dash line
      expect(lines, contains('  salinity    —'));
    });

    test('expands salinity, one line per gasmix and one line per tank', () {
      final dive = Dive('EEFF',
          diveTime: 45, maxDepth: 6.0, avgDepth: 3.0, atmospheric: 1.0,
          temperatureSurface: null, temperatureMinimum: null,
          temperatureMaximum: null, diveMode: null,
          dateTime: DateTime(2026, 4, 4),
          salinity: Salinity(1, 1.03),
          gasmixes: [
            Gasmix(0, 0, helium: 0.0, oxygen: 0.32, nitrogen: 0.68),
          ],
          tanks: [
            Tank(0, 0,
                workpressure: 200.0, beginpressure: 210.0, endpressure: 50.0),
          ],
          samples: const []);
      final lines = describeDiveVerbose(dive);
      expect(lines, contains('  salinity    type=1 density=1.03'));
      expect(
          lines.firstWhere((l) => l.contains('gasmix[0]')),
          allOf(contains('o2=0.32'), contains('he=0.0'), contains('n2=0.68'),
              contains('usage=0')));
      expect(
          lines.firstWhere((l) => l.contains('tank[0]')),
          allOf(contains('begin=210.0'), contains('end=50.0'),
              contains('work=200.0'), contains('gasmix=0'),
              contains('usage=0')));
    });

    test('dumps vendor, deco time and event time on a sample', () {
      final dive = Dive('CCDD',
          diveTime: 30, maxDepth: 4.0, avgDepth: 2.0, atmospheric: 1.0,
          temperatureSurface: null, temperatureMinimum: null,
          temperatureMaximum: null, diveMode: null,
          dateTime: DateTime(2026, 3, 3),
          salinity: null, gasmixes: null, tanks: null,
          samples: [
            Sample(5)
              ..depth = 4.0
              ..vendor = Vendor(7, 12)
              ..deco = Deco(1, 90, 3.0, 120)
              ..events = [Event(2, 15, 4, 8)]
          ]);
      final lines = describeDiveVerbose(dive);
      final sampleLine = lines.firstWhere((l) => l.contains('sample t='));
      expect(sampleLine, contains('vendor(type=7,size=12)'));
      expect(sampleLine, contains('deco(type=1,time=90,depth=3.0,tts=120)'));
      expect(sampleLine, contains('event(type=2,time=15,flags=4,value=8)'));
    });
  });
}
