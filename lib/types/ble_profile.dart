/// Describes how to talk to a family of BLE dive computers: which GATT
/// service to use, and how to recognize one from its advertised name
/// during a scan.
class BleProfile {
  const BleProfile({
    required this.namePatterns,
    required this.serviceUuid,
    this.nameRegExp,
    this.writeCharUuid,
    this.notifyCharUuid,
    this.writeWithResponse,
    this.vendorHint,
    this.productHint,
  });

  /// Each entry is matched case-insensitively as a substring of the
  /// device's advertised name (see [matchesName]). A device matches the
  /// profile if ANY entry matches, or if [nameRegExp] matches.
  final List<String> namePatterns;

  /// Optional anchored/structured match against the raw advertised name,
  /// for vendors whose device names aren't a stable substring (e.g. Cressi
  /// Goa's bare `<model>_<4 hex>` form). Matched in addition to
  /// [namePatterns].
  final RegExp? nameRegExp;

  /// The GATT service to talk to. Required — this is how a scanned device
  /// is matched to its profile after connecting.
  final String serviceUuid;

  /// Explicit write/notify characteristic UUIDs. When `null`, [BleTransport]
  /// discovers them within [serviceUuid] by GATT property. An explicit value
  /// always wins over discovery.
  final String? writeCharUuid;
  final String? notifyCharUuid;

  /// Whether GATT writes use write-with-response. When `null`, inferred from
  /// the resolved write characteristic.
  final bool? writeWithResponse;

  /// Best-guess [Computer] vendor/product this profile corresponds to.
  /// Used by the example app to pick a libdivecomputer descriptor;
  /// informational otherwise.
  final String? vendorHint;
  final String? productHint;

  bool matchesName(String advertisedName) {
    final lower = advertisedName.toLowerCase();
    for (final pattern in namePatterns) {
      if (lower.contains(pattern.toLowerCase())) return true;
    }
    return nameRegExp?.hasMatch(advertisedName) ?? false;
  }
}

/// Registry of BLE GATT profiles this plugin knows how to talk to.
///
/// libdivecomputer's headers contain no GATT UUID table (see the design
/// spec's Background section), so every entry here is derived from external
/// references (Subsurface's `qt-ble.cpp`, vendor protocol write-ups) and
/// should be treated as unverified until confirmed against real hardware.
/// Scanning only surfaces devices matching a `known` profile — see
/// [BleTransport.scanForDevices] — so a device that never appears in a scan
/// most likely just needs its [BleProfile.namePatterns] adjusted here.
class BleProfiles {
  BleProfiles._();

  static const List<BleProfile> known = [maresBluelink];

  /// Mares BLE dive computers (`DC_FAMILY_MARES_ICONHD`) — the family that
  /// covers the **Sirius** / **Sirius L** (BLE-only, libdivecomputer models
  /// 0x2F / 0x33), plus Quad / Quad Ci / Quad 2, Genius, Smart Air,
  /// Puck Pro+ / Puck 4, and others.
  ///
  /// Service UUID is the "Mares BlueLink Pro" service (Subsurface
  /// `core/qt-ble.cpp`); native-BLE models like the Sirius expose the same
  /// one. The write/notify characteristics are left to property-based
  /// discovery (as Subsurface does for Mares) — for reference, a Mares
  /// BlueLink service typically exposes:
  ///   write  : 99a91ebd-b21f-1689-bb43-681f1f55e966  (write-without-response)
  ///   notify : 1d1aae28-d2a8-91a1-1242-9d2973fbe571  (notify)
  ///
  /// `namePatterns` is a best guess — confirm the Sirius's actual advertised
  /// name during a scan and widen/narrow this if needed. `productHint`
  /// targets the plain Sirius; the Icon HD backend reads the true model
  /// from the device handshake, so a Sirius L should still enumerate.
  static const maresBluelink = BleProfile(
    namePatterns: ['Sirius'],
    serviceUuid: '544e326b-5b72-c6b0-1c46-41c1bc448118',
    vendorHint: 'Mares',
    productHint: 'Sirius',
  );

  /// UNVERIFIED reference profile — the Nordic UART Service is a standard,
  /// well-documented BLE serial profile several dive-computer vendors build
  /// on top of. Deliberately NOT included in [known]. Use this as a
  /// starting point once you have something to test against (a real dive
  /// computer, an ESP32 running a NUS sketch, or nRF Connect's peripheral
  /// simulator): copy it with a `namePatterns` entry matching your test
  /// peripheral's actual advertised name, and add it to a local `known`
  /// list (or pass it directly) for that test.
  static const nordicUart = BleProfile(
    namePatterns: [], // fill in with the real advertised name before use
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
