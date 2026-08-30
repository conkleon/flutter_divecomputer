import 'package:dive_computer/framework/sync/sync_run.dart';
import 'package:dive_computer/types/dive.dart';
import 'package:dive_computer/types/sync.dart';
import 'package:flutter_test/flutter_test.dart';

class _Rec {
  final progress = <SyncProgress>[];
  final immediates = <bool>[];
  final dives = <Dive>[];
  late final SyncRun run = SyncRun(
    onProgress: (p, {required immediate}) {
      progress.add(p);
      immediates.add(immediate);
    },
    onDive: dives.add,
  );
}

Dive _dive(String hash) => Dive(
      hash,
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
      samples: const [],
    );

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

  test('handleError completes with a failed result and emits no progress',
      () async {
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

  test('start() emits exactly one immediate connecting progress', () {
    final r = _Rec();
    expect(r.progress, isEmpty);
    r.run.start();
    expect(r.progress.single.phase, SyncPhase.connecting);
    expect(r.progress.single.divesParsed, 0);
    expect(r.immediates.single, isTrue);
  });
}
