import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../bridged_transport.dart';
import 'rfcomm_channel.dart';

final _log = Logger('RfcommTransport');

/// Main-isolate driver for a Bluetooth-Classic RFCOMM connection. RFCOMM is
/// a plain byte stream, so beyond opening the socket this only wires the
/// four [BridgedTransport] hooks.
class RfcommTransport extends BridgedTransport {
  RfcommTransport(this._channel);

  final RfcommChannel _channel;
  bool _connected = false;

  bool get isConnected => _connected;

  Future<void> connect(String address) async {
    await _channel.connect(address);
    _connected = true;
    _log.fine('RFCOMM connected to $address');
  }

  /// Public alias kept for `dive_computer_isolate.dart`, which calls
  /// `disconnect()` in its teardown paths.
  Future<void> disconnect() => teardown();

  // --- BridgedTransport hooks ---

  @override
  bool get isDeviceConnected => _connected;

  @override
  Future<void> writeToDevice(Uint8List bytes) => _channel.write(bytes);

  @override
  Stream<Uint8List> get inboundBytes => _channel.inbound;

  @override
  Future<void> closeDevice() async {
    _connected = false;
    await _channel.disconnect().catchError((_) {});
  }
}
