import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_central.dart';
import 'package:dive_computer/framework/ble/fake_ble_central.dart';
import 'package:dive_computer/framework/ble/ble_transport.dart';
import 'package:dive_computer/framework/dive_computer_ffi_bindings_generated.dart';
import 'package:dive_computer/types/ble_profile.dart';
import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:test/test.dart';

const _profile = BleProfile(
  namePattern: 'Test',
  serviceUuid: 'service-1',
  writeCharUuid: 'write-1',
  notifyCharUuid: 'notify-1',
  writeWithResponse: false,
);

BleScanResult _device({String id = 'dev-1'}) =>
    BleScanResult(id: id, name: 'Test Device', rssi: -50, profile: _profile);

FakeBleCentral _centralWithMatchingService(String deviceId) {
  final central = FakeBleCentral();
  central.servicesForDevice[deviceId] = [
    BleGattService('service-1', ['write-1', 'notify-1']),
  ];
  return central;
}

void main() {
  test('connect() succeeds when the expected service is present', () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);

    await transport.connect(device);

    expect(transport.isConnected, isTrue);
  });

  test('connect() fails fast (no retry) when the expected service is missing',
      () async {
    final device = _device();
    final central = FakeBleCentral(); // no services seeded
    final transport = BleTransport(central);

    await expectLater(
      () => transport.connect(device, maxAttempts: 1),
      throwsA(isA<StateError>()),
    );
    expect(central.connectCallCount, 1);
  });

  test('connect() retries on failure and eventually succeeds', () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id)
      ..failNextConnect = true;
    final transport = BleTransport(central);

    await transport.connect(device, maxAttempts: 3);

    expect(transport.isConnected, isTrue);
    expect(central.connectCallCount, 2);
  });

  test('mailbox: queued outbound bytes reach the connection and get acked',
      () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);
    await transport.connect(device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);
    addTearDown(transport.disconnect);

    final data = calloc<ffi.Uint8>(3);
    addTearDown(() => calloc.free(data));
    data.asTypedList(3).setAll(0, [1, 2, 3]);
    final seq = bridge.queueOutbound(data, 3);

    final acked = await _pollUntil(
        () => bridge.waitForWriteAck(seq, 0), const Duration(milliseconds: 200));

    expect(acked, isTrue);
    expect(central.connections[device.id]!.writes, [
      [1, 2, 3]
    ]);
    expect(bridge.writeStatus, dc_status_t.DC_STATUS_SUCCESS);
  });

  test(
      'a retry queued mid-flight does not start a concurrent write '
      'nor ack the wrong sequence', () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);
    await transport.connect(device);
    final connection = central.connections[device.id]!;
    connection.writeDelay = const Duration(milliseconds: 60);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);
    addTearDown(transport.disconnect);

    final data = calloc<ffi.Uint8>(1);
    addTearDown(() => calloc.free(data));

    // seq 1, payload [1]
    data[0] = 1;
    final seq1 = bridge.queueOutbound(data, 1);

    // Watchdog: an ack for seq 2 must never appear before payload 2 was
    // actually handed to the connection.
    var prematureAck = false;
    final watchdog = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (bridge.waitForWriteAck(seq1 + 1, 0) && connection.writes.length < 2) {
        prematureAck = true;
      }
    });
    addTearDown(watchdog.cancel);

    // Let the mailbox timer pick up seq 1 and start the (slow) write.
    await _pollUntil(
        () => connection.writes.isNotEmpty, const Duration(milliseconds: 200));

    // libdivecomputer times out and retries while the write is in flight.
    data[0] = 2;
    final seq2 = bridge.queueOutbound(data, 1);

    final acked = await _pollUntil(
        () => bridge.waitForWriteAck(seq2, 0), const Duration(seconds: 2));

    expect(acked, isTrue);
    expect(prematureAck, isFalse);
    expect(connection.maxConcurrentWrites, 1);
    expect(connection.writes, [
      [1],
      [2]
    ]);
    expect(bridge.writeStatus, dc_status_t.DC_STATUS_SUCCESS);
  });

  test('notifications from the connection land in the bridge', () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);
    await transport.connect(device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);
    addTearDown(transport.disconnect);

    central.connections[device.id]!
        .emitNotification(Uint8List.fromList([9, 9]));
    await Future.delayed(Duration.zero);

    expect(bridge.inboundAvailable, 2);
  });

  test('a notification delivered during teardown is dropped, not pushed',
      () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);
    await transport.connect(device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);

    // Queue a notification, then tear down before the broadcast stream
    // delivers it — the listener must observe the closed/detached bridge
    // instead of writing into freed memory.
    central.connections[device.id]!
        .emitNotification(Uint8List.fromList([9, 9]));
    await transport.disconnect();
    await Future.delayed(Duration.zero);

    expect(bridge.inboundAvailable, 0);
  });

  test('connect() disconnects the GATT link when discoverServices() throws',
      () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    central.failDiscoverServices = true;
    final transport = BleTransport(central);

    await expectLater(
      () => transport.connect(device, maxAttempts: 2),
      throwsA(isA<StateError>()),
    );

    expect(transport.isConnected, isFalse);
    expect(central.connectCallCount, 2);
    // Every attempt must have closed its half-open GATT link before the next
    // one opened a new connection (Windows wedges otherwise).
    expect(central.connections[device.id]!.disconnectCallCount, 1,
        reason: 'the last attempt\'s connection must have been disconnected');
  });

  test('a real disconnect closes the bridge and tears down the timer',
      () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);
    await transport.connect(device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);

    central.connections[device.id]!.simulateDisconnect();
    await Future.delayed(Duration.zero);

    expect(bridge.isClosed, isTrue);
    expect(transport.isConnected, isFalse);
  });
}

Future<bool> _pollUntil(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future.delayed(const Duration(milliseconds: 5));
  }
  return true;
}
