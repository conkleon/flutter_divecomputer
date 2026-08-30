# SP1 — Unified sync API + progress + pump swap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `download()`'s six positional args with `DiveComputer.sync(SyncRequest) -> Future<SyncResult>` driving broadcast `syncProgress` / `diveStream`, wire libdivecomputer's real progress events into `SyncProgress`, and replace the `Timer.periodic(4ms)` mailbox pump with an event-driven port message.

**Architecture:** New pure units (`ProgressCoalescer`, `SyncRun`) hold all the testable per-run orchestration so the un-testable singleton + FFI layers stay thin. A `BridgedTransport` base absorbs the ~80% shared BLE/RFCOMM bridge-servicing code and swaps its 4 ms poll for a `WriteReady` port message from the background isolate's `write` callback, backed by a 250 ms safety-net timer. `download()` / `connectBle()` / `disconnectBle()` become `@Deprecated` shims over `sync()`.

**Tech Stack:** Dart / Flutter plugin, `dart:ffi` + `dart:isolate`, `package:test` + `package:flutter_test` (with `fakeAsync`), libdivecomputer via generated FFI bindings, `universal_ble`, Android RFCOMM method channel.

**Spec:** `docs/superpowers/specs/2026-08-30-sp1-unified-sync-api-design.md` — read it alongside this plan.

## Global Constraints

- **Dart SDK floor `>=3.2.3 <4.0.0`, Flutter `>=3.3.0`** (`pubspec.yaml`) — no newer language features.
- **No new dependencies.** `fake_async` is already transitively available via `flutter_test`; use it through `package:flutter_test`.
- **The singleton (`dive_computer_isolate.dart`) and FFI layer (`dive_computer_ffi.dart`) cannot be exercised under `flutter test`** — the singleton spawns a background isolate that `DynamicLibrary.open`s the native lib. Tests for those two files are **source-level regex/string guards** using `package:test` and `File(...).readAsStringSync()`, exactly like the existing `test/framework/dive_computer_isolate_test.dart` and `test/framework/dive_computer_ffi_cap_test.dart`. Do not attempt to instantiate `DiveComputer.instance` in a test.
- **All real behavioural coverage of sync orchestration lives in the pure units** (`ProgressCoalescer`, `SyncRun`, `BridgedTransport`) plus the on-device manual test. Keep those units free of `dart:isolate` / `dart:ffi` / `dart:io` imports so they run under `flutter test`.
- **Never `git push`** — the user pushes. Commit locally after every task.
- **`@Deprecated` message wording, verbatim:** `'Use sync(SyncRequest). Will be removed in a future major version.'`
- **libdivecomputer FFI event bindings already exist** in `lib/framework/dive_computer_ffi_bindings_generated.dart` (`dc_device_set_events`, `dc_event_type_t`, `dc_event_progress_t`, `dc_event_devinfo_t`, `dc_event_callback_t`). No `ffigen` regeneration.
- **Existing flaky test `test/framework/ble/ble_bridge_state_test.dart` (the `waitForInbound` timing test) stays untouched** — do not "fix" or mask it as part of this work.
- Run the full suite with `flutter test` from the `flutter_divecomputer/` directory.

## File Structure

**New:**
| Path | Responsibility |
|---|---|
| `lib/types/sync.dart` | `SyncRequest`, `SyncProgress`, `SyncPhase`, `SyncResult`, `SyncStatus` value types. No logic beyond `SyncProgress.fraction`. |
| `lib/framework/sync/progress_coalescer.dart` | Rate-limits `SyncProgress` emission to ≤ 1 per interval; always passes phase-changes and the terminal event. Pure. |
| `lib/framework/sync/sync_run.dart` | Orchestrates one sync run: tracks `divesParsed` / phase, feeds the dive + progress sinks, owns the `Completer<SyncResult>`, maps errors to `SyncStatus.failed`. Pure. |
| `lib/framework/sync/write_signal.dart` | `WriteReady(seq)` cross-isolate message + the background-isolate `SendPort` holder the bridge `write` callback posts to. |
| `lib/framework/bridged_transport.dart` | Base class: `attachBridge`, inbound pump into the ring buffer, message-driven + safety-net-timer `serviceMailbox()`, teardown-before-dispose ordering, dangling-bridge guards. |
| `doc/migration/1.x-to-2.0.md` | `download()` → `sync()` migration guide. |
| `test/types/sync_test.dart` | Value-type tests. |
| `test/framework/sync/progress_coalescer_test.dart` | Coalescer tests (fakeAsync). |
| `test/framework/sync/sync_run_test.dart` | Orchestrator tests. |
| `test/framework/bridged_transport_test.dart` | Base-class tests with a fake subclass. |

**Modified:**
| Path | Change |
|---|---|
| `lib/dive_computer.dart` | `export 'types/sync.dart';` |
| `lib/framework/dive_computer_interface.dart` | Add `sync` / `syncProgress` / `diveStream`; `@Deprecated` on `download` / `connectBle` / `disconnectBle`. |
| `lib/framework/dive_computer_unsupported.dart` | No-op mirror of the new interface members (it only needs to compile). |
| `lib/framework/ble/ble_transport.dart` | `extends BridgedTransport`; keep only connect + characteristic resolution + the 4 subclass hooks. |
| `lib/framework/rfcomm/rfcomm_transport.dart` | `extends BridgedTransport`; keep only connect + channel plumbing + the 4 hooks. |
| `lib/framework/ble/ble_bridge_callbacks.dart` | `_write` posts `WriteReady(seq)` to `syncHostPort` after `queueOutbound`. |
| `lib/framework/dive_computer_ffi.dart` | `download()` → `sync()`; register `dc_device_set_events`; `progressCallback` / `deviceInfoCallback` slots; `stoppedAtKnownDive` flag; build + return `SyncResult`; drop `_divesCache` / `divesCallback`. |
| `lib/framework/dive_computer_isolate.dart` | `DiveComputer.sync()`, broadcast controllers, `_syncInFlight` guard, `_activeRun` / `_activeBridgedTransport`, port-listener branches, `DiveComputerMethod.sync`, deprecated shims. |
| `example/lib/main.dart`, `example/lib/ble_download_support.dart` | Migrate to `sync()` + `StreamBuilder<SyncProgress>` + `diveStream` subscription. |
| `test/framework/dive_computer_isolate_test.dart`, `test/framework/dive_computer_ffi_cap_test.dart`, `test/framework/dive_computer_interface_test.dart`, `test/framework/rfcomm/rfcomm_transport_test.dart`, `test/framework/ble/ble_transport_test.dart` | Update guards / retarget onto the base. |

**Deviation from spec:** the spec proposed moving the transport files into a new `lib/framework/transport/` directory. This plan leaves them in place (`lib/framework/ble/`, `lib/framework/rfcomm/`) and puts the base at `lib/framework/bridged_transport.dart`, to keep import churn to the two files plus their tests. The full directory move is deferred to SP4's cleanup pass.

---

### Task 1: `SyncRequest` / `SyncProgress` / `SyncResult` value types

**Files:**
- Create: `lib/types/sync.dart`
- Modify: `lib/dive_computer.dart`
- Test: `test/types/sync_test.dart`

**Interfaces:**
- Consumes: `Computer`, `ComputerTransport` from `lib/types/computer.dart`; `Dive` from `lib/types/dive.dart` (only referenced in doc comments here).
- Produces:
  - `class SyncRequest { final Computer computer; final ComputerTransport transport; final String? endpoint; final String? lastFingerprint; final Set<String>? knownFingerprints; SyncRequest({required this.computer, required this.transport, this.endpoint, this.lastFingerprint, this.knownFingerprints}); }`
  - `enum SyncPhase { connecting, reading, parsing, done }`
  - `class SyncProgress { final SyncPhase phase; final int current; final int maximum; final int divesParsed; const SyncProgress({required this.phase, required this.current, required this.maximum, required this.divesParsed}); double? get fraction; }`
  - `enum SyncStatus { completed, stoppedAtKnownDive, failed }`
  - `class SyncResult { final SyncStatus status; final int divesParsed; final int divesSkipped; final List<String> fingerprints; final Object? error; const SyncResult({required this.status, required this.divesParsed, required this.divesSkipped, required this.fingerprints, this.error}); }`

- [ ] **Step 1: Write the failing test**

```dart
// test/types/sync_test.dart
import 'package:dive_computer/types/computer.dart';
import 'package:dive_computer/types/sync.dart';
import 'package:test/test.dart';

void main() {
  final computer = Computer('Shearwater', 'Petrel',
      transports: [ComputerTransport.bluetooth]);

  test('SyncRequest keeps its fields', () {
    final r = SyncRequest(
      computer: computer,
      transport: ComputerTransport.bluetooth,
      endpoint: '00:11:22:33:44:55',
      lastFingerprint: 'ABCD',
      knownFingerprints: {'AA', 'BB'},
    );
    expect(r.computer, computer);
    expect(r.transport, ComputerTransport.bluetooth);
    expect(r.endpoint, '00:11:22:33:44:55');
    expect(r.lastFingerprint, 'ABCD');
    expect(r.knownFingerprints, {'AA', 'BB'});
  });

  test('SyncRequest optionals default to null', () {
    final r = SyncRequest(computer: computer, transport: ComputerTransport.ble);
    expect(r.endpoint, isNull);
    expect(r.lastFingerprint, isNull);
    expect(r.knownFingerprints, isNull);
  });

  group('SyncProgress.fraction', () {
    SyncProgress p(int c, int m) => SyncProgress(
        phase: SyncPhase.reading, current: c, maximum: m, divesParsed: 0);
    test('null when maximum is 0', () => expect(p(0, 0).fraction, isNull));
    test('ratio when maximum > 0', () => expect(p(1, 4).fraction, 0.25));
    test('does not throw when current exceeds maximum',
        () => expect(p(9, 4).fraction, closeTo(2.25, 1e-9)));
  });

  test('SyncResult carries status + counts + fingerprints', () {
    const res = SyncResult(
      status: SyncStatus.stoppedAtKnownDive,
      divesParsed: 3,
      divesSkipped: 2,
      fingerprints: ['C', 'B', 'A'],
    );
    expect(res.status, SyncStatus.stoppedAtKnownDive);
    expect(res.divesParsed, 3);
    expect(res.divesSkipped, 2);
    expect(res.fingerprints, ['C', 'B', 'A']);
    expect(res.error, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/types/sync_test.dart`
Expected: FAIL — `sync.dart` does not exist / URI doesn't resolve.

- [ ] **Step 3: Write the implementation**

