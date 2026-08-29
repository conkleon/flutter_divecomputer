/// A Bluetooth Classic device the plugin can connect to: on Windows one that
/// libdivecomputer enumerated as paired; on Android one from the OS bonded
/// list. Sendable across isolates (plain final fields, like [Computer]).
class BtDevice {
  const BtDevice(this.name, this.address);

  /// Advertised / bonded name, e.g. `Petrel`.
  final String name;

  /// `XX:XX:XX:XX:XX:XX`.
  final String address;

  @override
  bool operator ==(Object other) =>
      other is BtDevice && other.name == name && other.address == address;

  @override
  int get hashCode => Object.hash(name, address);

  @override
  String toString() => 'BtDevice($name, $address)';
}
