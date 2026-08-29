import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:developer' as developer;

import 'package:dive_computer/framework/dive_computer_interface.dart';
import 'package:dive_computer/framework/dive_computer_ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_central.dart';
import 'package:dive_computer/framework/ble/ble_transport.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_channel.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_transport.dart';
import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:dive_computer/types/computer.dart';
import 'package:dive_computer/types/dive.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

enum DiveComputerMethod {
  openConnection,
  closeConnection,
  enableDebugLogging,
  supportedComputers,
  serialPorts,
  bluetoothDevices,
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
  Completer<List<String>>? _serialPorts;
  Completer<List<BtDevice>>? _bluetoothDevices;
  Completer<List<Dive>>? _downloadedDives;

  /// Memoized [supportedComputers] request. Concurrent callers (the example
  /// app now has two: `_MyAppState` and `_BleDebugScreenState`) share one
  /// future and one isolate round-trip; without this the second call clobbers
  /// [_supportedComputers], the second reply throws in the port handler, and
  /// the first caller's future never resolves. Cleared in [closeConnection] so
  /// a close/reopen re-enumerates.
  Future<List<Computer>>? _supportedComputersRequest;

  final BleTransport _bleTransport = BleTransport(UniversalBleCentral());
  Completer<void>? _bleBridgeReleased;

  final RfcommChannel _rfcommChannel = MethodChannelRfcommChannel();
  late final RfcommTransport _rfcommTransport = RfcommTransport(_rfcommChannel);

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
        // Guarded like _BleBridgeReleased below: a stray/duplicate reply must
        // not call complete() on an already-completed completer (throws here
        // and wedges the port handler).
        if (_supportedComputers?.isCompleted == false) {
          _supportedComputers?.complete(message);
        }
      } else if (message is List<String>) {
        if (_serialPorts?.isCompleted == false) {
          _serialPorts?.complete(message);
        }
      } else if (message is List<BtDevice>) {
        if (_bluetoothDevices?.isCompleted == false) {
          _bluetoothDevices?.complete(message);
        }
      } else if (message is List<Dive>) {
        if (_downloadedDives?.isCompleted == false) {
          _downloadedDives?.complete(message);
        }
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
        if (_serialPorts?.isCompleted == false) {
          _serialPorts?.completeError(message);
        }
        if (_bluetoothDevices?.isCompleted == false) {
          _bluetoothDevices?.completeError(message);
        }
        if (_downloadedDives?.isCompleted == false) {
          _downloadedDives?.completeError(message);
        }
      } else {
        throw UnimplementedError('Message not implemented: $message');
      }
    });

    // `onError` for the spawned isolate. Without listening here an uncaught
    // error in the background isolate is silently dropped and every
    // outstanding request future hangs forever. Surface it on whichever
    // request is currently in flight.
    _errorPort.listen((dynamic message) {
      final (desc, trace) = message is List && message.length == 2
          ? (message[0].toString(), message[1].toString())
          : (message.toString(), '');
      final error = RemoteError(desc, trace);
      if (_supportedComputers?.isCompleted == false) {
        _supportedComputers?.completeError(error);
      }
      if (_serialPorts?.isCompleted == false) {
        _serialPorts?.completeError(error);
      }
      if (_bluetoothDevices?.isCompleted == false) {
        _bluetoothDevices?.completeError(error);
      }
      if (_downloadedDives?.isCompleted == false) {
        _downloadedDives?.completeError(error);
      }
      if (_bleBridgeReleased?.isCompleted == false) {
        _bleBridgeReleased?.completeError(error);
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
    _supportedComputersRequest = null;
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
  Future<List<Computer>> get supportedComputers =>
      _supportedComputersRequest ??= _requestSupportedComputers();

  Future<List<Computer>> _requestSupportedComputers() async {
    await _send((DiveComputerMethod.supportedComputers, []));
    return (_supportedComputers = Completer<List<Computer>>()).future;
  }

  @override
  Future<List<String>> serialPorts(Computer computer) async {
    await _send((DiveComputerMethod.serialPorts, [computer]));
    return (_serialPorts = Completer<List<String>>()).future;
  }

  @override
  Future<List<BtDevice>> bluetoothDevices(Computer computer) async {
    if (Platform.isAndroid) return _rfcommChannel.bondedDevices();
    if (Platform.isWindows) {
      await _send((DiveComputerMethod.bluetoothDevices, [computer]));
      return (_bluetoothDevices = Completer<List<BtDevice>>()).future;
    }
    return const [];
  }

  @override
  Future<bool> requestBluetoothPermissions() => Platform.isAndroid
      ? _rfcommChannel.requestPermissions()
      : Future.value(true);

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
    String? address,
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
      } else if (transport == ComputerTransport.bluetooth &&
          Platform.isAndroid) {
        if (address == null) {
          throw ArgumentError('Android bluetooth download requires an address');
        }
        await _rfcommTransport.connect(address);
        bridge = BleBridge.allocate();
        _rfcommTransport.attachBridge(bridge);
        _bleBridgeReleased = Completer<void>();
      }
      await _send((
        DiveComputerMethod.download,
        [computer, transport, lastFingerprint, bridge?.address, address],
      ));
    } catch (_) {
      // Tear the transport down BEFORE freeing the bridge: disconnect() writes
      // into the bridge (markClosed) and the 4ms mailbox timer can fire during
      // its await — both would touch freed native memory if dispose() ran
      // first.
      if (transport == ComputerTransport.bluetooth && Platform.isAndroid) {
        await _rfcommTransport.disconnect().catchError((_) {});
      }
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
        // The _BleBridgeReleased handshake guarantees the FFI isolate is done
        // with the bridge. Bounded so a lost handshake can't hang download()
        // forever.
        try {
          await _bleBridgeReleased!.future
              .timeout(const Duration(seconds: 60));
        } on TimeoutException {
          developer.log(
            'Timed out waiting for _BleBridgeReleased handshake; '
            'disposing bridge anyway',
            name: 'DiveComputerIsolate',
            level: 900,
          );
        } catch (_) {
          // Isolate error already surfaced on _downloadedDives via _errorPort.
        }
        // Disconnect the transport BEFORE dispose() — see the catch block.
        if (transport == ComputerTransport.bluetooth && Platform.isAndroid) {
          await _rfcommTransport.disconnect().catchError((_) {});
        }
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
        case DiveComputerMethod.serialPorts:
          final computer = message.$2[0] as Computer;
          sendPort.send(DiveComputerFfi.serialPorts(computer));
          break;
        case DiveComputerMethod.bluetoothDevices:
          sendPort.send(
              DiveComputerFfi.bluetoothDevices(message.$2[0] as Computer));
          break;
        case DiveComputerMethod.download:
          final computer = message.$2[0] as Computer;
          final transport = message.$2[1] as ComputerTransport;
          final lastFingerprint = message.$2[2] as String?;
          final bleBridgeAddress = message.$2[3] as int?;
          final address = message.$2[4] as String?;
          DiveComputerFfi.divesCallback = (dives) {
            sendPort.send(dives);
          };
          try {
            DiveComputerFfi.download(computer, transport, lastFingerprint,
                bleBridgeAddress, address);
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
