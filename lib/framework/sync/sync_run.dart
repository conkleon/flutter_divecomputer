import 'dart:async';

import '../../types/dive.dart';
import '../../types/sync.dart';

/// Orchestrates one `DiveComputer.sync()` run. Pure — no isolate/FFI/IO —
/// so it carries the real test coverage for progress/phase/error mapping
/// that the singleton itself cannot get under `flutter test`.
///
/// The singleton feeds it the messages it receives from the background
/// isolate (`handleProgress` / `handleDive` / `handleDeviceInfo` /
/// `handleResult`) and any transport/isolate error (`handleError`), and
/// awaits [result].
class SyncRun {
  SyncRun({
    required void Function(SyncProgress progress, {required bool immediate})
        onProgress,
    required void Function(Dive dive) onDive,
  })  : _onProgress = onProgress,
        _onDive = onDive;

  final void Function(SyncProgress progress, {required bool immediate})
      _onProgress;
  final void Function(Dive dive) _onDive;

  final _completer = Completer<SyncResult>();
  Future<SyncResult> get result => _completer.future;

  int _divesParsed = 0;
  SyncPhase _phase = SyncPhase.connecting;

  ({int model, int firmware, int serial})? _deviceInfo;
  ({int model, int firmware, int serial})? get deviceInfo => _deviceInfo;

  /// Emits the initial [SyncPhase.connecting] progress event. Call once,
  /// immediately after construction, before any `handle*` message.
  void start() {
    _emit(SyncPhase.connecting, 0, 0, force: true);
  }

  void handleProgress(int current, int maximum) {
    _emit(SyncPhase.reading, current, maximum);
  }

  void handleDive(Dive dive) {
    _onDive(dive);
    _divesParsed++;
    _emit(SyncPhase.parsing, 0, 0);
  }

  void handleDeviceInfo(int model, int firmware, int serial) {
    _deviceInfo = (model: model, firmware: firmware, serial: serial);
  }

  void handleResult(SyncResult result) {
    if (_completer.isCompleted) return;
    _emit(SyncPhase.done, 0, 0, force: true);
    _completer.complete(result);
  }

  void handleError(Object error) {
    if (_completer.isCompleted) return;
    _completer.complete(SyncResult(
      status: SyncStatus.failed,
      divesParsed: _divesParsed,
      divesSkipped: 0,
      fingerprints: const [],
      error: error,
    ));
  }

  void _emit(SyncPhase phase, int current, int maximum, {bool force = false}) {
    final phaseChanged = phase != _phase;
    _phase = phase;
    _onProgress(
      SyncProgress(
        phase: phase,
        current: current,
        maximum: maximum,
        divesParsed: _divesParsed,
      ),
      immediate: force || phaseChanged,
    );
  }
}
