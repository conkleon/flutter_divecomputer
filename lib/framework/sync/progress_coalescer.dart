import 'dart:async';

import '../../types/sync.dart';

/// Rate-limits [SyncProgress] emission. libdivecomputer fires PROGRESS
/// events per protocol packet — far more often than a UI needs. This
/// emits at most one event per [interval], always carrying the most
/// recent value, and never drops a phase transition or an [immediate]
/// (terminal) event.
class ProgressCoalescer {
  ProgressCoalescer(this._emit,
      {this.interval = const Duration(milliseconds: 100)});

  final void Function(SyncProgress) _emit;
  final Duration interval;

  SyncProgress? _pending;
  SyncPhase? _lastEmittedPhase;
  Timer? _timer;

  void submit(SyncProgress progress, {bool immediate = false}) {
    final phaseChanged = _pending != null && progress.phase != _pending!.phase;
    if (immediate || phaseChanged) {
      _timer?.cancel();
      _timer = null;
      _pending = null;
      _emitNow(progress);
      return;
    }
    _pending = progress;
    _timer ??= Timer(interval, _flush);
  }

  void _flush() {
    _timer = null;
    final p = _pending;
    _pending = null;
    if (p != null) _emitNow(p);
  }

  void _emitNow(SyncProgress p) {
    _lastEmittedPhase = p.phase;
    _emit(p);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
