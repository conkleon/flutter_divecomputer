import 'dart:io';
import 'package:test/test.dart';

/// `DiveComputer.instance` spawns a background isolate that opens the native
/// library, so exercising the singleton getter directly under `flutter test`
/// is impractical (see the note on the getter). These source-level guards
/// pin the memoization contract from final-review finding C1 instead:
/// concurrent `supportedComputers` callers must share one future / one
/// round-trip, and a close must clear the memo so a reopen re-enumerates —
/// plus the `sync()` wiring, whose real behaviour is unit-tested on the pure
/// `SyncRun` / `ProgressCoalescer` pieces it delegates to.
void main() {
  final source =
      File('lib/framework/dive_computer_isolate.dart').readAsStringSync();

  test('supportedComputers memoizes its request future', () {
    expect(
      source.contains(
          '_supportedComputersRequest ??= _requestSupportedComputers()'),
      isTrue,
      reason: 'The getter must return the same future to concurrent callers '
          'so a second caller cannot clobber the completer.',
    );
  });

  test('closeConnection clears the supportedComputers memo', () {
    final close = RegExp(r'void closeConnection\(\)\s*\{[^}]*\}')
        .firstMatch(source)
        ?.group(0);
    expect(close, isNotNull);
    expect(close, contains('_supportedComputersRequest = null'));
  });

  test('serialPorts round-trips through the isolate with a guarded completer',
      () {
    expect(source, contains('DiveComputerMethod.serialPorts'));
    expect(
      RegExp(r'is List<String>\)\s*\{\s*if \(_serialPorts\?\.isCompleted == '
              r'false\)\s*\{\s*_serialPorts\?\.complete\(message\)')
          .hasMatch(source),
      isTrue,
      reason: 'A duplicate serialPorts reply must not complete() an '
          'already-completed completer.',
    );
  });

  test('sync forwards the endpoint and known fingerprints to the isolate', () {
    // Main isolate puts computer/transport/fingerprint/bridge/endpoint/known
    // into the message (whitespace-tolerant — the list is multi-line).
    expect(
      RegExp(r'\[\s*request\.computer,\s*request\.transport,\s*'
              r'request\.lastFingerprint,\s*bridge\?\.address,\s*'
              r'request\.endpoint,')
          .hasMatch(source),
      isTrue,
    );
    // ...and the background isolate reads it back and hands it to the FFI.
    expect(source, contains('final address = message.\$2[4] as String?'));
    expect(
      RegExp(r'DiveComputerFfi\.sync\(\s*computer,\s*transport,\s*'
              r'lastFingerprint: lastFingerprint,\s*'
              r'bridgeAddress: bleBridgeAddress,\s*address: address,')
          .hasMatch(source),
      isTrue,
    );
  });

  test('the List<Computer> reply guards against double-complete', () {
    expect(
      RegExp(r'is List<Computer>\)\s*\{.*?isCompleted == false\)\s*\{\s*'
              r'_supportedComputers\?\.complete\(message\)',
              dotAll: true)
          .hasMatch(source),
      isTrue,
      reason: 'A duplicate supportedComputers reply must not complete() an '
          'already-completed completer.',
    );
  });

  test('the dives-as-a-list reply path is gone (dives stream only)', () {
    expect(source, isNot(contains('_downloadedDives')));
    expect(source, isNot(contains('List<Dive>')));
  });

  test('bluetoothDevices round-trips with a guarded completer', () {
    expect(source, contains('DiveComputerMethod.bluetoothDevices'));
    expect(
      RegExp(r'is List<BtDevice>\)\s*\{\s*if \(_bluetoothDevices\?\.isCompleted'
              r' == false\)\s*\{\s*_bluetoothDevices\?\.complete\(message\)')
          .hasMatch(source),
      isTrue,
    );
  });

  test('_spawnIsolate handles bluetoothDevices via the FFI layer', () {
    expect(source,
        contains('DiveComputerFfi.bluetoothDevices(message.\$2[0] as Computer)'));
  });

  test('Android bluetooth sync uses the RFCOMM channel + bridge', () {
    // bluetoothDevices: Android via channel, Windows via isolate.
    expect(source, contains('Platform.isAndroid'));
    expect(source, contains('_rfcommChannel.bondedDevices()'));
    // sync over bluetooth on Android: connect transport, allocate bridge, attach.
    expect(source, contains('_rfcommTransport.connect('));
    expect(source, contains('_rfcommTransport.attachBridge('));
    // the sync message for Android bluetooth carries a bridge address
    expect(
      RegExp(r'ComputerTransport\.bluetooth.*Platform\.isAndroid', dotAll: true)
          .hasMatch(source),
      isTrue,
    );
  });

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
    expect(source, contains('run.start()'));
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
      RegExp(r'is _DeviceInfoMsg\)[^;]*_activeRun\?\.handleDeviceInfo')
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
    // Both the reply port and the isolate onError port must feed the run.
    expect(
      '_activeRun?.handleError'.allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
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
    // every slot cleared in the finally so it cannot leak into the next run
    for (final cleared in const [
      'DiveComputerFfi.diveCallback = null;',
      'DiveComputerFfi.progressCallback = null;',
      'DiveComputerFfi.deviceInfoCallback = null;',
      'DiveComputerFfi.skipFingerprints = {};',
    ]) {
      expect(source, contains(cleared));
    }
  });

  test('BLE sync resolves its device from the last scan', () {
    expect(source, contains('_lastScan['));
    expect(source, contains('_resolveBleDevice('));
    expect(source, contains('_pendingBleDevice'));
  });

  test('the bridge is released before dispose, bounded by a timeout', () {
    expect(source, contains('_bleBridgeReleased'));
    expect(source, contains('const Duration(seconds: 60)'));
    expect(source, contains('bridge.dispose()'));
  });
}
