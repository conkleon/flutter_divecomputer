/// Helpers for picking which serial port to open when libdivecomputer's
/// serial iterator hands back several (and sometimes duplicate) COM ports.
///
/// On Windows a Bluetooth-Classic dive computer (e.g. a Shearwater Petrel)
/// pairs as one or more virtual COM ports, and the iterator enumerates every
/// COM port on the machine in a non-deterministic order — so the caller must
/// be able to say which one is the dive computer.
library;

/// Removes duplicate port names, preserving first-seen order.
List<String> dedupeSerialPorts(List<String> ports) => ports.toSet().toList();

/// The port to open, given libdivecomputer's [available] list and an optional
/// caller [requested] choice.
///
/// - [requested] `null`: the first available port (legacy behaviour).
/// - [requested] set and present (case-insensitive): that port, in the exact
///   spelling the iterator reported.
/// - [requested] set but absent: [ArgumentError] listing what is available.
/// - [available] empty: [StateError].
String selectSerialPort(List<String> available, {String? requested}) {
  final ports = dedupeSerialPorts(available);
  if (ports.isEmpty) {
    throw StateError('No serial ports found for this dive computer');
  }
  if (requested == null) return ports.first;
  for (final p in ports) {
    if (p.toLowerCase() == requested.toLowerCase()) return p;
  }
  throw ArgumentError.value(
    requested,
    'requested',
    'serial port "$requested" is not among the ports libdivecomputer '
        'enumerated (${ports.join(', ')})',
  );
}
