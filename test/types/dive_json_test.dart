import 'dart:convert';

import 'package:dive_computer/types/dive.dart';
import 'package:test/test.dart';

void main() {
  test('Dive.toJson round-trips through jsonEncode with nested types', () {
    final dive = Dive(
      'AABBCC',
      diveTime: 3600,
      maxDepth: 30.5,
      avgDepth: 18.0,
      atmospheric: 1.013,
      temperatureSurface: 25.0,
      temperatureMinimum: 12.0,
      temperatureMaximum: 25.0,
      diveMode: 0,
      dateTime: DateTime.utc(2026, 8, 30, 9, 15),
      salinity: Salinity(1, 1.03),
      gasmixes: [Gasmix(0, 0, helium: 0.0, oxygen: 0.21, nitrogen: 0.79)],
      tanks: [
        Tank(0, 0, workpressure: 232.0, beginpressure: 210.0, endpressure: 70.0)
      ],
      samples: [
        Sample(0)..depth = 0.0,
        Sample(10)
          ..depth = 5.0
          ..temperature = 24.0
          ..ppo2 = PPO2(0, 1.2)
          ..deco = Deco(1, 60, 3.0, 120)
          ..vendor = Vendor(7, 12)
          ..pressure = [Pressure(0, 200.0)]
          ..events = [Event(2, 15, 4, 8)],
      ],
    );

    final json = jsonEncode(dive.toJson());
    final back = jsonDecode(json) as Map<String, dynamic>;

    expect(back['hash'], 'AABBCC');
    expect(back['dateTime'], '2026-08-30T09:15:00.000Z');
    expect(back['salinity'], {'salinity': 1, 'density': 1.03});
    expect((back['gasmixes'] as List).single['oxygen'], 0.21);
    expect((back['tanks'] as List).single['beginpressure'], 210.0);
    expect((back['samples'] as List).length, 2);
    final s1 = (back['samples'] as List)[1] as Map<String, dynamic>;
    expect(s1['time'], 10);
    expect(s1['ppo2'], {'sensor': 0, 'value': 1.2});
    expect(s1['deco'], {'type': 1, 'time': 60, 'depth': 3.0, 'tts': 120});
    expect((s1['pressure'] as List).single, {'tank': 0, 'pressure': 200.0});
    expect((s1['events'] as List).single,
        {'type': 2, 'time': 15, 'flags': 4, 'value': 8});
  });

  test('omits null sample fields', () {
    final s = Sample(5).toJson();
    expect(s.keys, ['time']);
  });

  test('null salinity/gasmixes/tanks/dateTime serialise as null', () {
    final dive = Dive('X',
        diveTime: null,
        maxDepth: null,
        avgDepth: null,
        atmospheric: null,
        temperatureSurface: null,
        temperatureMinimum: null,
        temperatureMaximum: null,
        diveMode: null,
        dateTime: null,
        salinity: null,
        gasmixes: null,
        tanks: null,
        samples: const []);
    final j = dive.toJson();
    expect(j['dateTime'], isNull);
    expect(j['salinity'], isNull);
    expect(j['gasmixes'], isNull);
    expect(j['samples'], isEmpty);
    // still encodable
    jsonEncode(j);
  });
}
