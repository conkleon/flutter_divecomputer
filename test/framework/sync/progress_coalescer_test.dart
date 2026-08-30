import 'package:dive_computer/framework/sync/progress_coalescer.dart';
import 'package:dive_computer/types/sync.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

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
