import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('the debug-build dive cap is not present in _dive_callback', () {
    final source =
        File('lib/framework/dive_computer_ffi.dart').readAsStringSync();
    expect(
      source.contains('_divesCache.length >= 5'),
      isFalse,
      reason: 'The kDebugMode 5-dive download cap must stay removed — '
          'the plugin downloads the full dive log. See '
          'docs/superpowers/specs/2026-08-28-mares-cressi-ble-example-design.md',
    );
  });
}
