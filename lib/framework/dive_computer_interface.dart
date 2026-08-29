import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:dive_computer/types/computer.dart';
import 'package:dive_computer/types/dive.dart';

abstract class DiveComputerInterface {
  void openConnection() {
    throw UnimplementedError();
  }

  void closeConnection() {
    throw UnimplementedError();
  }

  void enableDebugLogging() {
    throw UnimplementedError();
  }

  Future<List<Computer>> get supportedComputers => throw UnimplementedError();

  /// The serial ports libdivecomputer associates with [computer] (on Windows,
  /// virtual COM ports for paired Bluetooth-Classic dive computers show up
  /// here too). Pass the right one to [download] as `address`.
  Future<List<String>> serialPorts(Computer computer) {
    throw UnimplementedError();
  }

  /// Bluetooth-Classic devices for [computer]: on Windows the paired devices
  /// libdivecomputer enumerates; on Android the OS bonded list. Pass the
  /// chosen one's `address` to [download] with `ComputerTransport.bluetooth`.
  ///
  /// The Windows path runs on the background isolate and requires
  /// [supportedComputers] to have been awaited first (same caveat as
  /// [serialPorts]).
  Future<List<BtDevice>> bluetoothDevices(Computer computer) {
    throw UnimplementedError();
  }

  /// Requests the runtime Bluetooth permissions the platform needs before
  /// [bluetoothDevices] / [download]. No-op (returns true) where nothing is
  /// required (Windows, Android < 31).
  Future<bool> requestBluetoothPermissions() async => true;

  Future<List<Dive>> download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
    String? address, // COM port for serial; BT MAC for Windows bluetooth
    // Called once per dive as it is parsed, before the returned future
    // completes. Persist each dive here so a mid-transfer disconnect still
    // leaves every parsed dive delivered.
    void Function(Dive dive)? onDive,
  ]) {
    throw UnimplementedError();
  }

  Stream<BleScanResult> scanForBleDevices() {
    throw UnimplementedError();
  }

  Future<void> connectBle(BleScanResult device) {
    throw UnimplementedError();
  }

  Future<void> disconnectBle() {
    throw UnimplementedError();
  }
}
