import 'package:dive_computer/dive_computer.dart';

/// libdivecomputer descriptors of the same vendor as [device]'s matched
/// profile that can be driven over BLE. Falls back to every same-vendor
/// descriptor if none carry [ComputerTransport.ble] in their transport
/// bitmask (older descriptor metadata). Empty if the profile has no
/// `vendorHint` or nothing matches.
List<Computer> candidateComputersFor(
    BleScanResult device, List<Computer> supported) {
  final vendor = device.profile?.vendorHint?.toLowerCase();
  if (vendor == null) return const [];
  final sameVendor = supported
      .where((c) => c.vendor.toLowerCase() == vendor)
      .toList(growable: false);
  final ble = sameVendor
      .where((c) => c.transports.contains(ComputerTransport.ble))
      .toList(growable: false);
  // Dedupe: libdivecomputer can expose duplicate vendor+product descriptors,
  // and duplicate DropdownButton items assert in debug builds.
  return (ble.isNotEmpty ? ble : sameVendor).toSet().toList();
}

/// The descriptor to preselect for [device]: the [candidateComputersFor]
/// entry whose product matches the profile's `productHint`, else the first
/// candidate, else null.
Computer? defaultComputerFor(BleScanResult device, List<Computer> supported) {
  final candidates = candidateComputersFor(device, supported);
  if (candidates.isEmpty) return null;
  final hint = device.profile?.productHint?.toLowerCase();
  for (final c in candidates) {
    if (c.product.toLowerCase() == hint) return c;
  }
  return candidates.first;
}

String _num(num? v, {int frac = 1, String unit = ''}) =>
    v == null ? '—' : '${v.toStringAsFixed(frac)}$unit';

String _dur(int? seconds) {
  if (seconds == null) return '—';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _date(DateTime? dt) => dt == null
    ? '—'
    : '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';

String formatDiveSummary(Dive dive) =>
    '${_date(dive.dateTime)}  •  ${_dur(dive.diveTime)}  •  '
    'max ${_num(dive.maxDepth, unit: ' m')}  •  '
    'temp ${_num(dive.temperatureMinimum, unit: ' °C')} – ${_num(dive.temperatureMaximum, unit: ' °C')}  •  '
    'gas ${dive.gasmixes?.length ?? 0}  •  ${dive.samples.length} samples';

List<String> describeDiveVerbose(Dive dive) {
  final salinity = dive.salinity;
  final gasmixes = dive.gasmixes ?? const <Gasmix>[];
  final tanks = dive.tanks ?? const <Tank>[];
  final lines = <String>[
    'Dive ${dive.hash}',
    '  date        ${_date(dive.dateTime)}',
    '  duration    ${_dur(dive.diveTime)}',
    '  maxDepth    ${_num(dive.maxDepth, unit: ' m')}',
    '  avgDepth    ${_num(dive.avgDepth, unit: ' m')}',
    '  atmospheric ${_num(dive.atmospheric, frac: 3, unit: ' bar')}',
    '  tempSurface ${_num(dive.temperatureSurface, unit: ' °C')}',
    '  tempMin     ${_num(dive.temperatureMinimum, unit: ' °C')}',
    '  tempMax     ${_num(dive.temperatureMaximum, unit: ' °C')}',
    '  diveMode    ${dive.diveMode ?? '—'}',
    if (salinity == null)
      '  salinity    —'
    else
      '  salinity    type=${salinity.salinity} density=${salinity.density}',
    '  gasmixes    ${dive.gasmixes?.length ?? 0}',
    for (var i = 0; i < gasmixes.length; i++)
      '  gasmix[$i]  o2=${gasmixes[i].oxygen} he=${gasmixes[i].helium} '
          'n2=${gasmixes[i].nitrogen} usage=${gasmixes[i].usage}',
    '  tanks       ${dive.tanks?.length ?? 0}',
    for (var i = 0; i < tanks.length; i++)
      '  tank[$i]  begin=${tanks[i].beginpressure} end=${tanks[i].endpressure} '
          'work=${tanks[i].workpressure} gasmix=${tanks[i].gasmix} '
          'usage=${tanks[i].usage}',
    '  samples     ${dive.samples.length}',
  ];
  for (final s in dive.samples) {
    final parts = <String>['t=${s.time}s'];
    if (s.depth != null) parts.add('depth=${s.depth!.toStringAsFixed(2)}m');
    if (s.temperature != null) {
      parts.add('temp=${s.temperature!.toStringAsFixed(1)}°C');
    }
    if (s.rbt != null) parts.add('rbt=${s.rbt}');
    if (s.heartbeat != null) parts.add('hr=${s.heartbeat}');
    if (s.bearing != null) parts.add('bearing=${s.bearing}');
    if (s.gasmix != null) parts.add('gasmix=${s.gasmix}');
    if (s.setpoint != null) parts.add('setpoint=${s.setpoint}');
    if (s.cns != null) parts.add('cns=${s.cns}');
    if (s.ppo2 != null) parts.add('ppo2=${s.ppo2!.value}');
    if (s.vendor != null) {
      parts.add('vendor(type=${s.vendor!.type},size=${s.vendor!.size})');
    }
    if (s.deco != null) {
      parts.add('deco(type=${s.deco!.type},time=${s.deco!.time},'
          'depth=${s.deco!.depth},tts=${s.deco!.tts})');
    }
    for (final p in s.pressure ?? const []) {
      parts.add('pressure(tank=${p.tank},bar=${p.pressure})');
    }
    for (final e in s.events ?? const []) {
      parts.add('event(type=${e.type},time=${e.time},'
          'flags=${e.flags},value=${e.value})');
    }
    lines.add('  sample ${parts.join(' ')}');
  }
  return lines;
}
