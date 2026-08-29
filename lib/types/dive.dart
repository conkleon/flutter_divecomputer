class Dive {
  final String hash;

  final int? diveTime, diveMode;
  final double? maxDepth,
      avgDepth,
      atmospheric,
      temperatureSurface,
      temperatureMinimum,
      temperatureMaximum;

  final DateTime? dateTime;
  final Salinity? salinity;
  final List<Gasmix>? gasmixes;
  final List<Tank>? tanks;

  final List<Sample> samples;

  Dive(
    this.hash, {
    required this.diveTime,
    required this.maxDepth,
    required this.avgDepth,
    required this.atmospheric,
    required this.temperatureSurface,
    required this.temperatureMinimum,
    required this.temperatureMaximum,
    required this.diveMode,
    required this.dateTime,
    required this.salinity,
    required this.gasmixes,
    required this.tanks,
    required this.samples,
  });

  /// A plain JSON map of every field. Stable enough to persist a downloaded
  /// dive log to disk and read it back elsewhere (it is not a libdivecomputer
  /// or UDDF format — just this plugin's `Dive` shape).
  Map<String, dynamic> toJson() => {
        'hash': hash,
        'diveTime': diveTime,
        'diveMode': diveMode,
        'maxDepth': maxDepth,
        'avgDepth': avgDepth,
        'atmospheric': atmospheric,
        'temperatureSurface': temperatureSurface,
        'temperatureMinimum': temperatureMinimum,
        'temperatureMaximum': temperatureMaximum,
        'dateTime': dateTime?.toIso8601String(),
        'salinity': salinity?.toJson(),
        'gasmixes': gasmixes?.map((g) => g.toJson()).toList(),
        'tanks': tanks?.map((t) => t.toJson()).toList(),
        'samples': samples.map((s) => s.toJson()).toList(),
      };

  @override
  String toString() {
    return 'Dive{hash: $hash, diveTime: $diveTime, maxDepth: $maxDepth} samples: ${samples.length}';
  }
}

enum Usage { none, oxygen, diluent, sidemount }

class Gasmix {
  final int index, usage;
  final double helium, oxygen, nitrogen;
  Gasmix(this.index, this.usage,
      {required this.helium, required this.oxygen, required this.nitrogen});

  Map<String, dynamic> toJson() => {
        'index': index,
        'usage': usage,
        'helium': helium,
        'oxygen': oxygen,
        'nitrogen': nitrogen,
      };
}

class Tank {
  final int gasmix, usage;
  final double workpressure, beginpressure, endpressure;
  Tank(this.gasmix, this.usage,
      {required this.workpressure,
      required this.beginpressure,
      required this.endpressure});

  Map<String, dynamic> toJson() => {
        'gasmix': gasmix,
        'usage': usage,
        'workpressure': workpressure,
        'beginpressure': beginpressure,
        'endpressure': endpressure,
      };
}

class Salinity {
  final int salinity;
  final double density;
  Salinity(this.salinity, this.density);

  Map<String, dynamic> toJson() => {'salinity': salinity, 'density': density};
}

class Sample {
  final int time;
  int? rbt, heartbeat, bearing, gasmix;
  double? depth, temperature, setpoint, cns;
  PPO2? ppo2;
  Deco? deco;
  Vendor? vendor;
  List<Pressure>? pressure;
  List<Event>? events;

  Sample(this.time);

  Map<String, dynamic> toJson() => {
        'time': time,
        if (depth != null) 'depth': depth,
        if (temperature != null) 'temperature': temperature,
        if (rbt != null) 'rbt': rbt,
        if (heartbeat != null) 'heartbeat': heartbeat,
        if (bearing != null) 'bearing': bearing,
        if (gasmix != null) 'gasmix': gasmix,
        if (setpoint != null) 'setpoint': setpoint,
        if (cns != null) 'cns': cns,
        if (ppo2 != null) 'ppo2': ppo2!.toJson(),
        if (deco != null) 'deco': deco!.toJson(),
        if (vendor != null) 'vendor': vendor!.toJson(),
        if (pressure != null)
          'pressure': pressure!.map((p) => p.toJson()).toList(),
        if (events != null) 'events': events!.map((e) => e.toJson()).toList(),
      };

  @override
  String toString() {
    return 'Sample{time: $time, depth: $depth}';
  }
}

class Event {
  final int type, time, flags, value;
  Event(this.type, this.time, this.flags, this.value);

  Map<String, dynamic> toJson() =>
      {'type': type, 'time': time, 'flags': flags, 'value': value};
}

class Vendor {
  final int type, size;
  Vendor(this.type, this.size);

  Map<String, dynamic> toJson() => {'type': type, 'size': size};
}

class PPO2 {
  final int sensor;
  final double value;
  PPO2(this.sensor, this.value);

  Map<String, dynamic> toJson() => {'sensor': sensor, 'value': value};
}

class Deco {
  final int type, time, tts;
  final double depth;
  Deco(this.type, this.time, this.depth, this.tts);

  Map<String, dynamic> toJson() =>
      {'type': type, 'time': time, 'depth': depth, 'tts': tts};
}

class Pressure {
  final int tank;
  final double pressure;
  Pressure(this.tank, this.pressure);

  Map<String, dynamic> toJson() => {'tank': tank, 'pressure': pressure};
}
