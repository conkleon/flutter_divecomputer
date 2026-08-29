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

  /// The profiles scanning matches against. Not `const` — [cressiGoa] holds
  /// a [RegExp], which has no const constructor.
  ///
  /// Order matters: [shearwaterPerdix3] must precede [shearwater] because
  /// `'Perdix'` is a substring of `'Perdix 3'` and the two carry different
  /// GATT service UUIDs.
  static final List<BleProfile> known = [
    shearwaterPerdix3,
    shearwater,
    maresBluelink,
    cressiGoa,
  ];

  /// Shearwater BLE dive computers (`DC_FAMILY_SHEARWATER_PREDATOR` /
  /// `DC_FAMILY_SHEARWATER_PETREL`) — Petrel 2, Perdix, Perdix AI, Perdix 2,
  /// NERD 2, Teric, Peregrine, Petrel 3, Tern and relatives.
  ///
  /// The original Predator, Petrel (1) and NERD (1) are Bluetooth Classic
  /// (RFCOMM) only; they are still listed here so a scan recognises them, but
  /// downloading needs `ComputerTransport.bluetooth`, which is not
  /// implemented. Every BLE Shearwater advertises with the model name as a
  /// prefix (Subsurface `core/btdiscovery.cpp`), so a small set of substrings
  /// covers the family.
  ///
  /// Service UUID is the Shearwater serial service (Subsurface
  /// `core/qt-ble.cpp` `serial_service_uuids[]`). Perdix 3 uses a *different*
  /// service — see [shearwaterPerdix3]. Write/notify characteristics are left
  /// to [BleTransport]'s property-based discovery (Subsurface does the same;
  /// there is no Shearwater-specific BLE framing in its read/write path).
  ///
  /// `productHint` is `Petrel 2` — the safest descriptor present in the
  /// vendored libdivecomputer build for an unknown BLE Shearwater. The
  /// example app's descriptor picker lets the user switch to their actual
  /// model (Perdix AI, Teric, Peregrine, …).
  ///
  /// All name patterns + the UUID are reference-derived and UNVERIFIED
  /// against hardware — if a device never shows up in a scan, widen
  /// `namePatterns` here first.
  static const shearwater = BleProfile(
    namePatterns: [
      'Predator',
      'Petrel',
      'Perdix',
      'Teric',
      'Peregrine',
      'NERD',
      'Tern',
    ],
    serviceUuid: 'fe25c237-0ece-443c-b0aa-e02033e7029d',
    vendorHint: 'Shearwater',
    productHint: 'Petrel 2',
  );

  /// Shearwater Perdix 3 — a separate profile because it advertises the same
  /// `Perdix …` name prefix as the rest of the family but exposes a distinct
  /// GATT serial service (Subsurface `core/qt-ble.cpp`). Listed before
  /// [shearwater] in [known] so the more specific `'Perdix 3'` pattern wins.
  ///
  /// The vendored libdivecomputer build (0.9.0-devel) has no Perdix 3
  /// descriptor, so a scan will recognise the device but the download can't
  /// resolve a backend until the native library is updated. `productHint`
  /// falls back to `Perdix 2`.
  ///
  /// UNVERIFIED against hardware.
  static const shearwaterPerdix3 = BleProfile(
    namePatterns: ['Perdix 3'],
    serviceUuid: '1aa44039-1667-4b29-87cc-dfecaaf31d97',
    vendorHint: 'Shearwater',
    productHint: 'Perdix 2',
  );

  /// Mares BLE dive computers (`DC_FAMILY_MARES_ICONHD`).
  ///
  /// Two ways a Mares reaches us over BLE:
  ///   - **BLE-native** (Mares Genius): the computer itself advertises,
  ///     typically as `Mares Genius`.
  ///   - **BlueLink Pro dongle** (Quad, Puck Pro+, Smart Air, Sirius and
  ///     other contact-pin models): the dongle is the BLE peripheral and
  ///     advertises `Mares bluelink pro`.
  ///
  /// Service UUID is the "Mares BlueLink Pro" service (Subsurface
  /// `core/qt-ble.cpp` `serial_service_uuids[]`); the Genius exposes the
  /// same one. Write/notify characteristics are left to property-based
  /// discovery (as Subsurface does for Mares).
  ///
  /// `productHint` is `Genius` because that descriptor exists in the
  /// vendored libdivecomputer build and drives the `mares_iconhd` backend;
  /// there is no `Sirius` descriptor in this build. The example app lets
  /// the user override the descriptor when their model differs.
  ///
  /// All name patterns + the UUID are reference-derived and UNVERIFIED
  /// against hardware — if a device never shows up in a scan, widen
  /// `namePatterns` here first.
  static const maresBluelink = BleProfile(
    namePatterns: ['Mares bluelink pro', 'Mares Genius', 'Genius', 'Sirius'],
    serviceUuid: '544e326b-5b72-c6b0-1c46-41c1bc448118',
    vendorHint: 'Mares',
    productHint: 'Genius',
  );

  /// Cressi BLE dive computers (`DC_FAMILY_CRESSI_GOA`) — Goa, Cartesio,
  /// Neon, Nepto, Michelangelo and relatives.
  ///
  /// Service UUID is Cressi's own 128-bit UUID (Subsurface
  /// `core/qt-ble.cpp`), NOT the generic Nordic UART service it resembles.
  /// Cressi devices advertise as `GOA_xxxx`, `CARESIO_xxxx` (sic — Cressi
  /// spells it that way), or a bare `<model>_<4 hex>` (Subsurface
  /// `core/btdiscovery.cpp`), hence the regex. Write/notify characteristics
  /// are left to property-based discovery.
  ///
  /// UNVERIFIED against hardware.
  static final cressiGoa = BleProfile(
    namePatterns: const ['GOA_', 'CARESIO_'],
    nameRegExp: RegExp(r'^[1-9][0-9]?_[0-9a-f]{4}$', caseSensitive: false),
    serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dc10b8',
    vendorHint: 'Cressi',
    productHint: 'Goa',
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