```dart
// lib/types/sync.dart
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

/// The outcome of a [SyncRequest]. Dives themselves arrive only on
/// `DiveComputer.diveStream`; this carries counts and identifiers.
class SyncResult {
  const SyncResult({
    required this.status,
    required this.divesParsed,
    required this.divesSkipped,
    required this.fingerprints,
    this.error,
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

  /// Set only when [status] is [SyncStatus.failed].
  final Object? error;
}
```

Add to `lib/dive_computer.dart` after the other `types/` exports:

```dart
export 'types/sync.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/types/sync_test.dart`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/types/sync.dart lib/dive_computer.dart test/types/sync_test.dart
git commit -m "feat: SyncRequest/SyncProgress/SyncResult value types"
```

---

### Task 2: `ProgressCoalescer`

**Files:**
- Create: `lib/framework/sync/progress_coalescer.dart`
- Test: `test/framework/sync/progress_coalescer_test.dart`

**Interfaces:**
- Consumes: `SyncProgress`, `SyncPhase` from `lib/types/sync.dart`.
- Produces:
  - `class ProgressCoalescer { ProgressCoalescer(void Function(SyncProgress) emit, {Duration interval}); void submit(SyncProgress progress, {bool immediate = false}); void dispose(); }`
  - Contract: `submit` with `immediate: true` emits synchronously and cancels any pending timer. `submit` with `immediate: false` stores the value and (if no timer is armed) arms a `Timer(interval)` that emits the latest stored value on fire. Back-to-back non-immediate submits within one interval collapse to a single emission carrying the most recent value.

- [ ] **Step 1: Write the failing test**

```dart
// test/framework/sync/progress_coalescer_test.dart
import 'package:dive_computer/framework/sync/progress_coalescer.dart';
import 'package:dive_computer/types/sync.dart';
import 'package:flutter_test/flutter_test.dart';

SyncProgress _p(SyncPhase phase, int current) => SyncProgress(
    phase: phase, current: current, maximum: 100, divesParsed: current);

