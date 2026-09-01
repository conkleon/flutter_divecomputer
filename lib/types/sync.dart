import 'computer.dart';

/// A request to download dives from one dive computer over one transport.
/// Replaces [DiveComputer.download]'s positional-optional parameters.
class SyncRequest {
  SyncRequest({
    required this.computer,
    required this.transport,
    this.endpoint,
    this.lastFingerprint,
    this.knownFingerprints,
  });

  final Computer computer;
  final ComputerTransport transport;

  /// COM port (serial), Bluetooth MAC (Classic), or BLE device id.
  /// May be null only for the single-serial-port auto-pick. For
  /// [ComputerTransport.ble], null falls back to a device set by a prior
  /// (deprecated) `connectBle()`.
  final String? endpoint;

  /// Sync ONLY dives newer than the dive with this fingerprint hash. The
  /// device stops transmitting when it reaches it (a real early stop).
  /// Use for "top up my log with new dives".
  final String? lastFingerprint;

  /// Dive fingerprint hashes the caller already holds. The device still
  /// transfers every dive's bytes, but parse + `diveStream` emit are
  /// skipped for these. Poor-man's resume for an interrupted full
  /// backfill. Combinable with [lastFingerprint].
  final Set<String>? knownFingerprints;
}

/// Coarse stage of a running sync.
enum SyncPhase { connecting, reading, parsing, done }

/// A progress snapshot for the running sync, delivered on
/// `DiveComputer.syncProgress`.
class SyncProgress {
  const SyncProgress({
    required this.phase,
    required this.current,
    required this.maximum,
    required this.divesParsed,
  });

  final SyncPhase phase;

  /// Raw byte counts from libdivecomputer's `DC_EVENT_PROGRESS`. [maximum]
  /// may be 0 before the device reports a total, and may grow. Guard
  /// before dividing — or use [fraction].
  final int current, maximum;

  /// Running count of dives emitted on `DiveComputer.diveStream` this run.
  final int divesParsed;

  /// [current] / [maximum], or null when [maximum] is 0.
  double? get fraction => maximum > 0 ? current / maximum : null;
}

/// How a sync ended.
enum SyncStatus { completed, stoppedAtKnownDive, failed }

/// Device identity + firmware, reported once per run by libdivecomputer's
/// `DC_EVENT_DEVINFO`. Absent when the device/backend does not emit it.
class DeviceInfo {
  const DeviceInfo({
    required this.model,
    required this.firmware,
    required this.serial,
  });

  final int model, firmware, serial;
}

/// The outcome of a [SyncRequest]. Dives themselves arrive only on
/// `DiveComputer.diveStream`; this carries counts and identifiers.
class SyncResult {
  const SyncResult({
    required this.status,
    required this.divesParsed,
    required this.divesSkipped,
    required this.fingerprints,
    this.error,
    this.deviceInfo,
  });

  final SyncStatus status;

  /// Dives emitted on `diveStream` this run (excludes [knownFingerprints] hits).
  final int divesParsed;

  /// Dives whose fingerprint matched [SyncRequest.knownFingerprints] — bytes
  /// transferred, parse skipped.
  final int divesSkipped;

  /// Every dive fingerprint hash seen this run (parsed + skipped), newest
  /// first. Persist as the next run's [SyncRequest.knownFingerprints].
  final List<String> fingerprints;

  /// Set when [status] is [SyncStatus.failed], null otherwise. A failure that
  /// originated on the background isolate (an unparseable dive) arrives as a
  /// message `String` rather than the original exception object — only
  /// sendable values cross the isolate port.
  final Object? error;

  /// Device identity for this run, or null if `DC_EVENT_DEVINFO` did not fire.
  /// A `serial` of 0 means "reported but unset" — callers treat it as absent.
  final DeviceInfo? deviceInfo;
}
