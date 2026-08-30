import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:developer' as developer;

import 'package:dive_computer/framework/bridged_transport.dart';
import 'package:dive_computer/framework/dive_computer_interface.dart';
import 'package:dive_computer/framework/dive_computer_ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_central.dart';
import 'package:dive_computer/framework/ble/ble_transport.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_channel.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_transport.dart';
import 'package:dive_computer/framework/sync/progress_coalescer.dart';
import 'package:dive_computer/framework/sync/sync_run.dart';
import 'package:dive_computer/framework/sync/write_signal.dart';
import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:dive_computer/types/computer.dart';
import 'package:dive_computer/types/dive.dart';
import 'package:dive_computer/types/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

enum DiveComputerMethod {
  openConnection,
  closeConnection,
  enableDebugLogging,
  supportedComputers,
  serialPorts,
  bluetoothDevices,
  sync,
}

typedef IsolateMessage = (DiveComputerMethod method, List<dynamic> args);

/// Sent by the background isolate once it has fully returned from
/// [DiveComputerFfi.sync] (past its own iostream-close finally block) for a
/// bridged transfer — only then is it safe for the main isolate to free the
/// bridge's shared native memory. See the design spec's "no leaks, explicit
/// two-phase teardown".
class _BleBridgeReleased {
  const _BleBridgeReleased(this.address);
  final int address;
}

/// One `DC_EVENT_PROGRESS` hop from the background isolate. A dedicated class
/// (not a raw record/list) so the port listener can route it unambiguously.
class _ProgressMsg {
  const _ProgressMsg(this.current, this.maximum);
  final int current, maximum;
}

/// One `DC_EVENT_DEVINFO` hop from the background isolate.
class _DeviceInfoMsg {
  const _DeviceInfoMsg(this.model, this.firmware, this.serial);
  final int model, firmware, serial;
}

/// Extends (rather than implements) [DiveComputerInterface]. The deprecated
/// `download`/`connectBle`/`disconnectBle` members are overridden below as thin
/// compatibility shims over [sync]; everything else the interface declares is
/// implemented here directly.
class DiveComputer extends DiveComputerInterface {
  late ReceivePort _receivePort, _errorPort;
  late Completer<SendPort> _sendPort;

  static DiveComputer? _instance;
  static DiveComputer get instance => _instance ??= DiveComputer._();

  Completer<List<Computer>>? _supportedComputers;
  Completer<List<String>>? _serialPorts;
  Completer<List<BtDevice>>? _bluetoothDevices;

  /// Memoized [supportedComputers] request. Concurrent callers (the example
  /// app now has two: `_MyAppState` and `_BleDebugScreenState`) share one
  /// future and one isolate round-trip; without this the second call clobbers
  /// [_supportedComputers], the second reply throws in the port handler, and
  /// the first caller's future never resolves. Cleared in [closeConnection] so
  /// a close/reopen re-enumerates.
  Future<List<Computer>>? _supportedComputersRequest;

  /// Progress and dives for the *current* [sync] run. Broadcast and created
  /// once for the life of the singleton: a UI may subscribe before the first
  /// sync and stay subscribed across many, so these are never closed.
  final _progressController = StreamController<SyncProgress>.broadcast();
  final _diveController = StreamController<Dive>.broadcast();

  @override
  Stream<SyncProgress> get syncProgress => _progressController.stream;

  @override
  Stream<Dive> get diveStream => _diveController.stream;

  bool _syncInFlight = false;
  SyncRun? _activeRun;
  ProgressCoalescer? _activeCoalescer;
  BridgedTransport? _activeBridgedTransport;

  final BleTransport _bleTransport = BleTransport(UniversalBleCentral());
  Completer<void>? _bleBridgeReleased;

  final RfcommChannel _rfcommChannel = MethodChannelRfcommChannel();
  late final RfcommTransport _rfcommTransport = RfcommTransport(_rfcommChannel);

  /// Devices seen by the most recent [scanForBleDevices]. `SyncRequest.endpoint`
  /// for BLE is a device id string, but connecting needs the full
  /// [BleScanResult] (it carries the matched `BleProfile`) — this is where the
  /// id is resolved back to one.
  final Map<String, BleScanResult> _lastScan = {};