void main() {
  test('immediate submit emits synchronously', () {
    final seen = <SyncProgress>[];
    final c = ProgressCoalescer(seen.add,
        interval: const Duration(milliseconds: 100));
    c.submit(_p(SyncPhase.connecting, 0), immediate: true);
    expect(seen, hasLength(1));
    c.dispose();
  });

  test('rapid non-immediate submits collapse to one emission per interval', () {
    fakeAsync((async) {
      final seen = <SyncProgress>[];
      final c = ProgressCoalescer(seen.add,
          interval: const Duration(milliseconds: 100));
      for (var i = 1; i <= 50; i++) {
        c.submit(_p(SyncPhase.reading, i));
        async.elapse(const Duration(milliseconds: 1));
      }
      async.elapse(const Duration(milliseconds: 200));
      // ~50ms of submits at 100ms interval -> 1 timed flush; plus nothing
      // pending after. Allow a little slack for the boundary.
      expect(seen.length, lessThanOrEqualTo(2));
      expect(seen.last.current, 50, reason: 'latest value wins');
      c.dispose();
    });
  });

  test('phase change is emitted immediately even without the flag', () {
    fakeAsync((async) {
      final seen = <SyncProgress>[];
      final c = ProgressCoalescer(seen.add,
          interval: const Duration(milliseconds: 100));
      c.submit(_p(SyncPhase.reading, 1));
      async.elapse(const Duration(milliseconds: 10));
      c.submit(_p(SyncPhase.parsing, 2)); // different phase
      expect(seen.map((p) => p.phase), contains(SyncPhase.parsing));
      c.dispose();
    });
  });

  test('dispose cancels a pending flush', () {
    fakeAsync((async) {
      final seen = <SyncProgress>[];
      final c = ProgressCoalescer(seen.add,
          interval: const Duration(milliseconds: 100));
      c.submit(_p(SyncPhase.reading, 1));
      c.dispose();
      async.elapse(const Duration(milliseconds: 500));
      expect(seen, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/sync/progress_coalescer_test.dart`
Expected: FAIL — `progress_coalescer.dart` does not exist.

- [ ] **Step 3: Write the implementation**

```dart
// lib/framework/sync/progress_coalescer.dart
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
    if (immediate || progress.phase != _lastEmittedPhase) {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/framework/sync/progress_coalescer_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/framework/sync/progress_coalescer.dart test/framework/sync/progress_coalescer_test.dart
git commit -m "feat: ProgressCoalescer — rate-limit SyncProgress emission"
```

---

### Task 3: `SyncRun` orchestrator

**Files:**
- Create: `lib/framework/sync/sync_run.dart`
- Test: `test/framework/sync/sync_run_test.dart`

**Interfaces:**
- Consumes: `SyncProgress`, `SyncPhase`, `SyncResult`, `SyncStatus` from `lib/types/sync.dart`; `Dive` from `lib/types/dive.dart`.
- Produces:
  - `class SyncRun { SyncRun({required void Function(SyncProgress progress, {required bool immediate}) onProgress, required void Function(Dive dive) onDive}); Future<SyncResult> get result; void handleProgress(int current, int maximum); void handleDive(Dive dive); void handleDeviceInfo(int model, int firmware, int serial); void handleResult(SyncResult result); void handleError(Object error); ({int model, int firmware, int serial})? get deviceInfo; }`
  - Contract:
    - construction → nothing emitted yet; `result` is an incomplete future.
    - `handleProgress` → `onProgress(SyncProgress(phase: reading, current, maximum, divesParsed: <running>), immediate: <phase changed>)`.
    - `handleDive` → `onDive(dive)`, increment `divesParsed`, then `onProgress(SyncProgress(phase: parsing, ...), immediate: <phase changed>)`.
    - `handleDeviceInfo` → stored on `deviceInfo`, nothing emitted.
    - `handleResult(r)` → `onProgress(SyncProgress(phase: done, ..., divesParsed), immediate: true)` then complete `result` with `r`.
    - `handleError(e)` → complete `result` with `SyncResult(status: failed, error: e, divesParsed: <running>, divesSkipped: 0, fingerprints: const [])`. No progress emitted. Second call is a no-op (future already complete).
    - `handleResult` after `handleError` (or vice versa) is a no-op.

- [ ] **Step 1: Write the failing test**

```dart
// test/framework/sync/sync_run_test.dart
import 'package:dive_computer/framework/sync/sync_run.dart';
import 'package:dive_computer/types/dive.dart';
import 'package:dive_computer/types/sync.dart';
import 'package:flutter_test/flutter_test.dart';

class _Rec {
  final progress = <SyncProgress>[];
  final dives = <Dive>[];
  late final SyncRun run = SyncRun(
    onProgress: (p, {required immediate}) => progress.add(p),
    onDive: dives.add,
  );
}

Dive _dive(String hash) => Dive(hash);

void main() {
  test('progress events carry the running dive count and reading phase', () {
    final r = _Rec();
    r.run.handleProgress(10, 100);
    expect(r.progress.single.phase, SyncPhase.reading);
    expect(r.progress.single.current, 10);
    expect(r.progress.single.maximum, 100);
    expect(r.progress.single.divesParsed, 0);
  });

  test('each dive is forwarded, counted, and followed by a parsing progress', () {
    final r = _Rec();
    r.run.handleDive(_dive('A'));
    r.run.handleDive(_dive('B'));
    expect(r.dives.map((d) => d.hash), ['A', 'B']);
    expect(r.progress.last.phase, SyncPhase.parsing);
    expect(r.progress.last.divesParsed, 2);
  });

  test('handleResult emits a terminal done progress then completes', () async {
    final r = _Rec();
    r.run.handleDive(_dive('A'));
    const result = SyncResult(
      status: SyncStatus.completed,
      divesParsed: 1,
      divesSkipped: 0,
      fingerprints: ['A'],
    );
    r.run.handleResult(result);
    expect(r.progress.last.phase, SyncPhase.done);
    expect(await r.run.result, same(result));
  });

  test('handleError completes with a failed result and emits no progress', () async {
    final r = _Rec();
    r.run.handleProgress(5, 50);
    r.progress.clear();
    final err = StateError('boom');
    r.run.handleError(err);
    expect(r.progress, isEmpty);
    final res = await r.run.result;
    expect(res.status, SyncStatus.failed);
    expect(res.error, same(err));
  });

  test('a second terminal call is a no-op', () async {
    final r = _Rec();
    r.run.handleError(StateError('first'));
    r.run.handleResult(const SyncResult(
        status: SyncStatus.completed,
        divesParsed: 0,
        divesSkipped: 0,
        fingerprints: []));
    final res = await r.run.result;
    expect(res.status, SyncStatus.failed);
  });

  test('deviceInfo is stored, not emitted', () {
    final r = _Rec();
    r.run.handleDeviceInfo(3, 47, 12345);
    expect(r.progress, isEmpty);
    expect(r.run.deviceInfo, (model: 3, firmware: 47, serial: 12345));
  });
}
```

> If `Dive`'s constructor needs more than a hash, check `lib/types/dive.dart` and adjust `_dive` — it takes `Dive(this.hash, {...optional named...})`, so `Dive('A')` compiles.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/sync/sync_run_test.dart`
Expected: FAIL — `sync_run.dart` does not exist.

- [ ] **Step 3: Write the implementation**

```dart
// lib/framework/sync/sync_run.dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/framework/sync/sync_run_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/framework/sync/sync_run.dart test/framework/sync/sync_run_test.dart
git commit -m "feat: SyncRun — per-run sync orchestration (pure)"
```

---

### Task 4: `BridgedTransport` base + fake-subclass tests

**Files:**
- Create: `lib/framework/bridged_transport.dart`
- Create: `test/framework/bridged_transport_test.dart`

**Interfaces:**
- Consumes: `BleBridge`, ring-buffer constants from `lib/framework/ble/ble_bridge_state.dart`; `dc_status_t` from `lib/framework/dive_computer_ffi_bindings_generated.dart`.
- Produces:
  - `abstract class BridgedTransport { void attachBridge(BleBridge bridge); Future<void> serviceMailbox(); void handleDisconnect(); Future<void> teardown(); bool get hasBridge; }`
  - Abstract members a subclass must implement: `Future<void> writeToDevice(Uint8List bytes); Stream<Uint8List> get inboundBytes; Future<void> closeDevice(); bool get isDeviceConnected;`
  - Contract:
    - `attachBridge` subscribes `inboundBytes` → `bridge.pushInbound` (logs `severe` on ring-buffer overflow; reads the `_bridge` **field** inside the listener, not the captured arg), and arms `Timer.periodic(Duration(milliseconds: 250), (_) => serviceMailbox())` as a **safety net only**.
    - `serviceMailbox()` — if `_writeInFlight` return; if no bridge / not connected return; if `bridge.isClosed` → `teardown()` and return; read `seq = bridge.pendingWriteSeq`; if `seq == _lastServicedWriteSeq` return; set `_lastServicedWriteSeq = seq`, `_writeInFlight = true`; `await writeToDevice(bridge.pendingOutbound)`; `bridge.ackOutbound(seq, DC_STATUS_SUCCESS)` (or `DC_STATUS_IO` on throw); `_writeInFlight = false` in `finally`.
    - `handleDisconnect()` → `bridge?.markClosed()` then `teardown()`.
    - `teardown()` → cancel timer, cancel inbound subscription, `await closeDevice()` guarded, null `_bridge` **last**.

- [ ] **Step 1: Write the failing test**

```dart
// test/framework/bridged_transport_test.dart
import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:dive_computer/framework/bridged_transport.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/dive_computer_ffi_bindings_generated.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTransport extends BridgedTransport {
  final _inbound = StreamController<Uint8List>();
  final writes = <List<int>>[];
  int writeCalls = 0;
  Completer<void>? gate; // when set, writeToDevice awaits it
  bool connected = true;
  int closeCalls = 0;

  void emitInbound(List<int> b) => _inbound.add(Uint8List.fromList(b));

  @override
  Stream<Uint8List> get inboundBytes => _inbound.stream;
  @override
  bool get isDeviceConnected => connected;
  @override
  Future<void> writeToDevice(Uint8List bytes) async {
    writeCalls++;
    if (gate != null) await gate!.future;
    writes.add(bytes.toList());
  }
  @override
  Future<void> closeDevice() async {
    closeCalls++;
    connected = false;
  }
}

int _queue(BleBridge bridge, List<int> bytes) {
  final p = calloc<ffi.Uint8>(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    p[i] = bytes[i];
  }
  final seq = bridge.queueOutbound(p, bytes.length);
  calloc.free(p);
  return seq;
}

void main() {
  test('serviceMailbox writes the mailbox and acks the captured seq', () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(() => t.teardown());
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);

    final seq = _queue(bridge, [1, 2, 3]);
    await t.serviceMailbox();

    expect(t.writes, [[1, 2, 3]]);
    expect(bridge.waitForWriteAck(seq, 0), isTrue);
  });

  test('a retry that bumps writeSeq mid-write does not double-write', () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(() => t.teardown());
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);

    t.gate = Completer<void>();
    _queue(bridge, [1]);
    final first = t.serviceMailbox();       // enters writeToDevice, awaits gate
    _queue(bridge, [2]);                      // bump writeSeq mid-flight
    await t.serviceMailbox();                 // must early-return on _writeInFlight
    expect(t.writeCalls, 1);
    t.gate!.complete();
    await first;
  });

  test('the 250ms safety-net timer services a write on its own', () {
    fakeAsync((async) {
      final t = _FakeTransport();
      final bridge = BleBridge.allocate();
      t.attachBridge(bridge);
      _queue(bridge, [7, 7]);
      async.elapse(const Duration(milliseconds: 300));
      expect(t.writes, [[7, 7]]);
      t.teardown();
      bridge.dispose();
    });
  });

  test('inbound bytes land in the ring buffer', () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(() => t.teardown());
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);

    t.emitInbound([9, 8, 7]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final dest = calloc<ffi.Uint8>(8);
    expect(bridge.popInbound(dest, 8), 3);
    calloc.free(dest);
  });

  test('an inbound event after teardown is a no-op (field read, not capture)',
      () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    t.attachBridge(bridge);
    await t.teardown();
    // must not throw even though the bridge is about to be freed
    t.emitInbound([1]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    bridge.dispose();
  });

  test('bridge.isClosed makes serviceMailbox tear the transport down', () async {
    final t = _FakeTransport();
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    t.attachBridge(bridge);
    bridge.markClosed();
    await t.serviceMailbox();
    expect(t.closeCalls, 1);
    expect(t.hasBridge, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/bridged_transport_test.dart`
Expected: FAIL — `bridged_transport.dart` does not exist.

- [ ] **Step 3: Write the implementation**

```dart
// lib/framework/bridged_transport.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'ble/ble_bridge_state.dart';
import 'dive_computer_ffi_bindings_generated.dart';

/// Shared machinery for a main-isolate transport driving a [BleBridge] on
/// behalf of libdivecomputer on the background isolate. `BleTransport` and
/// `RfcommTransport` differ only in how they open a connection and move
/// bytes; everything about servicing the bridge — the inbound pump, the
/// outbound mailbox, teardown ordering, the dangling-bridge guards — lives
/// here.
///
/// Outbound writes are normally triggered by a `WriteReady` port message
/// from the background isolate's `write` callback (see
/// `framework/sync/write_signal.dart`); [_safetyNet] is a slow fallback
/// for a lost message, not the primary path.
abstract class BridgedTransport {
  final Logger _log = Logger(_loggerName);
  static const _loggerName = 'BridgedTransport';

  BleBridge? _bridge;
  StreamSubscription<Uint8List>? _inboundSub;
  Timer? _safetyNet;
  int _lastServicedWriteSeq = 0;
  bool _writeInFlight = false;

  bool get hasBridge => _bridge != null;

  // --- subclass responsibilities -------------------------------------

  /// Perform the real device write (GATT write / socket write).
  Future<void> writeToDevice(Uint8List bytes);

  /// Inbound bytes from the device (GATT notifications / socket reads).
  Stream<Uint8List> get inboundBytes;

  /// Close the underlying connection. Called once during [teardown];
  /// must not throw (guard internally or expect the base to swallow it).
  Future<void> closeDevice();

  bool get isDeviceConnected;

  // --- base machinery ----------------------------------------------------

  void attachBridge(BleBridge bridge) {
    if (!isDeviceConnected) {
      throw StateError('attachBridge() called before a connection was open');
    }
    _bridge = bridge;
    _lastServicedWriteSeq = 0;
    _inboundSub = inboundBytes.listen(
      (bytes) {
        // Read the FIELD, not the captured param: teardown() nulls _bridge
        // and cancels this sub unawaited, so a queued notification can still
        // arrive after the bridge's native memory is freed.
        final b = _bridge;
        if (b == null || b.isClosed) return;
        final written = b.pushInbound(bytes);
        if (written < bytes.length) {
          _log.severe('Inbound ring buffer overflow: dropped '
              '${bytes.length - written} of ${bytes.length} bytes');
        }
      },
      onDone: handleDisconnect,
      onError: (Object e, StackTrace st) {
        _log.warning('Inbound stream error', e, st);
        handleDisconnect();
      },
    );
    _safetyNet = Timer.periodic(
        const Duration(milliseconds: 250), (_) => serviceMailbox());
  }

  /// Drain the outbound mailbox if it has a new payload. Invoked by a
  /// `WriteReady` message (fast path) and by [_safetyNet] (fallback).
  Future<void> serviceMailbox() async {
    if (_writeInFlight) return;
    final bridge = _bridge;
    if (bridge == null || !isDeviceConnected) return;
    if (bridge.isClosed) {
      await teardown();
      return;
    }
    final seq = bridge.pendingWriteSeq;
    if (seq == _lastServicedWriteSeq) return;
    _lastServicedWriteSeq = seq;
    _writeInFlight = true;
    try {
      await writeToDevice(bridge.pendingOutbound);
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_SUCCESS);
    } catch (e, st) {
      _log.severe('Mailbox write failed', e, st);
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_IO);
    } finally {
      _writeInFlight = false;
    }
  }

  void handleDisconnect() {
    _bridge?.markClosed();
    // teardown is async; callers of handleDisconnect don't await it.
    unawaited(teardown());
  }

  Future<void> teardown() async {
    _safetyNet?.cancel();
    _safetyNet = null;
    await _inboundSub?.cancel();
    _inboundSub = null;
    try {
      if (isDeviceConnected) await closeDevice();
    } catch (_) {
      // best-effort; the bridge is already marked closed
    }
    _bridge = null;
  }
}
```

> `Logger(_loggerName)` reuses the name `'BridgedTransport'` for both subclasses; the `enableDebugLogging()` wiring in Task 9 forwards it.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/framework/bridged_transport_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/framework/bridged_transport.dart test/framework/bridged_transport_test.dart
git commit -m "feat: BridgedTransport base — shared bridge-servicing, 250ms safety net"
```

---

### Task 5: `RfcommTransport extends BridgedTransport`

**Files:**
- Modify: `lib/framework/rfcomm/rfcomm_transport.dart`
- Modify: `test/framework/rfcomm/rfcomm_transport_test.dart`

**Interfaces:**
- Consumes: `BridgedTransport` (Task 4); existing `RfcommChannel`.
- Produces: `class RfcommTransport extends BridgedTransport { RfcommTransport(RfcommChannel channel); Future<void> connect(String address); bool get isConnected; }` — same public surface as today minus the now-inherited `attachBridge` / `disconnect`. `disconnect()` stays as a public alias that calls `teardown()` (callers in `dive_computer_isolate.dart` use it).

- [ ] **Step 1: Update the test (still a behavioural test, retargeted)**

Replace the body of `test/framework/rfcomm/rfcomm_transport_test.dart` with:

```dart
import 'dart:typed_data';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_channel.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'dart:ffi' as ffi;

void main() {
  test('inbound socket bytes land in the bridge ring buffer', () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(() => t.disconnect());
    addTearDown(bridge.dispose);

    await t.connect('00:13:43:0A:A0:6F');
    t.attachBridge(bridge);

    ch.emitInbound(Uint8List.fromList([1, 2, 3, 4]));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final dest = calloc<ffi.Uint8>(16);
    final n = bridge.popInbound(dest, 16);
    expect(n, 4);
    expect([for (var i = 0; i < 4; i++) dest[i]], [1, 2, 3, 4]);
    calloc.free(dest);
  });

  test('outbound mailbox is drained to channel.write and acked (safety net)',
      () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(() => t.disconnect());
    addTearDown(bridge.dispose);
    await t.connect('x');
    t.attachBridge(bridge);

    final data = calloc<ffi.Uint8>(3);
    data[0] = 10;
    data[1] = 20;
    data[2] = 30;
    final seq = bridge.queueOutbound(data, 3);
    calloc.free(data);

    // No WriteReady message in this unit test — rely on the 250ms safety net.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(ch.writes, [
      [10, 20, 30]
    ]);
    expect(bridge.waitForWriteAck(seq, 0), isTrue);
  });

  test('a socket disconnect marks the bridge closed', () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    await t.connect('x');
    t.attachBridge(bridge);

    ch.emitDisconnect();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(bridge.isClosed, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/rfcomm/rfcomm_transport_test.dart`
Expected: FAIL — the second test times out at 20 ms style waits / `attachBridge` still runs the old 4 ms timer OR compile error once you start editing. (If it still passes because the old code is intact, that's fine — proceed; the retarget is verified in Step 4.)

- [ ] **Step 3: Rewrite `rfcomm_transport.dart`**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../bridged_transport.dart';
import 'rfcomm_channel.dart';

final _log = Logger('RfcommTransport');

/// Main-isolate driver for a Bluetooth-Classic RFCOMM connection. RFCOMM is
/// a plain byte stream, so beyond opening the socket this only wires the
/// four [BridgedTransport] hooks.
class RfcommTransport extends BridgedTransport {
  RfcommTransport(this._channel);

  final RfcommChannel _channel;
  bool _connected = false;

  bool get isConnected => _connected;

  Future<void> connect(String address) async {
    await _channel.connect(address);
    _connected = true;
    _log.fine('RFCOMM connected to $address');
  }

  /// Public alias kept for `dive_computer_isolate.dart`, which calls
  /// `disconnect()` in its teardown paths.
  Future<void> disconnect() => teardown();

  // --- BridgedTransport hooks ---

  @override
  bool get isDeviceConnected => _connected;

  @override
  Future<void> writeToDevice(Uint8List bytes) => _channel.write(bytes);

  @override
  Stream<Uint8List> get inboundBytes => _channel.inbound;

  @override
  Future<void> closeDevice() async {
    _connected = false;
    await _channel.disconnect().catchError((_) {});
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/framework/rfcomm/rfcomm_transport_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full suite for regressions**

Run: `flutter test`
Expected: PASS except the pre-existing `ble_transport_test.dart` failures introduced only if you edited shared code — you haven't yet. `ble_transport.dart` still compiles (unchanged). Green (minus the known `ble_bridge_state_test.dart` flake if it flakes).

- [ ] **Step 6: Commit**

```bash
git add lib/framework/rfcomm/rfcomm_transport.dart test/framework/rfcomm/rfcomm_transport_test.dart
git commit -m "refactor: RfcommTransport extends BridgedTransport"
```

---

### Task 6: `BleTransport extends BridgedTransport`

**Files:**
- Modify: `lib/framework/ble/ble_transport.dart`
- Modify: `test/framework/ble/ble_transport_test.dart` (only if it references the removed `_mailboxTimer` internals or the 4 ms timing; the public flow is unchanged)

**Interfaces:**
- Consumes: `BridgedTransport` (Task 4); existing `BleCentral`, `BleProfile`, `BleScanResult`, GATT types.
- Produces: `class BleTransport extends BridgedTransport { BleTransport(BleCentral central); Stream<BleScanResult> scanForDevices(); Future<void> connect(BleScanResult device, {int maxAttempts = 3}); Future<void> disconnect(); bool get isConnected; }` — public surface unchanged; `attachBridge` now inherited.

- [ ] **Step 1: Read the current file and the test**

Run: (no command) — open `lib/framework/ble/ble_transport.dart` and `test/framework/ble/ble_transport_test.dart`. Note that `connect()` (retry loop, `_firstServiceMatching`, `_resolveCharacteristics`, `_connStateSub` disconnect watch) stays; only the bridge-servicing half moves to the base.

- [ ] **Step 2: Rewrite `ble_transport.dart`**

Keep everything from `connect()` down through `_resolveCharacteristics` **as-is**, and replace the bridge-servicing members. The class header becomes `class BleTransport extends BridgedTransport`. Remove: `_bridge`, `_mailboxTimer`, `_notifySub`, `_lastServicedWriteSeq`, `_writeInFlight`, `attachBridge`, `_serviceMailbox`, `_teardown` (the base owns these). Keep `_connection`, `_serviceUuid`, `_writeCharUuid`, `_notifyCharUuid`, `_writeWithResponse`, `_connStateSub`.

Add the hooks:

```dart
  @override
  bool get isDeviceConnected => _connection != null && _serviceUuid != null;

  @override
  Future<void> writeToDevice(Uint8List bytes) => _connection!.write(
        _serviceUuid!,
        _writeCharUuid!,
        bytes,
        withResponse: _writeWithResponse,
      );

  @override
  Stream<Uint8List> get inboundBytes =>
      _connection!.subscribeNotifications(_serviceUuid!, _notifyCharUuid!);

  @override
  Future<void> closeDevice() async {
    await _connStateSub?.cancel();
    _connStateSub = null;
    final c = _connection;
    _connection = null;
    _serviceUuid = null;
    _writeCharUuid = null;
    _notifyCharUuid = null;
    _writeWithResponse = false;
    await c?.disconnect().catchError((_) {});
  }
```

`disconnect()` (public) becomes:

```dart
  Future<void> disconnect() async {
    // markClosed happens in the base's teardown via handleDisconnect;
    // call teardown directly for an explicit disconnect.
    await teardown();
  }
```

`_handleDisconnect()` (the `_connStateSub` callback for an unexpected drop) → `handleDisconnect()` (inherited).

> **Watch:** `inboundBytes` is a getter returning a fresh `subscribeNotifications(...)` stream each call. The base calls it exactly once in `attachBridge`. Confirm `subscribeNotifications` can be called once per connection (it can — unchanged from today).

- [ ] **Step 3: Run the BLE transport test**

Run: `flutter test test/framework/ble/ble_transport_test.dart`
Expected: PASS. If a test explicitly waited `Duration(milliseconds: 20)` for a mailbox write, bump it to `Duration(milliseconds: 300)` (safety-net cadence) — the unit test has no `WriteReady` message. Do not change what it asserts.

- [ ] **Step 4: Full suite**

Run: `flutter test`
Expected: green (minus the known flake).

- [ ] **Step 5: Commit**

```bash
git add lib/framework/ble/ble_transport.dart test/framework/ble/ble_transport_test.dart
git commit -m "refactor: BleTransport extends BridgedTransport"
```

---

### Task 7: `WriteReady` signal — `write_signal.dart` + bridge callback + FFI host port

**Files:**
- Create: `lib/framework/sync/write_signal.dart`
- Modify: `lib/framework/ble/ble_bridge_callbacks.dart`
- Modify: `lib/framework/dive_computer_ffi.dart` (host-port static + set/clear around the transfer)
- Create: `test/framework/sync/write_signal_test.dart` (source guards + the plain data class)

**Interfaces:**
- Produces:
  - `class WriteReady { const WriteReady(this.seq); final int seq; }`
  - `SendPort? syncHostPort;` (library-level, mutable) — set on the **background isolate** for the duration of a transfer; read by `_write`.
- Consumes: `SendPort` from `dart:isolate`.

- [ ] **Step 1: Write the failing test**

```dart
// test/framework/sync/write_signal_test.dart
import 'dart:io';

import 'package:dive_computer/framework/sync/write_signal.dart';
import 'package:test/test.dart';

void main() {
  test('WriteReady is a plain data class', () {
    const w = WriteReady(7);
    expect(w.seq, 7);
  });

  test('syncHostPort defaults to null', () {
    expect(syncHostPort, isNull);
  });

  test('_write posts WriteReady to syncHostPort after queueOutbound', () {
    final src = File('lib/framework/ble/ble_bridge_callbacks.dart')
        .readAsStringSync();
    final write = RegExp(r'int _write\([^)]*\)[^{]*\{.*?\n\}', dotAll: true)
        .firstMatch(src)
        ?.group(0);
    expect(write, isNotNull);
    expect(write, contains('queueOutbound'));
    expect(write, contains('syncHostPort?.send(WriteReady(seq))'));
    // the signal must be posted before the blocking ack wait
    expect(
      write!.indexOf('syncHostPort?.send(WriteReady(seq))') <
          write.indexOf('waitForWriteAck'),
      isTrue,
      reason: 'signal the main isolate, THEN block on the ack',
    );
  });

  test('the FFI layer sets and clears syncHostPort around the transfer', () {
    final src =
        File('lib/framework/dive_computer_ffi.dart').readAsStringSync();
    expect(src, contains('syncHostPort ='));
    expect(src, contains('syncHostPort = null'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/sync/write_signal_test.dart`
Expected: FAIL — `write_signal.dart` does not exist.

- [ ] **Step 3: Create `write_signal.dart`**

```dart
// lib/framework/sync/write_signal.dart
import 'dart:isolate';

/// Posted by the bridge `write` callback (background isolate) to tell the
/// main isolate a payload is waiting in the outbound mailbox — replacing
/// the old `Timer.periodic(4ms)` poll. [seq] is the mailbox sequence the
/// callback is now blocked waiting an ack for.
class WriteReady {
  const WriteReady(this.seq);
  final int seq;
}

/// The main isolate's `SendPort`, stashed here by `_spawnIsolate` for the
/// duration of one transfer (see `dive_computer_ffi.dart`). Null outside a
/// transfer. Lives on the background isolate only — isolates don't share
/// globals, so this is not cross-isolate state.
SendPort? syncHostPort;
```

- [ ] **Step 4: Edit `_write` in `ble_bridge_callbacks.dart`**

Add the import:

```dart
import '../sync/write_signal.dart';
```

In `_write`, immediately after `final seq = bridge.queueOutbound(data.cast<ffi.Uint8>(), size);` and **before** `final acked = bridge.waitForWriteAck(seq, bridge.timeoutMs);`:

```dart
    // Wake the main isolate now instead of waiting for its 250ms safety net.
    syncHostPort?.send(WriteReady(seq));
```

- [ ] **Step 5: Set/clear `syncHostPort` in `dive_computer_ffi.dart`**

Add the import `import 'sync/write_signal.dart';`. In `DiveComputerFfi.sync()` (renamed in Task 8 — for now the method is still `download()`; do this edit in Task 8 instead if ordering bites). Simplest: set it in `_spawnIsolate`'s `sync`/`download` handler in `dive_computer_isolate.dart` where `sendPort` is in scope:

```dart
        case DiveComputerMethod.download: // becomes .sync in Task 9
          ...
          syncHostPort = sendPort;
          try {
            DiveComputerFfi.download(...);
          } finally {
            syncHostPort = null;
            ...
          }
```

Because the test in Step 1 greps `dive_computer_ffi.dart`, instead put a thin pass-through there: add to `DiveComputerFfi` a `static set hostPort(SendPort? p) => syncHostPort = p;` and call `DiveComputerFfi.hostPort = sendPort` / `= null` from `_spawnIsolate`. Add `import 'sync/write_signal.dart';` to `dive_computer_ffi.dart` and the setter. Adjust the Step-1 grep if you choose a different spelling — keep `syncHostPort =` and `syncHostPort = null` reachable in that file via the setter body.

- [ ] **Step 6: Run tests**

Run: `flutter test test/framework/sync/write_signal_test.dart`
Expected: PASS (4 tests).

Run: `flutter test`
Expected: green (minus the known flake). `ble_bridge_callbacks_test.dart` still passes — `syncHostPort` is null in that test so `?.send` is a no-op.

- [ ] **Step 7: Commit**

```bash
git add lib/framework/sync/write_signal.dart lib/framework/ble/ble_bridge_callbacks.dart lib/framework/dive_computer_ffi.dart test/framework/sync/write_signal_test.dart
git commit -m "feat: WriteReady port signal replaces the 4ms mailbox poll"
```

---

### Task 8: FFI `sync()` + `dc_device_set_events` progress plumbing

**Files:**
- Modify: `lib/framework/dive_computer_ffi.dart`
- Modify: `test/framework/dive_computer_ffi_cap_test.dart`

**Interfaces:**
- Consumes: `dc_device_set_events`, `dc_event_type_t.DC_EVENT_PROGRESS`, `dc_event_type_t.DC_EVENT_DEVINFO`, `dc_event_progress_t`, `dc_event_devinfo_t`, `dc_event_callback_t` (all already generated); `SyncRequest`/`SyncResult`/`SyncStatus` from `lib/types/sync.dart`.
- Produces (background-isolate FFI surface consumed by `_spawnIsolate` in Task 9):
  - `static Function(Dive)? diveCallback;` (unchanged)
  - `static Function(int current, int maximum)? progressCallback;`
  - `static Function(int model, int firmware, int serial)? deviceInfoCallback;`
  - `static Set<String> skipFingerprints;` (unchanged)
  - `static SyncResult sync(Computer computer, ComputerTransport transport, {String? lastFingerprint, int? bridgeAddress, String? address})` — replaces `download(...)`. Returns the built `SyncResult`.
  - `static set hostPort(SendPort? p)` (from Task 7)
- Removed: `divesCallback`, `_divesCache`.

- [ ] **Step 1: Update the source-guard test**

Add to `test/framework/dive_computer_ffi_cap_test.dart`:

```dart
  test('sync() registers a progress + devinfo event handler before foreach', () {
    expect(source, contains('dc_device_set_events('));
    expect(source, contains('dc_event_type_t.DC_EVENT_PROGRESS'));
    expect(source, contains('dc_event_type_t.DC_EVENT_DEVINFO'));
    final syncBody = RegExp(r'static SyncResult sync\(.*?\n  \}', dotAll: true)
        .firstMatch(source)
        ?.group(0);
    expect(syncBody, isNotNull);
    expect(
      syncBody!.indexOf('dc_device_set_events') <
          syncBody.indexOf('dc_device_foreach'),
      isTrue,
      reason: 'events must be registered before the transfer starts',
    );
  });

  test('the event handler does no work beyond forwarding to a callback slot',
      () {
    final handler = RegExp(
            r'void _event_callback\([^)]*\)\s*\{.*?\n\}', dotAll: true)
        .firstMatch(source)
        ?.group(0);
    expect(handler, isNotNull);
    expect(handler, contains('DC_EVENT_PROGRESS'));
    expect(handler, contains('progressCallback'));
    expect(handler, contains('deviceInfoCallback'));
    expect(handler, isNot(contains('_parseDive')));
    expect(handler, isNot(contains('.toDartString()')));
  });

  test('_divesCache and divesCallback are gone (stream-only result)', () {
    expect(source, isNot(contains('_divesCache')));
    expect(source, isNot(contains('divesCallback')));
  });

  test('sync() distinguishes stoppedAtKnownDive from completed', () {
    expect(source, contains('SyncStatus.stoppedAtKnownDive'));
    expect(source, contains('SyncStatus.completed'));
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/framework/dive_computer_ffi_cap_test.dart`
Expected: FAIL on the new tests.

- [ ] **Step 3: Edit `dive_computer_ffi.dart`**

3a. Add imports:

```dart
import 'dart:isolate' show SendPort;
import 'sync/write_signal.dart';
import '../types/sync.dart';
```

3b. Replace the callback statics:

```dart
  /// Called once per dive as it is parsed. Set by the background isolate to
  /// stream dives across to the main isolate.
  static Function(Dive)? diveCallback;

  /// Called on each libdivecomputer PROGRESS event with raw byte counts.
  static Function(int current, int maximum)? progressCallback;

  /// Called once on the DEVINFO event.
  static Function(int model, int firmware, int serial)? deviceInfoCallback;

  /// Fingerprints (dive hashes) the caller already has — [_dive_callback]
  /// skips parsing/emitting these. Set per [sync] call, cleared after.
  static Set<String> skipFingerprints = {};

  static set hostPort(SendPort? p) => syncHostPort = p;

  // run-scoped counters, reset at the top of sync()
  static int _divesParsedThisRun = 0;
  static int _divesSkippedThisRun = 0;
  static final _fingerprintsThisRun = <String>[];
  static bool _stoppedAtKnownDive = false;
```

3c. The event handler — a top-level function (like `_dive_callback`):

```dart
  // ignore: non_constant_identifier_names
  static void _event_callback(
    ffi.Pointer<dc_device_t> device,
    int event,
    ffi.Pointer<ffi.Void> data,
    ffi.Pointer<ffi.Void> userdata,
  ) {
    // Runs synchronously inside dc_device_foreach on the background isolate.
    // Do nothing but read the struct and forward — no allocation, no parse.
    switch (event) {
      case dc_event_type_t.DC_EVENT_PROGRESS:
        final p = data.cast<dc_event_progress_t>().ref;
        progressCallback?.call(p.current, p.maximum);
        break;
      case dc_event_type_t.DC_EVENT_DEVINFO:
        final d = data.cast<dc_event_devinfo_t>().ref;
        deviceInfoCallback?.call(d.model, d.firmware, d.serial);
        break;
    }
  }
```

3d. Rename `download(...)` → `sync(...)` returning `SyncResult`. The body keeps the iostream switch and `dc_device_open` exactly as-is. Changes:

- At the top: reset the run-scoped counters and `_stoppedAtKnownDive`.
- After `dc_device_open` succeeds and before `dc_device_foreach`:

```dart
      _handleResult(
        _bindings.dc_device_set_events(
          device.value,
          dc_event_type_t.DC_EVENT_PROGRESS | dc_event_type_t.DC_EVENT_DEVINFO,
          ffi.Pointer.fromFunction<dc_event_callback_tFunction>(_event_callback),
          ffi.nullptr,
        ),
        'device set events',
      );
```

- Remove `_divesCache.clear();`, the post-foreach `_divesCache.removeWhere(...)`, and `divesCallback?.call(_divesCache);`.
- After `dc_device_foreach` returns `DC_STATUS_SUCCESS`, build the result:

```dart
      final status = _stoppedAtKnownDive
          ? SyncStatus.stoppedAtKnownDive
          : SyncStatus.completed;
      final result = SyncResult(
        status: status,
        divesParsed: _divesParsedThisRun,
        divesSkipped: _divesSkippedThisRun,
        // dc_device_foreach walks the log NEWEST-FIRST (that is what makes
        // lastFingerprint an early stop), so _fingerprintsThisRun is already
        // newest-first — do NOT reverse it.
        fingerprints: List.of(_fingerprintsThisRun), // newest first
      );
```

- `dc_device_close` + `dc_iostream_close` in the `finally` unchanged.
- Return `result`.

3e. In `_dive_callback`:
- when `currentFingerprint == lastFingerprint` → `_stoppedAtKnownDive = true; return 0;`
- always `_fingerprintsThisRun.add(currentFingerprint);` (both skipped and parsed).
- when `skipFingerprints.contains(currentFingerprint)` → `_divesSkippedThisRun++;` and don't parse.
- else → `_parseDive(...)`.

3f. In `_parseDive`, after `diveCallback?.call(dive);` add `_divesParsedThisRun++;` (or increment in `_dive_callback` right after a successful non-skipped parse — pick the spot where a parse throw won't inflate the count; incrementing in `_dive_callback` after `_parseDive` returns is cleaner).

3g. Remove the now-unused `_divesCache` field and `divesCallback` static entirely.

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/dive_computer_ffi_cap_test.dart`
Expected: PASS.

Run: `flutter test`
Expected: green except `dive_computer_isolate_test.dart` (it still greps `DiveComputerFfi.download(...)` and the old message shape) and possibly `dive_computer_ffi_bluetooth_test.dart` / `dive_computer_interface_test.dart` — those are fixed in Task 9/10. Note which fail; they must be exactly the expected set.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/dive_computer_ffi.dart test/framework/dive_computer_ffi_cap_test.dart
git commit -m "feat: FFI sync() returns SyncResult, registers dc_device_set_events"
```

---

### Task 9: Isolate — `DiveComputer.sync()`, streams, guard, port listener

**Files:**
- Modify: `lib/framework/dive_computer_isolate.dart`
- Modify: `lib/framework/dive_computer_interface.dart`
- Modify: `lib/framework/dive_computer_unsupported.dart`
- Modify: `test/framework/dive_computer_isolate_test.dart`
- Modify: `test/framework/dive_computer_ffi_bluetooth_test.dart` (if it greps the download message shape — check and update)

**Interfaces:**
- Consumes: `SyncRun` (Task 3), `ProgressCoalescer` (Task 2), `WriteReady` (Task 7), `BridgedTransport` (Task 4), `DiveComputerFfi.sync` + callback slots (Task 8), `SyncRequest`/`SyncResult`/`SyncProgress` (Task 1).
- Produces (public API consumed by Task 10's shims + the example):
  - `Future<SyncResult> sync(SyncRequest request)`
  - `Stream<SyncProgress> get syncProgress`
  - `Stream<Dive> get diveStream`
  - `enum DiveComputerMethod { ..., sync }` (rename `download` → `sync`)
  - private: `_ProgressMsg(int current, int maximum)`, `_DeviceInfoMsg(int model, int firmware, int serial)` cross-isolate message classes; `SyncRun? _activeRun`; `BridgedTransport? _activeBridgedTransport`; `bool _syncInFlight`.

- [ ] **Step 1: Update the source-guard test**

Rewrite `test/framework/dive_computer_isolate_test.dart` — keep the memoization + guarded-completer tests for `supportedComputers` / `serialPorts` / `bluetoothDevices` (unchanged), and replace the `download`-specific ones:

```dart
  test('sync() guards against a concurrent run', () {
    expect(source, contains('_syncInFlight'));
    expect(
      RegExp(r'if \(_syncInFlight\)\s*\{?\s*throw StateError').hasMatch(source),
      isTrue,
      reason: 'a second sync() while one is running must throw',
    );
    expect("_syncInFlight = false".allMatches(source).length,
        greaterThanOrEqualTo(1));
  });

  test('sync() drives a SyncRun through a ProgressCoalescer', () {
    expect(source, contains('SyncRun('));
    expect(source, contains('ProgressCoalescer('));
    expect(source, contains('_progressController.add'));
    expect(source, contains('_diveController.add'));
  });

  test('syncProgress and diveStream are broadcast streams', () {
    expect(source, contains('StreamController<SyncProgress>.broadcast()'));
    expect(source, contains('StreamController<Dive>.broadcast()'));
    expect(source, contains('Stream<SyncProgress> get syncProgress'));
    expect(source, contains('Stream<Dive> get diveStream'));
  });

  test('port listener routes the new messages to the active run', () {
    expect(
      RegExp(r'is _ProgressMsg\)[^;]*_activeRun\?\.handleProgress')
          .hasMatch(source),
      isTrue,
    );
    expect(
      RegExp(r'is Dive\)[^;]*_activeRun\?\.handleDive').hasMatch(source),
      isTrue,
    );
    expect(
      RegExp(r'is SyncResult\)[^;]*_activeRun\?\.handleResult').hasMatch(source),
      isTrue,
    );
    expect(
      RegExp(r'is WriteReady\)[^;]*_activeBridgedTransport\?\.serviceMailbox')
          .hasMatch(source),
      isTrue,
    );
  });

  test('an isolate/transport error routes to handleError, not a stream error',
      () {
    expect(source, contains('_activeRun?.handleError'));
  });

  test('_spawnIsolate handles DiveComputerMethod.sync and wires the callbacks',
      () {
    expect(source, contains('DiveComputerMethod.sync'));
    expect(source, contains('DiveComputerFfi.progressCallback = '));
    expect(source, contains('DiveComputerFfi.deviceInfoCallback = '));
    expect(source, contains('DiveComputerFfi.diveCallback = '));
    expect(source, contains('DiveComputerFfi.hostPort = sendPort'));
    expect(source, contains('DiveComputerFfi.hostPort = null'));
    expect(source, contains('sendPort.send(result)'));
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/framework/dive_computer_isolate_test.dart`
Expected: FAIL on the new tests.

- [ ] **Step 3: Edit `dive_computer_interface.dart`**

```dart
  Future<SyncResult> sync(SyncRequest request) => throw UnimplementedError();

  Stream<SyncProgress> get syncProgress => throw UnimplementedError();

  Stream<Dive> get diveStream => throw UnimplementedError();
```

Add `@Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')` to `download`, `connectBle`, `disconnectBle`. Add the `sync.dart` import.

- [ ] **Step 4: Edit `dive_computer_isolate.dart`**

4a. Imports: `import '../types/sync.dart';`, `import 'sync/sync_run.dart';`, `import 'sync/progress_coalescer.dart';`, `import 'sync/write_signal.dart';`, `import 'bridged_transport.dart';`.

4b. `enum DiveComputerMethod` — rename `download` to `sync`.

4c. Cross-isolate message classes (near `_BleBridgeReleased`):

```dart
class _ProgressMsg {
  const _ProgressMsg(this.current, this.maximum);
  final int current, maximum;
}

class _DeviceInfoMsg {
  const _DeviceInfoMsg(this.model, this.firmware, this.serial);
  final int model, firmware, serial;
}
```

4d. Fields on `DiveComputer`:

```dart
  final _progressController = StreamController<SyncProgress>.broadcast();
  final _diveController = StreamController<Dive>.broadcast();

  Stream<SyncProgress> get syncProgress => _progressController.stream;
  Stream<Dive> get diveStream => _diveController.stream;

  bool _syncInFlight = false;
  SyncRun? _activeRun;
  ProgressCoalescer? _activeCoalescer;
  BridgedTransport? _activeBridgedTransport;
```

Delete `_downloadedDives` and `_onDive`.

4e. Port listener branches (replace the `is List<Dive>` / `is Dive` handling):

```dart
      } else if (message is _ProgressMsg) {
        _activeRun?.handleProgress(message.current, message.maximum);
      } else if (message is _DeviceInfoMsg) {
        _activeRun?.handleDeviceInfo(
            message.model, message.firmware, message.serial);
      } else if (message is Dive) {
        _activeRun?.handleDive(message);
      } else if (message is SyncResult) {
        _activeRun?.handleResult(message);
      } else if (message is WriteReady) {
        _activeBridgedTransport?.serviceMailbox();
      } else if (message is _BleBridgeReleased) {
        ...unchanged...
      } else if (message is Error || message is Exception) {
        _activeRun?.handleError(message);
        // keep the existing enumeration-completer error fan-out
        ...
      }
```

In `_errorPort.listen`, add `_activeRun?.handleError(error);` alongside the existing completer fan-out.

4f. `sync()`:

```dart
  @override
  Future<SyncResult> sync(SyncRequest request) async {
    if (_syncInFlight) {
      throw StateError('A sync is already in progress');
    }
    _syncInFlight = true;

    final coalescer = ProgressCoalescer(_progressController.add);
    final run = SyncRun(
      onProgress: (p, {required immediate}) =>
          coalescer.submit(p, immediate: immediate),
      onDive: _diveController.add,
    );
    _activeRun = run;
    _activeCoalescer = coalescer;

    // emit the initial connecting event
    run.handleProgress(0, 0); // -> reading? No: see note below.

    BleBridge? bridge;
    try {
      final transport = request.transport;
      if (transport == ComputerTransport.ble) {
        // fold the BLE connect in
        final device = _resolveBleDevice(request.endpoint); // helper, see 4g
        await _bleTransport.connect(device);
        bridge = BleBridge.allocate();
        _bleTransport.attachBridge(bridge);
        _activeBridgedTransport = _bleTransport;
        _bleBridgeReleased = Completer<void>();
      } else if (transport == ComputerTransport.bluetooth &&
          Platform.isAndroid) {
        if (request.endpoint == null) {
          throw ArgumentError('Android bluetooth sync requires an endpoint');
        }
        await _rfcommTransport.connect(request.endpoint!);
        bridge = BleBridge.allocate();
        _rfcommTransport.attachBridge(bridge);
        _activeBridgedTransport = _rfcommTransport;
        _bleBridgeReleased = Completer<void>();
      }
      await _send((DiveComputerMethod.sync, [
        request.computer,
        transport,
        request.lastFingerprint,
        bridge?.address,
        request.endpoint,
        request.knownFingerprints?.toList(growable: false),
      ]));
    } catch (e) {
      if (transportIsAndroidBt(request)) {
        await _rfcommTransport.disconnect().catchError((_) {});
      }
      bridge?.dispose();
      _bleBridgeReleased = null;
      _cleanupRun();
      rethrow;
    }

    try {
      return await run.result;
    } finally {
      if (bridge != null) {
        try {
          await _bleBridgeReleased!.future
              .timeout(const Duration(seconds: 60));
        } on TimeoutException {
          developer.log('Timed out waiting for _BleBridgeReleased',
              name: 'DiveComputerIsolate', level: 900);
        } catch (_) {}
        if (_activeBridgedTransport == _rfcommTransport) {
          await _rfcommTransport.disconnect().catchError((_) {});
        } else if (_activeBridgedTransport == _bleTransport) {
          await _bleTransport.disconnect().catchError((_) {});
        }
        bridge.dispose();
      }
      _cleanupRun();
    }
  }

  void _cleanupRun() {
    _activeCoalescer?.dispose();
    _activeCoalescer = null;
    _activeRun = null;
    _activeBridgedTransport = null;
    _bleBridgeReleased = null;
    _syncInFlight = false;
  }
```

> **Initial phase note:** `SyncRun` starts in `SyncPhase.connecting` and only leaves it on the first `handleProgress`/`handleDive`. To surface `connecting` to a UI immediately, add a one-liner to `SyncRun`: a public `void start()` that does `_emit(SyncPhase.connecting, 0, 0, force: true)`. Call `run.start()` right after constructing it, before the transport connect. Update `sync_run_test.dart` with a test for `start()` emitting one connecting event. (Do this small addition here — it belongs to Task 3's unit but is only motivated now.)

4g. Helpers:

```dart
  BleScanResult? _pendingBleDevice; // set by the deprecated connectBle()

  BleScanResult _resolveBleDevice(String? endpoint) {
    final pending = _pendingBleDevice;
    if (pending != null && (endpoint == null || endpoint == pending.id)) {
      return pending;
    }
    throw ArgumentError(
        'BLE sync needs a scanned device. Pass SyncRequest.endpoint as a '
        'BleScanResult id from scanForBleDevices(), or call the (deprecated) '
        'connectBle() first.');
  }
```

> **Design gap to resolve here:** `SyncRequest.endpoint` for BLE is a device **id string**, but `_bleTransport.connect()` needs a full `BleScanResult` (with the matched `BleProfile`). The scan (`scanForBleDevices()`) is what produces those. Options: (a) have `DiveComputer` keep a short-lived cache of the last `scanForBleDevices()` results keyed by id and look the endpoint up there; (b) keep BLE requiring a prior `connectBle()` (which already takes a `BleScanResult`) and treat `endpoint` as advisory. **Pick (a):** add `final Map<String, BleScanResult> _lastScan = {};`, populate it in `scanForBleDevices()`'s `.map((r) { _lastScan[r.id] = r; return r; })`, and have `_resolveBleDevice` consult `_lastScan[endpoint]` before falling back to `_pendingBleDevice`. Add a source-guard test: `expect(source, contains('_lastScan['));`.

4h. `closeConnection()` — add: if `_syncInFlight`, the in-flight `run` will get an error when the isolate tears down; also `_cleanupRun()` is safe to call. Leave the existing `_supportedComputersRequest = null`.

4i. `_spawnIsolate` `case DiveComputerMethod.sync:`:

```dart
        case DiveComputerMethod.sync:
          final computer = message.$2[0] as Computer;
          final transport = message.$2[1] as ComputerTransport;
          final lastFingerprint = message.$2[2] as String?;
          final bleBridgeAddress = message.$2[3] as int?;
          final address = message.$2[4] as String?;
          final knownFingerprints = (message.$2[5] as List?)?.cast<String>();
          DiveComputerFfi.diveCallback = (d) => sendPort.send(d);
          DiveComputerFfi.progressCallback =
              (c, m) => sendPort.send(_ProgressMsg(c, m));
          DiveComputerFfi.deviceInfoCallback =
              (mo, fw, sn) => sendPort.send(_DeviceInfoMsg(mo, fw, sn));
          DiveComputerFfi.skipFingerprints = knownFingerprints?.toSet() ?? {};
          DiveComputerFfi.hostPort = sendPort;
          try {
            final result = DiveComputerFfi.sync(
              computer,
              transport,
              lastFingerprint: lastFingerprint,
              bridgeAddress: bleBridgeAddress,
              address: address,
            );
            sendPort.send(result);
          } finally {
            DiveComputerFfi.diveCallback = null;
            DiveComputerFfi.progressCallback = null;
            DiveComputerFfi.deviceInfoCallback = null;
            DiveComputerFfi.skipFingerprints = {};
            DiveComputerFfi.hostPort = null;
            if (bleBridgeAddress != null) {
              sendPort.send(_BleBridgeReleased(bleBridgeAddress));
            }
          }
          break;
```

> Keep the `catch (e) { sendPort.send(initializationError ?? e); }` wrapper — a `sync()` throw becomes an `Exception`/`Error` message the main isolate routes to `_activeRun?.handleError`.

4j. `enableDebugLogging()` — add `'BridgedTransport'` to the list of logger names forwarded (it currently forwards `'RfcommTransport'`, `'RfcommChannel'`, and the BLE transport log).

4k. Edit `dive_computer_unsupported.dart` — it only needs to compile against the new interface. The base `DiveComputerInterface` already throws `UnimplementedError` for the new members, and `dive_computer_unsupported.dart`'s `DiveComputer` extends it without overriding, so **likely no change needed** — verify it still compiles. If `download`/`connectBle` are referenced there, they aren't (the file is 8 lines).

- [ ] **Step 5: Run tests**

Run: `flutter test test/framework/dive_computer_isolate_test.dart`
Expected: PASS.

Run: `flutter test`
Expected: green except `dive_computer_interface_test.dart` (Task 10) and possibly `dive_computer_ffi_bluetooth_test.dart`. Check `dive_computer_ffi_bluetooth_test.dart` — if it greps `DiveComputerFfi.download`, update the grep to `DiveComputerFfi.sync` and the arg shape; if it exercises real FFI it's skipped without a device anyway.

- [ ] **Step 6: Commit**

```bash
git add lib/framework/dive_computer_isolate.dart lib/framework/dive_computer_interface.dart lib/framework/dive_computer_unsupported.dart lib/framework/sync/sync_run.dart test/framework/sync/sync_run_test.dart test/framework/dive_computer_isolate_test.dart test/framework/dive_computer_ffi_bluetooth_test.dart
git commit -m "feat: DiveComputer.sync() + syncProgress/diveStream + WriteReady routing"
```

---

### Task 10: Deprecated `download()` / `connectBle()` / `disconnectBle()` shims

**Files:**
- Modify: `lib/framework/dive_computer_isolate.dart`
- Modify: `test/framework/dive_computer_interface_test.dart`
- Create: `test/framework/download_shim_test.dart`

**Interfaces:**
- Consumes: `sync()` / `diveStream` (Task 9).
- Produces:
  - `@Deprecated(...) Future<List<Dive>> download(Computer computer, ComputerTransport transport, [String? lastFingerprint, String? address, void Function(Dive dive)? onDive, Iterable<String>? knownFingerprints])` — builds a `SyncRequest`, subscribes `diveStream` (collect + forward to `onDive`), awaits `sync()`, returns the collected list; on `SyncStatus.failed` rethrows `result.error` **after** the caller has already received every dive via `onDive`.
  - `@Deprecated(...) Future<void> connectBle(BleScanResult device)` — stores `device` in `_pendingBleDevice`; the next `sync()` with `transport: ble` uses it.
  - `@Deprecated(...) Future<void> disconnectBle()` — `_pendingBleDevice = null`; if `_bleTransport.isConnected && !_syncInFlight` → `await _bleTransport.disconnect()`.

- [ ] **Step 1: Write the failing tests**

`test/framework/download_shim_test.dart` (source-level — the shim can't run without an isolate):

```dart
import 'dart:io';
import 'package:test/test.dart';

void main() {
  final source =
      File('lib/framework/dive_computer_isolate.dart').readAsStringSync();

  test('download() is deprecated and delegates to sync()', () {
    final m = RegExp(
            r"@Deprecated\('Use sync\(SyncRequest\)\. Will be removed in a "
            r"future major version\.'\)\s*@override\s*Future<List<Dive>> "
            r'download\(.*?\n  \}',
            dotAll: true)
        .firstMatch(source);
    expect(m, isNotNull, reason: 'download() must carry the exact deprecation');
    final body = m!.group(0)!;
    expect(body, contains('sync(SyncRequest('));
    expect(body, contains('diveStream.listen'));
    expect(body, contains('onDive?.call'));
  });

  test('connectBle/disconnectBle are deprecated and manage _pendingBleDevice',
      () {
    expect(source, contains('_pendingBleDevice = device'));
    expect(source, contains('_pendingBleDevice = null'));
    expect("@Deprecated('Use sync(SyncRequest). Will be removed in a future "
                "major version.')"
            .allMatches(source)
            .length,
        greaterThanOrEqualTo(3));
  });
}
```

Update `test/framework/dive_computer_interface_test.dart` — the `download` signature test stays (it still exists), add:

```dart
  test('sync throws UnimplementedError by default', () {
    expect(() => iface.sync(SyncRequest(
          computer: computer,
          transport: ComputerTransport.bluetooth,
        )), throwsUnimplementedError);
  });

  test('syncProgress / diveStream throw UnimplementedError by default', () {
    expect(() => iface.syncProgress, throwsUnimplementedError);
    expect(() => iface.diveStream, throwsUnimplementedError);
  });
```

(add the `sync.dart` import to that test file).

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/framework/download_shim_test.dart test/framework/dive_computer_interface_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement the shims in `dive_computer_isolate.dart`**

```dart
  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  @override
  Future<List<Dive>> download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
    String? address,
    void Function(Dive dive)? onDive,
    Iterable<String>? knownFingerprints,
  ]) async {
    final collected = <Dive>[];
    final sub = diveStream.listen((d) {
      collected.add(d);
      onDive?.call(d);
    });
    try {
      final result = await sync(SyncRequest(
        computer: computer,
        transport: transport,
        endpoint: address,
        lastFingerprint: lastFingerprint,
        knownFingerprints: knownFingerprints?.toSet(),
      ));
      if (result.status == SyncStatus.failed && result.error != null) {
        // Match the old contract: every parsed dive was already delivered via
        // onDive before we surface the failure.
        throw result.error!;
      }
      return collected;
    } finally {
      await sub.cancel();
    }
  }

  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  @override
  Future<void> connectBle(BleScanResult device) async {
    _pendingBleDevice = device;
  }

  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  @override
  Future<void> disconnectBle() async {
    _pendingBleDevice = null;
    if (_bleTransport.isConnected && !_syncInFlight) {
      await _bleTransport.disconnect();
    }
  }
```

Remove the old `connectBle`/`disconnectBle` implementations that called `_bleTransport.connect`/`.disconnect` directly (the connect now happens inside `sync()`).

> **Behavioural change to document (Task 11):** `connectBle()` no longer opens the GATT connection eagerly — it's deferred to `sync()`. The BLE debug screen's "Connect" then "Download" buttons still work because `sync()` connects; a caller that relied on `connectBle()` throwing on a bad device now gets that error from `sync()` instead.

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/download_shim_test.dart test/framework/dive_computer_interface_test.dart`
Expected: PASS.

Run: `flutter test`
Expected: fully green (minus the known `ble_bridge_state_test.dart` flake).

- [ ] **Step 5: Commit**

```bash
git add lib/framework/dive_computer_isolate.dart test/framework/download_shim_test.dart test/framework/dive_computer_interface_test.dart
git commit -m "feat: @Deprecated download()/connectBle()/disconnectBle() shims over sync()"
```

---

### Task 11: Migration guide

**Files:**
- Create: `doc/migration/1.x-to-2.0.md`
- Test: none (documentation) — folded into this task.

- [ ] **Step 1: Write `doc/migration/1.x-to-2.0.md`**

```markdown
# Migrating from `download()` to `sync()`

`download()` and its friends still work but are `@Deprecated` and will be
removed in a future major version. Move to `sync()`.

## `download()` → `sync()`

**Before:**

```dart
final dives = await dc.download(
  computer,
  ComputerTransport.bluetooth,
  lastFingerprint,       // positional #3
  address,               // positional #4
  (dive) => save(dive),  // positional #5 — onDive
  knownHashes,           // positional #6
);
```

**After:**

```dart
final sub = dc.diveStream.listen(save);   // was the onDive callback
final result = await dc.sync(SyncRequest(
  computer: computer,
  transport: ComputerTransport.bluetooth,
  endpoint: address,                       // COM port / BT MAC / BLE id
  lastFingerprint: lastFingerprint,
  knownFingerprints: knownHashes?.toSet(),
));
await sub.cancel();
```

## What changed

| Old | New |
|---|---|
| `onDive` positional callback | `dc.diveStream` broadcast stream — subscribe before calling `sync()` |
| return value `List<Dive>` | dives come **only** via `diveStream`; `SyncResult` carries `divesParsed` / `divesSkipped` / `fingerprints` / `status`, not the dive objects. Accumulate the list yourself from the stream if you need it. |
| `knownFingerprints` as `Iterable<String>` | `SyncRequest.knownFingerprints` as `Set<String>?` |
| no progress | `dc.syncProgress` — `Stream<SyncProgress>` with `phase` / `current` / `maximum` / `divesParsed` and a `fraction` getter (null until the device reports a total) |
| BLE: `await dc.connectBle(device); await dc.download(computer, ComputerTransport.ble);` | `await dc.sync(SyncRequest(computer: computer, transport: ComputerTransport.ble, endpoint: device.id));` — `sync()` connects internally. Call `scanForBleDevices()` first so the plugin can resolve the id. |
| a mid-transfer failure threw, but `onDive` had already delivered parsed dives | same: `sync()` completes with `SyncResult(status: failed, error: ...)`; the `download()` shim rethrows that error, but every dive parsed before the failure was already delivered on `diveStream`. `sync()` callers check `result.status` instead of catching. |

## `lastFingerprint` vs `knownFingerprints`

- **`lastFingerprint`** — "I already have every dive up to this one." The device
  stops sending when it reaches it. Fast. Use to top up a log. Ends with
  `SyncStatus.stoppedAtKnownDive`.
- **`knownFingerprints`** — "skip these specific dives." The device still
  transfers every dive's bytes; only the parse + `diveStream` emit are skipped.
  Use to resume an interrupted full backfill.
- They combine: `lastFingerprint` for the recent boundary, `knownFingerprints`
  for gaps below it.

## `connectBle()` / `disconnectBle()`

Deprecated. `sync()` with `transport: ComputerTransport.ble` opens and closes the
connection itself. If you still call `connectBle()`, it no longer opens the GATT
connection eagerly — that's deferred to the next `sync()`.
```

- [ ] **Step 2: Sanity-check links**

Confirm the file renders (no broken tables) and that `README.md` / `CHANGELOG.md` get a one-line pointer added:

```markdown
<!-- CHANGELOG.md, under an Unreleased / next-version heading -->
- **BREAKING (soft):** `download()` deprecated in favour of `sync(SyncRequest)`
  with `syncProgress` / `diveStream`. See `doc/migration/1.x-to-2.0.md`.
  `download()` still works.
```

- [ ] **Step 3: Commit**

```bash
git add doc/migration/1.x-to-2.0.md CHANGELOG.md README.md
git commit -m "docs: download() -> sync() migration guide"
```

---

### Task 12: Migrate the example app

**Files:**
- Modify: `example/lib/main.dart`
- Modify: `example/lib/ble_download_support.dart` (only if it calls `download()`/`connectBle()` — check)

**Interfaces:**
- Consumes: `dc.sync()`, `dc.syncProgress`, `dc.diveStream`, `SyncRequest`, `SyncProgress`, `SyncResult`, `SyncStatus`.

- [ ] **Step 1: Migrate the Bluetooth flow in `_downloadFrom`**

Replace the `dc.download(computer, ComputerTransport.bluetooth, null, picked.address, (dive) {...}, known)` call and its manual status string with:

```dart
    final sub = dc.diveStream.listen((dive) {
      count++;
      pending.writeln(jsonEncode(dive.toJson()));
      final now = DateTime.now();
      if (count % 20 == 0 ||
          now.difference(lastDrained) > const Duration(seconds: 2)) {
        outFile.writeAsStringSync(pending.toString(), mode: FileMode.append);
        pending.clear();
        lastDrained = now;
      }
    });
    final progressSub = dc.syncProgress.listen((p) {
      status.value = switch (p.phase) {
        SyncPhase.connecting => 'Connecting…\nKeep the Petrel on its BT screen.',
        SyncPhase.reading => p.fraction != null
            ? 'Downloading… ${(p.fraction! * 100).toStringAsFixed(0)}%  '
                '(${p.divesParsed} dives)'
            : 'Downloading… ${p.divesParsed} dives',
        SyncPhase.parsing => 'Downloading… ${p.divesParsed} dives saved\n'
            '→ ${outFile.path}',
        SyncPhase.done => 'Finishing…',
      };
    });
    try {
      final result = await dc.sync(SyncRequest(
        computer: computer,
        transport: ComputerTransport.bluetooth,
        endpoint: picked.address,
        knownFingerprints: known,
      ));
      if (pending.isNotEmpty) {
        outFile.writeAsStringSync(pending.toString(), mode: FileMode.append);
      }
      status.value = switch (result.status) {
        SyncStatus.failed => 'Stopped at $count dives: ${result.error}\n'
            'Re-run — it skips what is already saved.',
        _ => 'Done — $count dives '
            '(${result.divesParsed} new, ${result.divesSkipped} skipped).\n'
            'Saved to:\n${outFile.path}',
      };
    } finally {
      await sub.cancel();
      await progressSub.cancel();
    }
```

Remove the old `try/catch` that duplicated the "stopped at N" handling and the `dives.length` reference (no longer returned).

- [ ] **Step 2: Add a `LinearProgressIndicator` to the status dialog**

In the `AlertDialog` content, alongside the `ValueListenableBuilder<String>`, add a second `StreamBuilder<SyncProgress>` on `dc.syncProgress`:

```dart
            StreamBuilder<SyncProgress>(
              stream: dc.syncProgress,
              builder: (_, snap) {
                final f = snap.data?.fraction;
                return LinearProgressIndicator(value: f);
              },
            ),
```

- [ ] **Step 3: Migrate the serial flow**

The one remaining `dc.download(computer, transport, 'exampleFingerprint', serialPort)` → 

```dart
      final result = await dc.sync(SyncRequest(
        computer: computer,
        transport: transport,
        endpoint: serialPort,
        lastFingerprint: 'exampleFingerprint',
      ));
      messenger.showSnackBar(SnackBar(
          content: Text('Synced ${result.divesParsed} dives '
              '(${result.status.name})')));
```

- [ ] **Step 4: Migrate the BLE debug screen (`_connectAndDownload`)**

```dart
      _print('Connecting + downloading ${device.name} as $computer ...');
      final dives = <Dive>[];
      final sub = dc.diveStream.listen(dives.add);
      try {
        final result = await dc.sync(SyncRequest(
          computer: computer,
          transport: ComputerTransport.ble,
          endpoint: device.id,
        ));
        _print('Sync ${result.status.name}: ${result.divesParsed} dives');
      } finally {
        await sub.cancel();
      }
      setState(() => _dives = dives);
```

Remove the explicit `dc.connectBle(device)` and the `dc.disconnectBle()` in `finally` (sync owns the lifecycle). Keep the scan-stop-before-transfer logic. `scanForBleDevices()` must have run (it has — that's how `_found` is populated), so `_lastScan` has the id.

- [ ] **Step 5: Run the example's analyzer + tests**

Run: `cd example && flutter analyze && cd ..`
Expected: no errors. (Deprecation warnings for any leftover `download()` are acceptable to see but there should be none — you migrated them all.)

Run: `flutter test`
Expected: fully green (minus the known flake).

- [ ] **Step 6: Commit**

```bash
git add example/lib/main.dart example/lib/ble_download_support.dart
git commit -m "example: migrate to sync() + syncProgress + diveStream"
```

---

## Manual on-device verification (after Task 12)

Not automatable — run on the user's Shearwater Petrel + Android phone over Bluetooth Classic:

1. **Full sync from an empty file:** progress bar advances, dive count climbs, ends `SyncStatus.completed`, JSONL has every dive.
2. **`lastFingerprint` top-up:** set `SyncRequest.lastFingerprint` to the newest saved dive's hash → ends `SyncStatus.stoppedAtKnownDive`, only newer dives (or none) on `diveStream`.
3. **`knownFingerprints` resume:** interrupt run 1 partway, re-run with the saved hashes as `knownFingerprints` → `result.divesSkipped > 0`, transfer still takes the full wire time (expected — SP2 territory), only the not-yet-saved dives emit.
4. **Pump latency check:** enable debug logging, confirm `WriteReady`-driven writes (not the 250 ms safety net) service the mailbox during a real transfer — transfer time should be no worse than the pre-refactor baseline (~30–40 min for 600 dives on BT 2.0).

---

## Self-Review

**1. Spec coverage:**

| Spec section | Task |
|---|---|
| §1 new API surface (`sync`, `syncProgress`, `diveStream`, deprecations) | 1, 9, 10 |
| §2 value types (`SyncRequest`/`SyncProgress`/`SyncResult` + enums) | 1 |
| §3 streams & lifecycle (broadcast, per-run scoping, concurrency guard, no replay) | 3, 9 |
| §4 `BridgedTransport` base + `_WriteReady` + safety net | 4, 5, 6, 7 |
| §5 `dc_device_set_events` → `SyncProgress`, 100 ms coalescing, phases, DEVINFO internal | 2, 3, 8 |
| §6 deprecation shims + `_runSync` sharing + migration guide + example | 9 (`sync()` is the shared core), 10, 11, 12 |
| §7 testing (unit for types/coalescer/run/base; source guards for isolate/FFI; on-device) | every task + the manual section |
| §"Data flow" trace | realised across 7, 8, 9 |
| §"Risks" — `SendPort` in write callback | Task 7 (resolved: background isolate already holds `sendPort`; stashed via `DiveComputerFfi.hostPort`) |
| §"Risks" — `stoppedAtKnownDive` detection | Task 8 step 3e (`_stoppedAtKnownDive` flag in `_dive_callback`) |
| §"Risks" — broadcast stream, zero listeners | `StreamController.broadcast().add` is a no-op with no listener; Task 9 relies on it, Task 3's sink tests cover the run side |
| §"Risks" — ffigen event bindings | Global Constraints: confirmed already generated |
| §"Risks" — per-vendor `maximum` semantics | Task 1 (`fraction` returns null) + Task 12 (`LinearProgressIndicator(value: null)` renders indeterminate) |

Gap found and folded in: the spec's §2 `endpoint` doc says BLE takes a "device id" but `BleTransport.connect` needs a `BleScanResult` — resolved in Task 9 step 4g with the `_lastScan` id→result cache.

**2. Placeholder scan:** No "TBD"/"handle errors appropriately"/"similar to Task N". Task 6 references code "as-is" but names every member to keep and every member to remove. Task 9 is large but each edit block is concrete.

**3. Type consistency:**
- `SyncRun` constructor `onProgress` signature `void Function(SyncProgress, {required bool immediate})` — same in Task 3 definition, Task 3 test, and Task 9 call site. ✔
- `ProgressCoalescer.submit(SyncProgress, {bool immediate})` — consistent Task 2 ↔ Task 9.
- `DiveComputerFfi.sync(computer, transport, {String? lastFingerprint, int? bridgeAddress, String? address})` — defined Task 8, called Task 9 step 4i with named args. ✔
- `BridgedTransport` hooks `writeToDevice` / `inboundBytes` / `closeDevice` / `isDeviceConnected` — same names in Task 4 base, Task 4 fake, Task 5 `RfcommTransport`, Task 6 `BleTransport`. ✔
- `WriteReady` / `syncHostPort` — Task 7 definition, Task 7 callback use, Task 9 `DiveComputerFfi.hostPort` setter. ✔
- `DiveComputerMethod.sync` — renamed Task 9, used in Task 9 `_spawnIsolate`. The Task 7 note about editing the `download` case is superseded by Task 9's rename — Task 7 only adds the `syncHostPort` line, which Task 9 relocates into the `.sync` case; net result is one `hostPort` set/clear pair. Executor: if doing Task 7 before Task 9, put the set/clear in the existing `download` case; Task 9 moves it.

Fix applied inline: Task 7 step 5 reworded to say the set/clear lands in whichever case exists at the time and Task 9 owns the final placement.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-08-30-sp1-unified-sync-api.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
