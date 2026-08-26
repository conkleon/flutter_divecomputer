/// Describes how to talk to a family of BLE dive computers: which GATT
/// service/characteristics to use, and how to recognize one from its
/// advertised name during a scan.
class BleProfile {
  const BleProfile({
    required this.namePattern,
    required this.serviceUuid,
    required this.writeCharUuid,
    required this.notifyCharUuid,
    required this.writeWithResponse,
    this.vendorHint,
    this.productHint,
  });

  /// Matched case-insensitively as a substring of the device's advertised
  /// name (see [matchesName]).
  final String namePattern;

  final String serviceUuid;
  final String writeCharUuid;
  final String notifyCharUuid;
  final bool writeWithResponse;

  /// Best-guess [Computer] vendor/product this profile corresponds to.
  /// Informational only — not used to select a libdivecomputer descriptor.
  final String? vendorHint;
  final String? productHint;

  bool matchesName(String advertisedName) =>
      advertisedName.toLowerCase().contains(namePattern.toLowerCase());
}

/// Registry of BLE GATT profiles this plugin knows how to talk to.
///
/// `known` intentionally starts empty: libdivecomputer's headers contain no
/// GATT UUID table (see the design spec's Background section), so every
/// entry here has to be verified against a real device before it's added.
/// Scanning only surfaces devices matching a `known` profile — see
/// BleTransport.scanForDevices() — so an empty registry means "nothing
/// recognized yet", not a bug.
class BleProfiles {
  BleProfiles._();

  static const List<BleProfile> known = [];

  /// UNVERIFIED reference profile — the Nordic UART Service is a standard,
  /// well-documented BLE serial profile several dive-computer vendors build
  /// on top of. Deliberately NOT included in [known]. Use this as a
  /// starting point once you have something to test against (a real dive
  /// computer, an ESP32 running a NUS sketch, or nRF Connect's peripheral
  /// simulator): copy it with a `namePattern` matching your test
  /// peripheral's actual advertised name, and add it to a local `known`
  /// list (or pass it directly) for that test.
  static const nordicUart = BleProfile(
    namePattern: '', // fill in with the real advertised name before use
    serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    writeCharUuid: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
    notifyCharUuid: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
    writeWithResponse: false,
  );

  static BleProfile? match(String advertisedName) {
    for (final profile in known) {
      if (profile.matchesName(advertisedName)) return profile;
    }
    return null;
  }
}
