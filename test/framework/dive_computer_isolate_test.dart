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
    // Narrow on purpose: the deprecated `Future<List<Dive>> download(...)`
    // shim legitimately reintroduces the `List<Dive>` literal. What must stay
    // gone is the completer and the port-listener branch that fed it.
    expect(source, isNot(contains('_downloadedDives')));
    expect(source, isNot(contains('message is List<Dive>')));
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
      // Bounded rather than [^;]*: an explanatory comment between the branch
      // and the call is fine, and a semicolon in it must not break the guard.
      RegExp(r'is WriteReady\)[\s\S]{0,400}?'
              r'_activeBridgedTransport\?\.serviceMailbox')
          .hasMatch(source),
      isTrue,
    );
  });

  test('sync() never pushes errors onto the public streams', () {
    // Failures travel through SyncRun (-> SyncResult.failed / a thrown
    // pre-connection error), never as a stream error that would kill every
    // subscriber of these long-lived broadcast controllers.
    expect(source, isNot(contains('_progressController.addError')));
    expect(source, isNot(contains('_diveController.addError')));
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

  /// The body of `Future<SyncResult> sync(SyncRequest request)`, delimited by
  /// the next member (`_cleanupRun`) rather than the first `\n  }` — the
  /// method is full of nested blocks and an early match would silently
  /// truncate the ordering assertions below into a false pass.
  String syncBody() {
    final m = RegExp(
            r'Future<SyncResult> sync\(SyncRequest request\).*?\n  void _cleanupRun',
            dotAll: true)
        .firstMatch(source);
    expect(m, isNotNull, reason: 'could not locate the sync() method body');
    return m!.group(0)!;
  }

  test('the bridge is released, then the transport is torn down, then and '
      'only then is the bridge disposed', () {
    // The use-after-free this whole task is built to avoid: BridgedTransport's
    // inbound subscription and its 250ms safety-net timer can still reach into
    // the bridge during disconnect()'s await, so dispose() MUST come last.
    final body = syncBody();
    const handshake = '_bleBridgeReleased?.future.timeout';
    const dispose = 'bridge.dispose()';
    for (final needle in const [handshake, dispose, '.disconnect()']) {
      expect(body, contains(needle));
    }
    final iHandshake = body.indexOf(handshake);
    // The first disconnect AFTER the handshake — sync() also disconnects on
    // the pre-send failure path, which is a different (earlier) block.
    final iDisconnect = body.indexOf('.disconnect()', iHandshake);
    final iDispose = body.indexOf(dispose);
    expect(iDisconnect, greaterThan(iHandshake),
        reason: 'the bridge must be released by the FFI isolate before the '
            'transport is torn down');
    expect(iDispose, greaterThan(iDisconnect),
        reason: 'freeing the bridge before disconnect() completes is a '
            'use-after-free on shared native memory');
    expect(body, contains('const Duration(seconds: 60)'),
        reason: 'a lost handshake must not hang sync() forever');
  });

  test('the background isolate signals _BleBridgeReleased from its finally',
      () {
    final syncCase =
        RegExp(r'case DiveComputerMethod\.sync:.*?\n          break;',
                dotAll: true)
            .firstMatch(source)
            ?.group(0);
    expect(syncCase, isNotNull);
    final iFinally = syncCase!.indexOf('} finally {');
    expect(iFinally, greaterThan(-1));
    expect(
      syncCase.substring(iFinally),
      contains('sendPort.send(_BleBridgeReleased('),
      reason: 'the handshake must fire even when the transfer throws, or the '
          'main isolate waits out the full 60s timeout',
    );
  });
}
