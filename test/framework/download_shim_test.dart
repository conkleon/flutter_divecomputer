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
    expect(
        "@Deprecated('Use sync(SyncRequest). Will be removed in a future "
                "major version.')"
            .allMatches(source)
            .length,
        greaterThanOrEqualTo(3));
  });
}
