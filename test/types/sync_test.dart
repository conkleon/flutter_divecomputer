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
