import 'ble_profile.dart';

/// A device seen during a BLE scan, with the [BleProfile] it matched
/// against (if any). [BleTransport.scanForDevices] only yields results
/// with a non-null [profile] — see that class for why.
class BleScanResult {
  const BleScanResult({
    required this.id,
    required this.name,
    required this.rssi,
    required this.profile,
  });

  final String id;
  final String name;
  final int rssi;
  final BleProfile? profile;

  @override
  String toString() => 'BleScanResult($name, $id, rssi=$rssi, '
      'profile=${profile?.vendorHint ?? profile?.namePatterns.join("/")})';
}
