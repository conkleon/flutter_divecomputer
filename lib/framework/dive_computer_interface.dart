import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:dive_computer/types/computer.dart';
import 'package:dive_computer/types/dive.dart';
import 'package:dive_computer/types/sync.dart';

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
  /// here too). Pass the right one as `SyncRequest.endpoint`.
  Future<List<String>> serialPorts(Computer computer) {
    throw UnimplementedError();
  }

  /// Bluetooth-Classic devices for [computer]: on Windows the paired devices
  /// libdivecomputer enumerates; on Android the OS bonded list. Pass the
  /// chosen one's `address` as `SyncRequest.endpoint` with
  /// `ComputerTransport.bluetooth`.
  ///
  /// The Windows path runs on the background isolate and requires
  /// [supportedComputers] to have been awaited first (same caveat as
  /// [serialPorts]).
  Future<List<BtDevice>> bluetoothDevices(Computer computer) {
    throw UnimplementedError();
  }

  /// Requests the runtime Bluetooth permissions the platform needs before
  /// [bluetoothDevices] / [sync]. No-op (returns true) where nothing is
  /// required (Windows, Android < 31).
  Future<bool> requestBluetoothPermissions() async => true;

  /// Runs one transfer described by [request]: connects the transport,
  /// streams every parsed dive on [diveStream] and progress on
  /// [syncProgress], and completes with the run's outcome. Only one sync may
  /// run at a time.
  ///
  /// Failures split two ways: anything before the download starts — a missing
  /// or unresolvable endpoint, a transport that won't connect, a
  /// `StateError` for a concurrent sync — is THROWN, while a failure once the
  /// download is under way completes normally with
  /// `SyncResult(status: SyncStatus.failed, error: ...)`. Callers should both
  /// catch and check [SyncResult.status].
  Future<SyncResult> sync(SyncRequest request) => throw UnimplementedError();

  /// Coarse progress for the running [sync], rate-limited. Broadcast, open
  /// for the life of the instance — subscribe before starting a sync.
  Stream<SyncProgress> get syncProgress => throw UnimplementedError();

  /// Every dive parsed by the running [sync], emitted as it is parsed so a
  /// caller can persist incrementally. Broadcast, open for the life of the
  /// instance.
  Stream<Dive> get diveStream => throw UnimplementedError();

  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  Future<List<Dive>> download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
    String? address, // COM port for serial; BT MAC for Windows bluetooth
    // Called once per dive as it is parsed, before the returned future
    // completes. Persist each dive here so a mid-transfer disconnect still
    // leaves every parsed dive delivered.
    void Function(Dive dive)? onDive,
    // Dive hashes the caller already has. Their parse + delivery is skipped
    // (the device still streams the bytes) — a re-run flies past dives
    // already saved and continues from the rest.
    Iterable<String>? knownFingerprints,
  ]) {
    throw UnimplementedError();
  }

  Stream<BleScanResult> scanForBleDevices() {
    throw UnimplementedError();
  }

  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  Future<void> connectBle(BleScanResult device) {
    throw UnimplementedError();
  }

  @Deprecated('Use sync(SyncRequest). Will be removed in a future major version.')
  Future<void> disconnectBle() {
    throw UnimplementedError();
  }
}
