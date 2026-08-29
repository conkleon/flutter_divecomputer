import 'dart:io';
import 'package:test/test.dart';

/// `DiveComputer.instance` spawns a background isolate that opens the native
/// library, so exercising the singleton getter directly under `flutter test`
/// is impractical (see the note on the getter). These source-level guards
/// pin the memoization contract from final-review finding C1 instead:
/// concurrent `supportedComputers` callers must share one future / one
/// round-trip, and a close must clear the memo so a reopen re-enumerates.
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

  test('download forwards the chosen serial port to the background isolate', () {
    // Main isolate puts computer/transport/fingerprint/bridge/address/known
    // into the message (whitespace-tolerant — the list is multi-line).
    expect(
      RegExp(r'\[\s*computer,\s*transport,\s*lastFingerprint,\s*'
              r'bridge\?\.address,\s*address,')
          .hasMatch(source),
      isTrue,
    );
    // ...and the background isolate reads it back and hands it to the FFI.
    expect(source, contains('final address = message.\$2[4] as String?'));
    expect(
      RegExp(r'DiveComputerFfi\.download\(computer, transport, lastFingerprint,'
              r'\s*bleBridgeAddress, address\)')
          .hasMatch(source),
      isTrue,
    );
  });

  test('the List<Computer>/List<Dive> replies guard against double-complete',
      () {
    expect(
      RegExp(r'is List<Computer>\)\s*\{.*?isCompleted == false\)\s*\{\s*'
              r'_supportedComputers\?\.complete\(message\)',
              dotAll: true)
          .hasMatch(source),
      isTrue,
      reason: 'A duplicate supportedComputers reply must not complete() an '
          'already-completed completer.',
    );
    expect(
      RegExp(r'is List<Dive>\)\s*\{.*?isCompleted == false\)\s*\{\s*'
              r'_downloadedDives\?\.complete\(message\)',
              dotAll: true)
          .hasMatch(source),
      isTrue,
    );
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

  test('Android bluetooth download uses the RFCOMM channel + bridge', () {
    // bluetoothDevices: Android via channel, Windows via isolate.
    expect(source, contains('Platform.isAndroid'));
    expect(source, contains('_rfcommChannel.bondedDevices()'));
    // download bluetooth on Android: connect transport, allocate bridge, attach.
    expect(source, contains('_rfcommTransport.connect('));
    expect(source, contains('_rfcommTransport.attachBridge('));
    // the download message for Android bluetooth carries a bridge address
    expect(
      RegExp(r'ComputerTransport\.bluetooth.*Platform\.isAndroid', dotAll: true)
          .hasMatch(source),
      isTrue,
    );
  });

  test('per-dive stream: onDive param, guarded field, Dive message branch, '
      'diveCallback set+cleared in the isolate', () {
    // download() accepts the onDive callback and stashes it.
    expect(source, contains('void Function(Dive dive)? onDive'));
    expect(source, contains('_onDive = onDive'));
    // a stray single-Dive reply invokes it (no completer to double-complete).
    expect(
      RegExp(r'is Dive\)\s*\{\s*//[^\n]*\n\s*_onDive\?\.call\(message\)')
          .hasMatch(source),
      isTrue,
    );
    // _onDive is cleared on both exit paths so it can't leak to the next call.
    expect('_onDive = null'.allMatches(source).length, greaterThanOrEqualTo(2));
    // the background isolate sets diveCallback -> sendPort.send(dive) and
    // clears it in the finally.
    expect(source, contains('DiveComputerFfi.diveCallback = (dive) {'));
    expect(source, contains('DiveComputerFfi.diveCallback = null;'));
  });
}
