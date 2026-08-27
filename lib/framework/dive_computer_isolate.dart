import 'dart:async';
import 'dart:isolate';
import 'dart:developer' as developer;

import 'package:dive_computer/framework/dive_computer_interface.dart';
import 'package:dive_computer/framework/dive_computer_ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_central.dart';
import 'package:dive_computer/framework/ble/ble_transport.dart';
import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:dive_computer/types/computer.dart';
import 'package:dive_computer/types/dive.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

enum DiveComputerMethod {
  openConnection,
  closeConnection,
  enableDebugLogging,
  supportedComputers,
  download,
}

typedef IsolateMessage = (DiveComputerMethod method, List<dynamic> args);

/// Sent by the background isolate once it has fully returned from
/// [DiveComputerFfi.download] (past its own iostream-close finally block) for a
/// BLE transfer — only then is it safe for the main isolate to free the bridge's
/// shared native memory. See the design spec's "no leaks, explicit two-phase
/// teardown".
class _BleBridgeReleased {
  const _BleBridgeReleased(this.address);
  final int address;
}

class DiveComputer implements DiveComputerInterface {
  late ReceivePort _receivePort, _errorPort;
  late Completer<SendPort> _sendPort;

  static DiveComputer? _instance;
  static DiveComputer get instance => _instance ??= DiveComputer._();

  Completer<List<Computer>>? _supportedComputers;
  Completer<List<Dive>>? _downloadedDives;

  final BleTransport _bleTransport = BleTransport(UniversalBleCentral());
  Completer<void>? _bleBridgeReleased;

  DiveComputer._() {
    _receivePort = ReceivePort();
    _errorPort = ReceivePort();
    _sendPort = Completer<SendPort>();

    Isolate.spawn(
      _spawnIsolate,
      _receivePort.sendPort,
      onError: _errorPort.sendPort,
    );
    _receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort.complete(message);
      } else if (message is List<Computer>) {
        _supportedComputers?.complete(message);
      } else if (message is List<Dive>) {
        _downloadedDives?.complete(message);
      } else if (message is _BleBridgeReleased) {
        // Guarded: complete() on an already-completed completer throws inside
        // this listener and would wedge the singleton's port handler.
        if (_bleBridgeReleased?.isCompleted == false) {
          _bleBridgeReleased?.complete();
        }
      } else if (message is Error || message is Exception) {
        if (_supportedComputers?.isCompleted == false) {
          _supportedComputers?.completeError(message);
        }
        if (_downloadedDives?.isCompleted == false) {
          _downloadedDives?.completeError(message);
        }
      } else {
        throw UnimplementedError('Message not implemented: $message');
      }
    });
  }

  Future<void> _send(IsolateMessage message) async {
    final sendPort = await _sendPort.future;
    sendPort.send(message);
  }

  @override
  void openConnection() {
    _send((DiveComputerMethod.openConnection, []));
  }

  @override
  void closeConnection() {
    _send((DiveComputerMethod.closeConnection, []));
  }

  @override
  void enableDebugLogging() async {
    // One switch controls both isolates: BleTransport lives here on the main
    // isolate, so the background-isolate message alone can never enable it.
    hierarchicalLoggingEnabled = true;
    forwardLoggerToDeveloperLog(bleTransportLog);
    bleTransportLog.level = Level.FINEST;
    _send((DiveComputerMethod.enableDebugLogging, []));
  }

  @override
  Future<List<Computer>> get supportedComputers async {
    await _send((DiveComputerMethod.supportedComputers, []));
    return (_supportedComputers = Completer()).future;
  }

  @override
  Stream<BleScanResult> scanForBleDevices() => _bleTransport.scanForDevices();

  @override
  Future<void> connectBle(BleScanResult device) =>
      _bleTransport.connect(device);

  @override
  Future<void> disconnectBle() => _bleTransport.disconnect();

  @override
  Future<List<Dive>> download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
  ]) async {
    BleBridge? bridge;
    // Allocate/attach/send are grouped so that any failure before the send is
    // confirmed disposes the bridge and rethrows WITHOUT entering the
    // await-released path below: the background isolate never received the
    // bridge, so _BleBridgeReleased would never arrive and download() would
    // hang forever.
    try {
      if (transport == ComputerTransport.ble) {
        if (!_bleTransport.isConnected) {
          throw StateError(
              'download() with ComputerTransport.ble requires connectBle() '
              'to have succeeded first');
        }
        bridge = BleBridge.allocate();
        _bleTransport.attachBridge(bridge);
        _bleBridgeReleased = Completer<void>();
      }
      await _send((
        DiveComputerMethod.download,
        [computer, transport, lastFingerprint, bridge?.address],
      ));
    } catch (_) {
      if (bridge != null) {
        bridge.dispose();
        bridge = null;
      }
      _bleBridgeReleased = null;
      rethrow;
    }
    try {
      return await (_downloadedDives = Completer()).future;
    } finally {
      if (bridge != null) {
        await _bleBridgeReleased!.future;
        bridge.dispose();
      }
    }
  }
}

_spawnIsolate(SendPort sendPort) {
  developer.log(
    'Spawning DiveComputerFfi in an Isolate',
    name: 'DiveComputerIsolate',
  );

  Object? initializationError;
  try {
    DiveComputerFfi.initialize();
  } catch (e) {
    initializationError = e;
  }

  ReceivePort receivePort = ReceivePort();
  receivePort.listen((message) {
    message = message as IsolateMessage;
    try {
      switch (message.$1) {
        case DiveComputerMethod.openConnection:
          DiveComputerFfi.openConnection();
          if (kDebugMode) DiveComputerFfi.enableDebugLogging();
          break;
        case DiveComputerMethod.closeConnection:
          DiveComputerFfi.closeConnection();
          break;
        case DiveComputerMethod.enableDebugLogging:
          DiveComputerFfi.enableDebugLogging(Level.FINEST);
          break;
        case DiveComputerMethod.supportedComputers:
          final computers = DiveComputerFfi.supportedComputers;
          sendPort.send(computers);
          break;
        case DiveComputerMethod.download:
          final computer = message.$2[0] as Computer;
          final transport = message.$2[1] as ComputerTransport;
          final lastFingerprint = message.$2[2] as String?;
          final bleBridgeAddress = message.$2[3] as int?;
          DiveComputerFfi.divesCallback = (dives) {
            sendPort.send(dives);
          };
          try {
            DiveComputerFfi.download(
                computer, transport, lastFingerprint, bleBridgeAddress);
          } finally {
            if (bleBridgeAddress != null) {
              sendPort.send(_BleBridgeReleased(bleBridgeAddress));
            }
          }
          break;
        default:
          throw UnimplementedError('Message not implemented: $message');
      }
    } catch (e) {
      sendPort.send(initializationError ?? e);
    }
  });
  sendPort.send(receivePort.sendPort);
}
