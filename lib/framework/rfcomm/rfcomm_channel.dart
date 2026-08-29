import 'dart:async';

import 'package:flutter/services.dart';

import '../../types/bt_device.dart';

/// Main-isolate access to a Bluetooth-Classic RFCOMM connection. On Android
/// this is backed by the plugin's method/event channels; a
/// [FakeRfcommChannel] stands in for tests.
///
/// The Kotlin side reports failures via [PlatformException] with a variety of
/// error codes (`connect_failed`, `permission_denied`, `bad_args`,
/// `not_connected`, `write_failed`, `permission_request_pending`). Callers must
/// treat any such exception as a generic failure and must not branch on the
/// code.
abstract class RfcommChannel {
  Future<bool> requestPermissions();
  Future<List<BtDevice>> bondedDevices();
  Future<void> connect(String address);
  Stream<Uint8List> get inbound;
  Future<void> write(List<int> bytes);
  Future<void> disconnect();
}

class MethodChannelRfcommChannel implements RfcommChannel {
  static const _method = MethodChannel('app.divenote.dive_computer/rfcomm');
  static const _events =
      EventChannel('app.divenote.dive_computer/rfcomm/inbound');

  @override
  Future<bool> requestPermissions() async =>
      (await _method.invokeMethod<bool>('requestPermissions')) ?? false;

  @override
  Future<List<BtDevice>> bondedDevices() async {
    final raw = await _method
            .invokeListMethod<Map<Object?, Object?>>('bondedDevices') ??
        const [];
    return raw
        .map((m) => BtDevice(
            (m['name'] as String?) ?? '', (m['address'] as String?) ?? ''))
        .toList();
  }

  @override
  Future<void> connect(String address) =>
      _method.invokeMethod<void>('connect', {'address': address});

  // Cached: receiveBroadcastStream() returns a fresh stream (and re-invokes
  // the platform onListen/onCancel) on every access, but Kotlin holds exactly
  // one eventSink — repeated access would silently steal the sink.
  @override
  late final Stream<Uint8List> inbound = _events
      .receiveBroadcastStream()
      .map((e) => e is Uint8List ? e : Uint8List.fromList((e as List).cast()));

  @override
  Future<void> write(List<int> bytes) =>
      _method.invokeMethod<void>('write', {'bytes': Uint8List.fromList(bytes)});

  @override
  Future<void> disconnect() => _method.invokeMethod<void>('disconnect');
}

class FakeRfcommChannel implements RfcommChannel {
  List<BtDevice> bonded = const [];
  bool permissionGranted = true;
  String? connectedAddress;
  bool disconnected = false;
  final List<List<int>> writes = [];
  final _inbound = StreamController<Uint8List>.broadcast();

  void emitInbound(Uint8List bytes) => _inbound.add(bytes);
  void emitDisconnect() => _inbound.close();

  @override
  Future<bool> requestPermissions() async => permissionGranted;
  @override
  Future<List<BtDevice>> bondedDevices() async => bonded;
  @override
  Future<void> connect(String address) async => connectedAddress = address;
  @override
  Stream<Uint8List> get inbound => _inbound.stream;
  @override
  Future<void> write(List<int> bytes) async => writes.add(bytes);
  @override
  Future<void> disconnect() async => disconnected = true;
}
