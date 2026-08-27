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
/// libdivecomputer's headers contain no GATT UUID table (see the design
/// spec's Background section), so every entry here is derived from external
/// references (Subsurface's `qt-ble.cpp`, vendor protocol write-ups) and
/// should be treated as unverified until confirmed against real hardware.
/// Scanning only surfaces devices matching a `known` profile — see
/// [BleTransport.scanForDevices] — so a device that never appears in a scan
/// most likely just needs its [BleProfile.namePattern] adjusted here.
class BleProfiles {
  BleProfiles._();

  static const List<BleProfile> known = [maresBluelink];

  /// Mares BLE dive computers (`DC_FAMILY_MARES_ICONHD`) — the family that
  /// covers the **Sirius** / **Sirius L** (BLE-only, libdivecomputer models
  /// 0x2F / 0x33), plus Quad / Quad Ci / Quad 2, Genius, Smart Air,
  /// Puck Pro+ / Puck 4, and others.
  ///
  /// GATT layout (a.k.a. the "Mares BlueLink Pro" service — native-BLE
  /// models like the Sirius expose the same service):
  ///   service : 544e326b-5b72-c6b0-1c46-41c1bc448118
  ///   write   : 99a91ebd-b21f-1689-bb43-681f1f55e966  (write-without-response)
  ///   notify  : 1d1aae28-d2a8-91a1-1242-9d2973fbe571  (notify)
  /// Source: Subsurface `core/qt-ble.cpp` (service) + Mares Icon HD BLE
  /// protocol write-ups (characteristics). Subsurface itself picks the
  /// characteristics by GATT property rather than by fixed UUID, so if a
  /// future Mares model differs, discover the real UUIDs with a BLE
  /// inspector (nRF Connect) and add a second entry.
  ///
  /// `namePattern` is a best guess — confirm the Sirius's actual advertised
  /// name during a scan and widen/narrow this if needed. `productHint`
  /// targets the plain Sirius; the Icon HD backend reads the true model
  /// from the device handshake, so a Sirius L should still enumerate.
  static const maresBluelink = BleProfile(
    namePattern: 'Sirius',
    serviceUuid: '544e326b-5b72-c6b0-1c46-41c1bc448118',
    writeCharUuid: '99a91ebd-b21f-1689-bb43-681f1f55e966',
    notifyCharUuid: '1d1aae28-d2a8-91a1-1242-9d2973fbe571',
    writeWithResponse: false,
    vendorHint: 'Mares',
    productHint: 'Sirius',
  );

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
