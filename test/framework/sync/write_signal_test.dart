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
    final src =
        File('lib/framework/ble/ble_bridge_callbacks.dart').readAsStringSync();
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

  test('the FFI layer exposes a hostPort setter that assigns syncHostPort', () {
    final src =
        File('lib/framework/dive_computer_ffi.dart').readAsStringSync();
    // T7 only adds the pass-through setter; T9 owns the set/clear in
    // _spawnIsolate, so we assert the setter body, not `syncHostPort = null`.
    expect(src, contains('set hostPort'));
    expect(src, contains('syncHostPort = p'));
    expect(src, contains('syncHostPort ='));
  });
}
