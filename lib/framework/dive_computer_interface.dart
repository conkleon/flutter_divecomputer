import 'package:dive_computer/types/ble_scan_result.dart';
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
  /// here too). Pass the right one to [download] as `serialPort`.
  Future<List<String>> serialPorts(Computer computer) {
    throw UnimplementedError();
  }

  Future<List<Dive>> download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
    String? serialPort,
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