  /// Device set by the deprecated `connectBle()` shim, used as the fallback
  /// when a BLE [SyncRequest] carries no endpoint.
  BleScanResult? _pendingBleDevice;

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
      } else if (message is _ProgressMsg) {
        _activeRun?.handleProgress(message.current, message.maximum);
      } else if (message is _DeviceInfoMsg) {
        _activeRun?.handleDeviceInfo(
            message.model, message.firmware, message.serial);
      } else if (message is Dive) {
        _activeRun?.handleDive(message);
      } else if (message is SyncResult) {
        _activeRun?.handleResult(message);
      } else if (message is WriteReady) {
        // The bridge write callback is parked waiting for this payload to
        // reach the device — service the mailbox now (the BridgedTransport
        // safety-net timer is only a fallback for a lost signal).
        _activeBridgedTransport?.serviceMailbox();
      } else if (message is _BleBridgeReleased) {
        // Guarded: complete() on an already-completed completer throws inside
        // this listener and would wedge the singleton's port handler.
        if (_bleBridgeReleased?.isCompleted == false) {
          _bleBridgeReleased?.complete();
        }
      } else if (message is Error || message is Exception) {
        _activeRun?.handleError(message);
        if (_supportedComputers?.isCompleted == false) {
          _supportedComputers?.completeError(message);
        }
        if (_serialPorts?.isCompleted == false) {
          _serialPorts?.completeError(message);
        }
        if (_bluetoothDevices?.isCompleted == false) {
          _bluetoothDevices?.completeError(message);
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
      _activeRun?.handleError(error);
      if (_supportedComputers?.isCompleted == false) {
        _supportedComputers?.completeError(error);
      }
      if (_serialPorts?.isCompleted == false) {
        _serialPorts?.completeError(error);
      }
      if (_bluetoothDevices?.isCompleted == false) {
        _bluetoothDevices?.completeError(error);
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
    // The RFCOMM transport + channel and the shared bridged-transport
    // machinery also live on this isolate.
    for (final name in const [
      'RfcommTransport',
      'RfcommChannel',
      'BridgedTransport',
    ]) {
      final l = Logger(name);
      forwardLoggerToDeveloperLog(l);
      l.level = Level.FINEST;
    }
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
  Stream<BleScanResult> scanForBleDevices() =>
      _bleTransport.scanForDevices().map((r) {
        // Remembered so a later SyncRequest.endpoint (a device id) can be
        // resolved back to the full scan result.
        _lastScan[r.id] = r;
        return r;
      });

  @override
  Future<SyncResult> sync(SyncRequest request) async {
    if (_syncInFlight) {
      throw StateError('A sync is already in progress');
    }
    _syncInFlight = true;

    final coalescer = ProgressCoalescer(_progressController.add);
    final run = SyncRun(
      onProgress: (p, {required immediate}) =>
          coalescer.submit(p, immediate: immediate),
      onDive: _diveController.add,
    );
    _activeRun = run;
    _activeCoalescer = coalescer;
    run.start();

    BleBridge? bridge;
    // Connect/allocate/attach/send are grouped so that any failure before the
    // send is confirmed disposes the bridge and rethrows WITHOUT entering the
    // await-released path below: the background isolate never received the
    // bridge, so _BleBridgeReleased would never arrive and sync() would hang
    // forever.
    try {
      if (request.transport == ComputerTransport.ble) {
        await _bleTransport.connect(_resolveBleDevice(request.endpoint));
        bridge = BleBridge.allocate();
        _bleTransport.attachBridge(bridge);
        _activeBridgedTransport = _bleTransport;
        _bleBridgeReleased = Completer<void>();
      } else if (request.transport == ComputerTransport.bluetooth &&
          Platform.isAndroid) {
        if (request.endpoint == null) {
          throw ArgumentError('Android bluetooth sync requires an endpoint');
        }
        await _rfcommTransport.connect(request.endpoint!);
        bridge = BleBridge.allocate();
        _rfcommTransport.attachBridge(bridge);
        _activeBridgedTransport = _rfcommTransport;
        _bleBridgeReleased = Completer<void>();
      }
      await _send((
        DiveComputerMethod.sync,
        [
          request.computer,
          request.transport,
          request.lastFingerprint,
          bridge?.address,
          request.endpoint,
          request.knownFingerprints?.toList(growable: false),
        ],
      ));
    } catch (_) {
      // Tear the transport down BEFORE freeing the bridge: BridgedTransport's
      // inbound subscription and its 250ms safety-net timer can still reach
      // for the bridge during disconnect()'s await, and both would touch freed
      // native memory if dispose() ran first.
      if (request.transport == ComputerTransport.bluetooth &&
          Platform.isAndroid) {
        await _rfcommTransport.disconnect().catchError((_) {});
      } else if (request.transport == ComputerTransport.ble) {
        await _bleTransport.disconnect().catchError((_) {});
      }
      bridge?.dispose();
      _cleanupRun();
      rethrow;
    }

    try {
      return await run.result;
    } finally {
      if (bridge != null) {
        // The _BleBridgeReleased handshake guarantees the FFI isolate is done
        // with the bridge. Bounded so a lost handshake can't hang sync()
        // forever.
        try {
          // Null-safe on purpose: this runs in a finally, and a NoSuchMethod
          // here would mask the run's real result.
          await _bleBridgeReleased?.future.timeout(const Duration(seconds: 60));
        } on TimeoutException {
          developer.log(
            'Timed out waiting for _BleBridgeReleased handshake; '
            'disposing bridge anyway',
            name: 'DiveComputerIsolate',
            level: 900,
          );
        } catch (_) {
          // Isolate error already surfaced on the run via _errorPort.
        }
        // Disconnect the transport BEFORE dispose() — see the catch block.
        if (_activeBridgedTransport == _rfcommTransport) {
          await _rfcommTransport.disconnect().catchError((_) {});
        } else if (_activeBridgedTransport == _bleTransport) {
          await _bleTransport.disconnect().catchError((_) {});
        }
        bridge.dispose();
      }
      _cleanupRun();
    }
  }

  void _cleanupRun() {
    _activeCoalescer?.dispose();
    _activeCoalescer = null;
    _activeRun = null;
    _activeBridgedTransport = null;
    _bleBridgeReleased = null;
    _syncInFlight = false;
  }

  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  @override
  Future<List<Dive>> download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
    String? address,
    void Function(Dive dive)? onDive,
    Iterable<String>? knownFingerprints,
  ]) async {
    final collected = <Dive>[];
    final sub = diveStream.listen((d) {
      collected.add(d);
      onDive?.call(d);
    });
    try {
      final result = await sync(SyncRequest(
        computer: computer,
        transport: transport,
        endpoint: address,
        lastFingerprint: lastFingerprint,
        knownFingerprints: knownFingerprints?.toSet(),
      ));
      if (result.status == SyncStatus.failed && result.error != null) {
        // Match the old contract: every parsed dive was already delivered via
        // onDive before we surface the failure.
        throw result.error!;
      }
      return collected;
    } finally {
      await sub.cancel();
    }
  }

  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  @override
  Future<void> connectBle(BleScanResult device) async {
    _pendingBleDevice = device;
  }

  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  @override
  Future<void> disconnectBle() async {
    _pendingBleDevice = null;
    if (_bleTransport.isConnected && !_syncInFlight) {
      await _bleTransport.disconnect();
    }
  }

  /// Resolves a BLE [SyncRequest.endpoint] (a device id) to the scan result
  /// that carries its matched profile.
  BleScanResult _resolveBleDevice(String? endpoint) {
    if (endpoint != null) {
      final scanned = _lastScan[endpoint];
      if (scanned != null) return scanned;
    }
    final pending = _pendingBleDevice;
    if (pending != null && (endpoint == null || endpoint == pending.id)) {
      return pending;
    }
    throw ArgumentError(
        'BLE sync needs a scanned device. Pass SyncRequest.endpoint as a '
        'BleScanResult id from scanForBleDevices(), or call the (deprecated) '
        'connectBle() first.');
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
        case DiveComputerMethod.sync:
          final computer = message.$2[0] as Computer;
          final transport = message.$2[1] as ComputerTransport;
          final lastFingerprint = message.$2[2] as String?;
          final bleBridgeAddress = message.$2[3] as int?;
          final address = message.$2[4] as String?;
          final knownFingerprints = (message.$2[5] as List?)?.cast<String>();
          DiveComputerFfi.diveCallback = (dive) => sendPort.send(dive);
          DiveComputerFfi.progressCallback =
              (current, maximum) => sendPort.send(_ProgressMsg(current, maximum));
          DiveComputerFfi.deviceInfoCallback = (model, firmware, serial) =>
              sendPort.send(_DeviceInfoMsg(model, firmware, serial));
          DiveComputerFfi.skipFingerprints = knownFingerprints?.toSet() ?? {};
          // Lets the bridge write callback signal the main isolate directly.
          DiveComputerFfi.hostPort = sendPort;
          try {
            final result = DiveComputerFfi.sync(
              computer,
              transport,
              lastFingerprint: lastFingerprint,
              bridgeAddress: bleBridgeAddress,
              address: address,
            );
            sendPort.send(result);
          } finally {
            DiveComputerFfi.diveCallback = null;
            DiveComputerFfi.progressCallback = null;
            DiveComputerFfi.deviceInfoCallback = null;
            DiveComputerFfi.skipFingerprints = {};
            DiveComputerFfi.hostPort = null;
            if (bleBridgeAddress != null) {
              sendPort.send(_BleBridgeReleased(bleBridgeAddress));
            }
          }
          break;
      }
    } catch (e) {
      sendPort.send(initializationError ?? e);
    }
  });
  sendPort.send(receivePort.sendPort);
}
