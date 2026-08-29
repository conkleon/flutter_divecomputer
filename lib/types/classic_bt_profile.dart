/// How to recognise a Bluetooth-Classic dive computer from its bonded /
/// paired name, and which libdivecomputer descriptor to default to.
///
/// Deliberately separate from `BleProfile` (`lib/types/ble_profile.dart`):
/// a Classic profile needs no GATT service/characteristic UUIDs, and the
/// Shearwater membership differs (only the older, Classic-radio models).
class ClassicBtProfile {
  const ClassicBtProfile({
    required this.namePatterns,
    this.vendorHint,
    this.productHint,
  });

  /// Each matched case-insensitively as a substring of the device name.
  final List<String> namePatterns;

  /// Best-guess `Computer` vendor/product for the descriptor picker.
  final String? vendorHint;
  final String? productHint;

  bool matchesName(String name) {
    final lower = name.toLowerCase();
    for (final p in namePatterns) {
      if (lower.contains(p.toLowerCase())) return true;
    }
    return false;
  }
}

/// Registry of Bluetooth-Classic dive computers this plugin recognises.
class ClassicBtProfiles {
  ClassicBtProfiles._();

  /// The Classic-radio Shearwaters: Predator, Petrel, Petrel 2, NERD, Perdix.
  /// Teric / Peregrine / Petrel 3 / Perdix 2 / Tern are BLE-only and are NOT
  /// here — picking a Classic descriptor for them would be wrong. `Petrel 3`
  /// is excluded structurally by [match] (it is matched by `BleProfiles`
  /// first in real use; here `match` just needs `namePatterns` not to be a
  /// prefix trap — `Petrel 3` DOES contain `Petrel`, so callers that care
  /// must check `BleProfiles` first, which the example app does).
  static const shearwater = ClassicBtProfile(
    namePatterns: ['Predator', 'Petrel', 'Perdix', 'NERD', 'Nerd'],
    vendorHint: 'Shearwater',
    productHint: 'Petrel',
  );

  static const List<ClassicBtProfile> known = [shearwater];

  static ClassicBtProfile? match(String name) {
    for (final p in known) {
      if (p.matchesName(name)) return p;
    }
    return null;
  }
}
