import 'dart:io';
import 'package:test/test.dart';

void main() {
  final source =
      File('lib/framework/dive_computer_ffi.dart').readAsStringSync();

  test('the debug-build dive cap is not present in _dive_callback', () {
    expect(
      source.contains('_divesCache.length >= 5'),
      isFalse,
      reason: 'The kDebugMode 5-dive download cap must stay removed — '
          'the plugin downloads the full dive log. See '
          'docs/superpowers/specs/2026-08-28-mares-cressi-ble-example-design.md',
    );
  });

  test('_connectSerial picks a port via selectSerialPort, not a blind names[0]',
      () {
    expect(
      source.contains('names[0]'),
      isFalse,
      reason: 'Opening the first enumerated COM port is non-deterministic on '
          'Windows (Bluetooth SPP ports). The caller-chosen / first port must '
          'go through selectSerialPort().',
    );
    expect(source, contains('selectSerialPort(names, requested: serialPortName)'));
  });

  test('_connectBridged is transport-parameterised and used by both bridged '
      'transports', () {
    expect(source, contains('_connectBridged(int bridgeAddress, int transport)'));
    expect(source, isNot(contains('_connectBle(')));
    expect(source,
        contains('_connectBridged(bridgeAddress, dc_transport_t.DC_TRANSPORT_BLE)'));
    expect(
        source,
        contains(
            '_connectBridged(bridgeAddress, dc_transport_t.DC_TRANSPORT_BLUETOOTH)'));
  });

  test('sync routes ComputerTransport.bluetooth to bridged (Android) or '
      '_connectBluetooth (Windows)', () {
    final dl = RegExp(r'case ComputerTransport\.bluetooth:(.+?)break;',
            dotAll: true)
        .firstMatch(source)
        ?.group(1);
    expect(dl, isNotNull);
    expect(dl, contains('bridgeAddress != null'));
    expect(dl, contains('_connectBridged(bridgeAddress'));
    expect(dl, contains('_connectBluetooth(computerDescriptor, address)'));
  });

  /// The body of `static SyncResult sync(...)`, delimited by the next
  /// class-level `static` declaration rather than the first `\n  }` — the
  /// method contains nested blocks and an early `\n  }` match would silently
  /// truncate every ordering assertion below into a false pass.
  String syncBody() {
    final m = RegExp(r'static SyncResult sync\((.*?)\n  static ', dotAll: true)
        .firstMatch(source);
    return m!.group(0)!;
  }

  test('sync() registers a progress + devinfo event handler before foreach', () {
    expect(source, contains('dc_device_set_events('));
    expect(source, contains('dc_event_type_t.DC_EVENT_PROGRESS'));
    expect(source, contains('dc_event_type_t.DC_EVENT_DEVINFO'));
    final body = syncBody();
    expect(body, contains('dc_device_set_events'));
    expect(body, contains('dc_device_foreach'));
    expect(
      body.indexOf('dc_device_set_events') < body.indexOf('dc_device_foreach'),
      isTrue,
      reason: 'events must be registered before the transfer starts',
    );
  });

  test('sync() is the entry point and download() is gone', () {
    expect(source, contains('static SyncResult sync('));
    expect(source, isNot(contains('static void download(')));
  });

  test('the event handler does no work beyond forwarding to a callback slot',
      () {
    // Class member, so it closes at two-space indentation.
    final handler =
        RegExp(r'void _event_callback\([^)]*\)\s*\{.*?\n  \}', dotAll: true)
            .firstMatch(source)
            ?.group(0);
    expect(handler, isNotNull);
    expect(handler, contains('DC_EVENT_PROGRESS'));
    expect(handler, contains('progressCallback'));
    expect(handler, contains('DC_EVENT_DEVINFO'));
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
    final body = syncBody();
    expect(body, contains('SyncStatus.stoppedAtKnownDive'));
    expect(body, contains('SyncStatus.completed'));
  });

  test('_dive_callback records every fingerprint and counts skips', () {
    final cb = RegExp(r'static int _dive_callback\(.*?\n  \}', dotAll: true)
        .firstMatch(source)
        ?.group(0);
    expect(cb, isNotNull);
    expect(cb, contains('_stoppedAtKnownDive = true'));
    expect(cb, contains('_fingerprintsThisRun.add(currentFingerprint)'));
    expect(cb, contains('_divesSkippedThisRun++'));
    expect(cb, contains('_divesParsedThisRun++'));
  });
}
