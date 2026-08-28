# Mares & Cressi BLE — Example App End-to-End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the example app connect to a Mares (BlueLink dongle / Genius) or Cressi (Goa family) dive computer over BLE, download every logged dive, and show them — a per-dive summary list in the UI plus a full field/sample dump to the console.

**Architecture:** `BleProfile` gains multi-substring + optional regex name matching so one profile entry can recognise the several names a vendor advertises. The registry (`BleProfiles.known`) grows a widened Mares BlueLink entry and a new Cressi Goa entry. The example app resolves a scanned device to a real libdivecomputer `Computer` descriptor (needed by `dc_device_open` to pick the vendor backend), defaulting from the profile's hints with a dropdown override. The library's debug-build 5-dive download cap is removed. Android gets the BLE manifest permissions it currently lacks (`universal_ble` requests them at runtime itself).

**Tech Stack:** Flutter/Dart, `package:test` (plugin unit tests), `flutter_test` (example unit tests), `package:universal_ble` (already a dependency), `dart:ffi` (existing, not modified structurally).

**Spec:** `docs/superpowers/specs/2026-08-28-mares-cressi-ble-example-design.md`

## Global Constraints

- No custom native C/C++/Kotlin code. Dart + existing FFI bindings only.
- BLE plumbing goes through `universal_ble` via the existing `BleCentral` seam — do not call platform BLE APIs directly.
- Never hard-code write/notify characteristic UUIDs — `BleTransport` discovers them by GATT property. Profiles carry the **service** UUID only.
- All BLE GATT service UUIDs and advertised-name patterns are **reference-derived (Subsurface `core/qt-ble.cpp`, `core/btdiscovery.cpp`) and unverified against hardware.** Every registry entry keeps a comment saying so.
- Mares BlueLink Pro service UUID: `544e326b-5b72-c6b0-1c46-41c1bc448118` (already in the repo, unchanged).
- Cressi service UUID: `6e400001-b5a3-f393-e0a9-e50e24dc10b8` (Cressi's own 128-bit UUID — **not** the generic Nordic UART service `6e400001-b5a3-f393-e0a9-e50e24dcca9e`).
- Dependency version constraints are bounded on both ends (`>=x <y`), matching the existing `pubspec.yaml` style. No unbounded constraints.
- New verbose logging stays behind the existing `DiveComputer.enableDebugLogging()` switch and the `logging` package convention.
- The vendored libdivecomputer is `0.9.0-devel`: it has `mares_iconhd` (incl. `"Mares bluelink pro"`, `"Mares Genius"`) and `cressi_goa` (`"Goa"`, `"Cartesio"`, `"Neon"`, `"Michelangelo"`) backends. It has **no** `"Sirius"` product descriptor.
- Platforms in scope: Windows and Android. macOS must keep building. iOS and Bluetooth Classic are untouched.

---

### Task 1: `BleProfile` multi-pattern + regex name matching

Pure type change. Behaviour of the one registered profile stays identical (`['Sirius']`); the registry contents change in Task 2.

**Files:**
- Modify: `lib/types/ble_profile.dart`
- Modify: `lib/types/ble_scan_result.dart` (one line in `toString`)
- Modify: `test/types/ble_profile_test.dart`
- Modify: `test/types/ble_scan_result_test.dart` (constructor call — keep suite compiling)
- Modify: `test/framework/ble/ble_transport_test.dart` (constructor calls — keep suite compiling)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `BleProfile({required List<String> namePatterns, required String serviceUuid, RegExp? nameRegExp, String? writeCharUuid, String? notifyCharUuid, bool? writeWithResponse, String? vendorHint, String? productHint})`
  - `bool BleProfile.matchesName(String advertisedName)` — true if any `namePatterns` entry is a case-insensitive substring of `advertisedName`, or `nameRegExp` (if non-null) matches `advertisedName`. `namePatterns` empty + `nameRegExp` null → always false.
  - `BleProfiles.match(String) -> BleProfile?` — unchanged signature.

- [ ] **Step 1: Update the `matchesName` tests in `test/types/ble_profile_test.dart`**

Replace the `BleProfile.matchesName` group and the `BleProfiles` group's inline constructor with the new API:

```dart
import 'package:dive_computer/types/ble_profile.dart';
import 'package:test/test.dart';

void main() {
  group('BleProfile.matchesName', () {
    test('matches any of several patterns, case-insensitively, as substrings',
        () {
      const profile = BleProfile(
        namePatterns: ['Mares bluelink pro', 'Genius'],
        serviceUuid: 's',
      );
      expect(profile.matchesName('Mares bluelink pro'), isTrue);
      expect(profile.matchesName('MARES BLUELINK PRO'), isTrue);
      expect(profile.matchesName('Mares Genius'), isTrue);
      expect(profile.matchesName('Suunto EON'), isFalse);
    });

    test('matches via nameRegExp when provided', () {
      final profile = BleProfile(
        namePatterns: const ['GOA_'],
        nameRegExp: RegExp(r'^[1-9][0-9]?_[0-9a-f]{4}$'),
        serviceUuid: 's',
      );
      expect(profile.matchesName('GOA_1234'), isTrue); // substring
      expect(profile.matchesName('2_ab12'), isTrue); // regex
      expect(profile.matchesName('20_ffff'), isTrue); // regex
      expect(profile.matchesName('0_ab12'), isFalse); // regex: leading 0
      expect(profile.matchesName('2_abardvark'), isFalse);
    });

    test('empty patterns and null regex never match', () {
      const profile = BleProfile(namePatterns: [], serviceUuid: 's');
      expect(profile.matchesName(''), isFalse);
      expect(profile.matchesName('anything'), isFalse);
    });
  });

  group('BleProfiles.match', () {
    test('returns null when nothing in known matches', () {
      expect(BleProfiles.match('Suunto EON Steel'), isNull);
    });

    test('returns the first matching profile in known', () {
      const a = BleProfile(namePatterns: ['foo'], serviceUuid: 's1');
      expect(a.matchesName('foobar'), isTrue);
    });
  });
}
```

(The Mares-registry assertion currently in this file moves to Task 2's test.)

- [ ] **Step 2: Run to verify it fails**

```
flutter test test/types/ble_profile_test.dart
```
Expected: FAIL — `namePatterns` / `nameRegExp` are not parameters of `BleProfile` yet.

- [ ] **Step 3: Rewrite `BleProfile` in `lib/types/ble_profile.dart`**

Replace the class (keep the file's other content for now — `maresBluelink`, `nordicUart`, `BleProfiles.known`, `BleProfiles.match` — updating only what must change to compile):

```dart
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
```

Then update the two constants in the same file so it compiles:

```dart
  static const maresBluelink = BleProfile(
    namePatterns: ['Sirius'],
    serviceUuid: '544e326b-5b72-c6b0-1c46-41c1bc448118',
    vendorHint: 'Mares',
    productHint: 'Sirius',
  );
```
```dart
  static const nordicUart = BleProfile(
    namePatterns: [], // fill in with the real advertised name before use
    serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    writeCharUuid: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
    notifyCharUuid: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
    writeWithResponse: false,
  );
```

(Leave the doc comments referencing `namePattern` for now if they still read sensibly, or s/`namePattern`/`namePatterns`/ — cosmetic. `maresBluelink`'s real widening is Task 2.)

- [ ] **Step 4: Fix the `profile?.namePattern` reference in `lib/types/ble_scan_result.dart`**

Line ~21, in `toString`:

```dart
  @override
  String toString() => 'BleScanResult($name, $id, rssi=$rssi, '
      'profile=${profile?.vendorHint ?? profile?.namePatterns.join("/")})';
```

- [ ] **Step 5: Fix the remaining constructor call sites so the suite compiles**

`test/types/ble_scan_result_test.dart` (~line 7):
```dart
    const profile = BleProfile(
      namePatterns: ['Test'],
      serviceUuid: 's',
    );
```

`test/framework/ble/ble_transport_test.dart` — every `BleProfile(namePattern: 'Test', ...)` becomes `BleProfile(namePatterns: ['Test'], ...)`. There are constructor calls near lines 15, 25, and 143; grep to be sure:
```
grep -n "namePattern" test/framework/ble/ble_transport_test.dart
```
Keep whatever `serviceUuid` / char / `writeWithResponse` values each already passes — only the name field changes.

- [ ] **Step 6: Run the full suite + analyzer**

```
flutter test
flutter analyze
```
Expected: all green. `flutter analyze` shows no **new** issues (the pre-existing 4 baseline issues from `progress.md` may remain).

- [ ] **Step 7: Commit**

```bash
git add lib/types/ble_profile.dart lib/types/ble_scan_result.dart test/types/ble_profile_test.dart test/types/ble_scan_result_test.dart test/framework/ble/ble_transport_test.dart
git commit -m "BleProfile: match multiple name patterns plus an optional regex"
```

---

### Task 2: Widen the Mares profile and add a Cressi Goa profile

**Files:**
- Modify: `lib/types/ble_profile.dart`
- Modify: `test/types/ble_profile_test.dart` (add a registry group)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `BleProfile` (Task 1).
- Produces:
  - `BleProfiles.maresBluelink` — `namePatterns: ['Mares bluelink pro', 'Mares Genius', 'Genius', 'Sirius']`, `serviceUuid: '544e326b-5b72-c6b0-1c46-41c1bc448118'`, `vendorHint: 'Mares'`, `productHint: 'Genius'`.
  - `BleProfiles.cressiGoa` — `namePatterns: ['GOA_', 'CARESIO_']`, `nameRegExp: RegExp(r'^[1-9][0-9]?_[0-9a-f]{4}$')`, `serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dc10b8'`, `vendorHint: 'Cressi'`, `productHint: 'Goa'`.
  - `BleProfiles.known == [maresBluelink, cressiGoa]`.

- [ ] **Step 1: Write the registry tests**

Add to `test/types/ble_profile_test.dart`:

```dart
  group('BleProfiles.known registry', () {
    test('known contains exactly the Mares and Cressi profiles', () {
      expect(BleProfiles.known,
          orderedEquals([BleProfiles.maresBluelink, BleProfiles.cressiGoa]));
    });

    test('Mares BlueLink profile matches its advertised names', () {
      for (final name in const [
        'Mares bluelink pro',
        'Mares Genius',
        'Genius',
        'Mares Sirius',
      ]) {
        expect(BleProfiles.match(name), same(BleProfiles.maresBluelink),
            reason: name);
      }
      expect(BleProfiles.maresBluelink.serviceUuid,
          '544e326b-5b72-c6b0-1c46-41c1bc448118');
      expect(BleProfiles.maresBluelink.vendorHint, 'Mares');
      expect(BleProfiles.maresBluelink.productHint, 'Genius');
      // Characteristics + write mode left to property-based discovery.
      expect(BleProfiles.maresBluelink.writeCharUuid, isNull);
      expect(BleProfiles.maresBluelink.notifyCharUuid, isNull);
      expect(BleProfiles.maresBluelink.writeWithResponse, isNull);
    });

    test('Cressi Goa profile matches GOA_/CARESIO_/bare-model names', () {
      for (final name in const ['GOA_1A2B', 'CARESIO_09', '2_ab12', '13_00ff']) {
        expect(BleProfiles.match(name), same(BleProfiles.cressiGoa),
            reason: name);
      }
      expect(BleProfiles.cressiGoa.serviceUuid,
          '6e400001-b5a3-f393-e0a9-e50e24dc10b8');
      expect(BleProfiles.cressiGoa.vendorHint, 'Cressi');
      expect(BleProfiles.cressiGoa.productHint, 'Goa');
      expect(BleProfiles.cressiGoa.writeCharUuid, isNull);
      expect(BleProfiles.cressiGoa.notifyCharUuid, isNull);
    });

    test('an unrelated device name matches nothing', () {
      expect(BleProfiles.match('Garmin Descent Mk2'), isNull);
      expect(BleProfiles.match('Perdix AI'), isNull);
    });
  });
```

- [ ] **Step 2: Run to verify it fails**

```
flutter test test/types/ble_profile_test.dart
```
Expected: FAIL — `cressiGoa` doesn't exist; `maresBluelink` still `['Sirius']` / `productHint: 'Sirius'`.

- [ ] **Step 3: Update `BleProfiles` in `lib/types/ble_profile.dart`**

```dart
class BleProfiles {
  BleProfiles._();

  static const List<BleProfile> known = [maresBluelink, cressiGoa];

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
    nameRegExp: RegExp(r'^[1-9][0-9]?_[0-9a-f]{4}$'),
    serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dc10b8',
    vendorHint: 'Cressi',
    productHint: 'Goa',
  );

  /// UNVERIFIED reference profile — the Nordic UART Service. Deliberately
  /// NOT in [known]. Copy it, set a real `namePatterns` entry, and add it to
  /// a local list to test against an ESP32 / nRF Connect peripheral.
  static const nordicUart = BleProfile(
    namePatterns: [],
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
```

Note: `cressiGoa` is `static final` (not `const`) because `RegExp` is not a const constructor. `known` stays `const`-friendly? No — a list containing a non-const `final` cannot be `const`. Change `known` to:
```dart
  static final List<BleProfile> known = [maresBluelink, cressiGoa];
```
and update the doc comment on `known` accordingly. Confirm `BleTransport` / `BleScanResult` only read `known` (they do — `BleProfiles.match` iterates it), so `final` vs `const` is transparent to callers.

- [ ] **Step 4: Run to verify it passes**

```
flutter test test/types/ble_profile_test.dart
```
Expected: PASS.

- [ ] **Step 5: Update `CHANGELOG.md`**

Under `## Unreleased`, add:
```markdown
* BLE: recognise Mares (BlueLink Pro dongle / Genius) and Cressi (Goa
  family) dive computers during a scan. GATT service UUIDs and advertised
  name patterns are derived from Subsurface and not yet hardware-verified.
```

- [ ] **Step 6: Run the full suite + analyzer, then commit**

```
flutter test
flutter analyze
```
```bash
git add lib/types/ble_profile.dart test/types/ble_profile_test.dart CHANGELOG.md
git commit -m "Add Cressi Goa BLE profile and widen the Mares BlueLink profile"
```

---

### Task 3: Remove the debug-build 5-dive download cap

**Files:**
- Modify: `lib/framework/dive_computer_ffi.dart` (`_dive_callback`, ~line 342)
- Create: `test/framework/dive_computer_ffi_cap_test.dart`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing.
- Produces: no API change. `download()` returns the device's full dive log in every build mode (still trimmed by `lastFingerprint` when supplied).

Why a source-assertion test: this line lives in a synchronous `dart:ffi` callback that only runs with real `libdivecomputer` + a real device attached, so it has no reachable unit-test seam. A source guard is the honest regression lock.

- [ ] **Step 1: Write the guard test**

```dart
// test/framework/dive_computer_ffi_cap_test.dart
import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('the debug-build dive cap is not present in _dive_callback', () {
    final source =
        File('lib/framework/dive_computer_ffi.dart').readAsStringSync();
    expect(
      source.contains('_divesCache.length >= 5'),
      isFalse,
      reason: 'The kDebugMode 5-dive download cap must stay removed — '
          'the plugin downloads the full dive log. See '
          'docs/superpowers/specs/2026-08-28-mares-cressi-ble-example-design.md',
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```
flutter test test/framework/dive_computer_ffi_cap_test.dart
```
Expected: FAIL — the string is still there.

- [ ] **Step 3: Delete the cap line**

In `lib/framework/dive_computer_ffi.dart`, `_dive_callback`, remove exactly this line:
```dart
    if (kDebugMode && _divesCache.length >= 5) return 0;
```
Leave the line above it (`if (currentFingerprint == lastFingerprint) return 0;`) and the trailing `return 1;` intact. Do not remove the `import 'package:flutter/foundation.dart';` — `kDebugMode` / `kProfileMode` are still used elsewhere in the file (and `debugPrint`/`kDebugMode` in the isolate). Confirm with:
```
grep -n "kDebugMode\|foundation.dart" lib/framework/dive_computer_ffi.dart
```
If `kDebugMode` now has zero remaining uses in this file, also remove the now-unused import to keep `flutter analyze` clean; otherwise leave it.

- [ ] **Step 4: Run to verify it passes**

```
flutter test test/framework/dive_computer_ffi_cap_test.dart
flutter analyze
```
Expected: test PASS; analyzer no new issues (watch for "unused import" if you left `foundation.dart` in without a remaining reference).

- [ ] **Step 5: Update `CHANGELOG.md`**

Under `## Unreleased`:
```markdown
* `download()` now returns the dive computer's complete log in all build
  modes. Debug builds previously stopped after 5 dives.
```

- [ ] **Step 6: Full suite + commit**

```
flutter test
```
```bash
git add lib/framework/dive_computer_ffi.dart test/framework/dive_computer_ffi_cap_test.dart CHANGELOG.md
git commit -m "Remove the debug-build 5-dive download cap"
```

---

### Task 4: Descriptor-resolution helpers (example app)

Pure functions the BLE screen uses to turn a `BleScanResult` into a libdivecomputer `Computer` descriptor.

**Files:**
- Create: `example/lib/ble_download_support.dart`
- Create: `example/test/ble_download_support_test.dart`

**Interfaces:**
- Consumes: `Computer`, `ComputerTransport`, `BleScanResult`, `BleProfile` (from `package:dive_computer`); `Dive`, `Sample` (for the formatter).
- Produces:
  - `List<Computer> candidateComputersFor(BleScanResult device, List<Computer> supported)` — same-vendor (`vendorHint`, case-insensitive) computers that support `ComputerTransport.ble`; if none of the same-vendor computers advertise `ble`, returns all same-vendor computers; empty list if the profile has no `vendorHint` or nothing matches.
  - `Computer? defaultComputerFor(BleScanResult device, List<Computer> supported)` — the candidate whose `product` equals the profile's `productHint` (case-insensitive); else the first candidate; else `null`.
  - `String formatDiveSummary(Dive dive)` — one-line summary: date/time, duration `m:ss`, max depth, min/max temp, gas count, sample count. Null fields render as `—`.
  - `List<String> describeDiveVerbose(Dive dive)` — one string per line for the full console dump: every non-null `Dive` field, then one line per `Sample` with its non-null values.

- [ ] **Step 1: Write the tests**

```dart
// example/test/ble_download_support_test.dart
import 'package:dive_computer/dive_computer.dart';
import 'package:dive_computer_example/ble_download_support.dart';
import 'package:flutter_test/flutter_test.dart';

BleScanResult _scan(BleProfile profile) =>
    BleScanResult(id: 'x', name: 'n', rssi: -50, profile: profile);

void main() {
  const maresBle = Computer('Mares', 'Genius',
      transports: [ComputerTransport.ble]);
  const maresQuadBle = Computer('Mares', 'Quad',
      transports: [ComputerTransport.ble, ComputerTransport.serial]);
  const maresSerialOnly = Computer('Mares', 'Puck',
      transports: [ComputerTransport.serial]);
  const cressiSerialOnly = Computer('Cressi', 'Leonardo',
      transports: [ComputerTransport.serial]);
  final supported = [maresBle, maresQuadBle, maresSerialOnly, cressiSerialOnly];

  group('candidateComputersFor', () {
    test('same-vendor BLE-capable computers', () {
      final c = candidateComputersFor(_scan(BleProfiles.maresBluelink), supported);
      expect(c, containsAll([maresBle, maresQuadBle]));
      expect(c, isNot(contains(maresSerialOnly)));
      expect(c, isNot(contains(cressiSerialOnly)));
    });

    test('falls back to all same-vendor when none advertise BLE', () {
      final c = candidateComputersFor(
          _scan(BleProfiles.cressiGoa), [cressiSerialOnly, maresBle]);
      expect(c, [cressiSerialOnly]);
    });

    test('empty when the profile has no vendorHint', () {
      const noHint = BleProfile(namePatterns: ['x'], serviceUuid: 's');
      expect(candidateComputersFor(_scan(noHint), supported), isEmpty);
    });
  });

  group('defaultComputerFor', () {
    test('prefers the productHint match', () {
      expect(defaultComputerFor(_scan(BleProfiles.maresBluelink), supported),
          maresBle); // productHint 'Genius'
    });

    test('first candidate when productHint does not match', () {
      const profile = BleProfile(
          namePatterns: ['x'], serviceUuid: 's',
          vendorHint: 'Mares', productHint: 'Nonesuch');
      expect(defaultComputerFor(_scan(profile), supported), maresBle);
    });

    test('null when nothing matches the vendor', () {
      const profile = BleProfile(
          namePatterns: ['x'], serviceUuid: 's', vendorHint: 'Suunto');
      expect(defaultComputerFor(_scan(profile), supported), isNull);
    });
  });

  group('formatDiveSummary', () {
    test('renders fields and dashes for nulls', () {
      final dive = Dive('AABB',
          diveTime: 125, maxDepth: 18.4, avgDepth: null, atmospheric: null,
          temperatureSurface: null, temperatureMinimum: 12.0,
          temperatureMaximum: 21.0, diveMode: null,
          dateTime: DateTime(2026, 5, 1, 9, 30),
          salinity: null, gasmixes: null, tanks: null, samples: const []);
      final s = formatDiveSummary(dive);
      expect(s, contains('2026-05-01'));
      expect(s, contains('2:05')); // 125 s
      expect(s, contains('18.4'));
    });
  });

  group('describeDiveVerbose', () {
    test('one line per sample plus the dive header lines', () {
      final dive = Dive('AABB',
          diveTime: 60, maxDepth: 5.0, avgDepth: 3.0, atmospheric: 1.01,
          temperatureSurface: 20.0, temperatureMinimum: 18.0,
          temperatureMaximum: 20.0, diveMode: 0,
          dateTime: DateTime(2026, 1, 1),
          salinity: null, gasmixes: null, tanks: null,
          samples: [Sample(0)..depth = 0.0, Sample(10)..depth = 5.0]);
      final lines = describeDiveVerbose(dive);
      expect(lines.first, contains('AABB'));
      expect(lines.where((l) => l.contains('sample')).length, 2);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```
cd example
flutter test test/ble_download_support_test.dart
```
Expected: FAIL — `ble_download_support.dart` doesn't exist.

- [ ] **Step 3: Implement `example/lib/ble_download_support.dart`**

```dart
import 'package:dive_computer/dive_computer.dart';

/// libdivecomputer descriptors of the same vendor as [device]'s matched
/// profile that can be driven over BLE. Falls back to every same-vendor
/// descriptor if none carry [ComputerTransport.ble] in their transport
/// bitmask (older descriptor metadata). Empty if the profile has no
/// `vendorHint` or nothing matches.
List<Computer> candidateComputersFor(
    BleScanResult device, List<Computer> supported) {
  final vendor = device.profile?.vendorHint?.toLowerCase();
  if (vendor == null) return const [];
  final sameVendor = supported
      .where((c) => c.vendor.toLowerCase() == vendor)
      .toList(growable: false);
  final ble = sameVendor
      .where((c) => c.transports.contains(ComputerTransport.ble))
      .toList(growable: false);
  return ble.isNotEmpty ? ble : sameVendor;
}

/// The descriptor to preselect for [device]: the [candidateComputersFor]
/// entry whose product matches the profile's `productHint`, else the first
/// candidate, else null.
Computer? defaultComputerFor(BleScanResult device, List<Computer> supported) {
  final candidates = candidateComputersFor(device, supported);
  if (candidates.isEmpty) return null;
  final hint = device.profile?.productHint?.toLowerCase();
  for (final c in candidates) {
    if (c.product.toLowerCase() == hint) return c;
  }
  return candidates.first;
}

String _num(num? v, {int frac = 1, String unit = ''}) =>
    v == null ? '—' : '${v.toStringAsFixed(frac)}$unit';

String _dur(int? seconds) {
  if (seconds == null) return '—';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _date(DateTime? dt) => dt == null
    ? '—'
    : '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';

String formatDiveSummary(Dive dive) =>
    '${_date(dive.dateTime)}  •  ${_dur(dive.diveTime)}  •  '
    'max ${_num(dive.maxDepth, unit: ' m')}  •  '
    'temp ${_num(dive.temperatureMinimum)}–${_num(dive.temperatureMaximum, unit: ' °C')}  •  '
    'gas ${dive.gasmixes?.length ?? 0}  •  ${dive.samples.length} samples';

List<String> describeDiveVerbose(Dive dive) {
  final lines = <String>[
    'Dive ${dive.hash}',
    '  date        ${_date(dive.dateTime)}',
    '  duration    ${_dur(dive.diveTime)}',
    '  maxDepth    ${_num(dive.maxDepth, unit: ' m')}',
    '  avgDepth    ${_num(dive.avgDepth, unit: ' m')}',
    '  atmospheric ${_num(dive.atmospheric, frac: 3, unit: ' bar')}',
    '  tempSurface ${_num(dive.temperatureSurface, unit: ' °C')}',
    '  tempMin     ${_num(dive.temperatureMinimum, unit: ' °C')}',
    '  tempMax     ${_num(dive.temperatureMaximum, unit: ' °C')}',
    '  diveMode    ${dive.diveMode ?? '—'}',
    '  salinity    ${dive.salinity?.density ?? '—'}',
    '  gasmixes    ${dive.gasmixes?.length ?? 0}',
    '  tanks       ${dive.tanks?.length ?? 0}',
    '  samples     ${dive.samples.length}',
  ];
  for (final s in dive.samples) {
    final parts = <String>['t=${s.time}s'];
    if (s.depth != null) parts.add('depth=${s.depth!.toStringAsFixed(2)}m');
    if (s.temperature != null) {
      parts.add('temp=${s.temperature!.toStringAsFixed(1)}°C');
    }
    if (s.rbt != null) parts.add('rbt=${s.rbt}');
    if (s.heartbeat != null) parts.add('hr=${s.heartbeat}');
    if (s.bearing != null) parts.add('bearing=${s.bearing}');
    if (s.gasmix != null) parts.add('gasmix=${s.gasmix}');
    if (s.setpoint != null) parts.add('setpoint=${s.setpoint}');
    if (s.cns != null) parts.add('cns=${s.cns}');
    if (s.ppo2 != null) parts.add('ppo2=${s.ppo2!.value}');
    if (s.deco != null) {
      parts.add('deco(type=${s.deco!.type},depth=${s.deco!.depth},tts=${s.deco!.tts})');
    }
    for (final p in s.pressure ?? const []) {
      parts.add('pressure(tank=${p.tank},bar=${p.pressure})');
    }
    for (final e in s.events ?? const []) {
      parts.add('event(type=${e.type},flags=${e.flags},value=${e.value})');
    }
    lines.add('  sample ${parts.join(' ')}');
  }
  return lines;
}
```

- [ ] **Step 4: Run to verify it passes**

```
cd example
flutter test test/ble_download_support_test.dart
```
Expected: PASS. If the `Dive` / `Sample` constructor signatures in the test don't match `package:dive_computer/types/dive.dart`, fix the **test** to match the real constructors (check `lib/types/dive.dart`) — do not change the types.

- [ ] **Step 5: Commit**

```bash
cd ..
git add example/lib/ble_download_support.dart example/test/ble_download_support_test.dart
git commit -m "Add example helpers: BLE descriptor resolution and dive formatting"
```

---

### Task 5: Rework the example BLE screen

**Files:**
- Modify: `example/lib/main.dart` (`_BleDebugScreenState` and its widget tree)

**Interfaces:**
- Consumes: `DiveComputer.instance` (`scanForBleDevices`, `connectBle`, `disconnectBle`, `download`, `supportedComputers`); `candidateComputersFor`, `defaultComputerFor`, `formatDiveSummary`, `describeDiveVerbose` (Task 4); `BleScanResult`, `Computer`, `ComputerTransport`, `Dive`.
- Produces: no exported API (example app only).

- [ ] **Step 1: Rewrite `_BleDebugScreenState`**

Replace the class body (keep the `BleDebugScreen` widget class and the file's other contents — `MyApp`, the serial tab — unchanged). Target behaviour:

- State: `final List<String> _log`, `final Map<String, BleScanResult> _found`, `StreamSubscription<BleScanResult>? _scanSub`, `List<Computer> _supported = const []`, `BleScanResult? _selectedDevice`, `Computer? _selectedComputer`, `List<Dive> _dives = const []`, `bool _busy = false`.
- `initState`: `super.initState()`, then `DiveComputer.instance.supportedComputers.then((c) { if (mounted) setState(() => _supported = c); })`.
- `_print(String)`: unchanged (insert at 0, `setState`, `print`).
- `_startScan()`: cancel prior sub, clear `_found`, `_print('Scan started')`, listen to `dc.scanForBleDevices()`, on each result `setState(() => _found[result.id] = result)` + `_print('Found: $result')`, `onError` → `_print('SCAN ERROR: $e')`.
- `_selectDevice(BleScanResult d)`: `setState` to set `_selectedDevice = d`, `_selectedComputer = defaultComputerFor(d, _supported)`, `_dives = const []`.
- `_connectAndDownload()` (uses `_selectedDevice!` / `_selectedComputer`):

```dart
  Future<void> _connectAndDownload() async {
    final device = _selectedDevice;
    final computer = _selectedComputer;
    if (device == null) return;
    if (computer == null) {
      _print('No libdivecomputer descriptor for '
          '${device.profile?.vendorHint ?? "this device"} — is the plugin '
          'connection open?');
      return;
    }
    setState(() => _busy = true);
    try {
      _print('Connecting to ${device.name}...');
      await dc.connectBle(device);
      if (!mounted) return;
      _print('Connected. Downloading full dive log as $computer ...');
      final dives = await dc.download(computer, ComputerTransport.ble);
      if (!mounted) return;
      setState(() => _dives = dives);
      _print('Downloaded ${dives.length} dives — full dump follows');
      for (final dive in dives) {
        for (final line in describeDiveVerbose(dive)) {
          _print(line);
        }
      }
    } catch (e) {
      _print('ERROR: $e');
    } finally {
      try {
        await dc.disconnectBle();
        _print('Disconnected.');
      } catch (e) {
        _print('Disconnect error (ignored): $e');
      }
      if (mounted) setState(() => _busy = false);
    }
  }
```

- `dispose()`: `_scanSub?.cancel()`, `super.dispose()`.

- [ ] **Step 2: Build the widget tree**

`build` returns a `Column`:
1. A `Wrap`/`Row` of buttons: `ElevatedButton('Scan for Mares / Cressi', onPressed: _busy ? null : _startScan)`.
2. If `_selectedDevice != null`: a small panel showing the device name, a `DropdownButton<Computer>` whose items are `candidateComputersFor(_selectedDevice!, _supported)` (value `_selectedComputer`, `onChanged` → `setState(() => _selectedComputer = v)`), and `ElevatedButton('Connect & download', onPressed: _busy ? null : _connectAndDownload)`. If the candidate list is empty, show `Text('No BLE-capable $vendor descriptor found in libdivecomputer')` instead of the dropdown.
3. `Expanded` with a `ListView`:
   - Section header `Text('Found devices')`, then for each `_found.values` a `ListTile` (title device name, subtitle `${id}  rssi=${rssi}  ·  ${profile?.vendorHint}`, `onTap: () => _selectDevice(device)`, selected highlight when `identical(device, _selectedDevice)`).
   - `Divider()`, header `Text('Dives (${_dives.length})')`, then for each dive a `Card`/`ListTile` with `title: Text(formatDiveSummary(dive))`, `onTap: () { for (final l in describeDiveVerbose(dive)) _print(l); }`.
   - `Divider()`, header `Text('Log')`, then `for (final line in _log) Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))`.

Keep it plain — this is a debug screen, not a design task.

- [ ] **Step 3: Analyze**

```
cd example
flutter analyze
```
Expected: no errors. Common catches: missing `mounted` guard (add it), unused import, `DropdownButton` needs unique `value` present in `items` (guard with `value: _selectedComputer` only when it's in the candidate list, else `null`).

- [ ] **Step 4: Analyzer at root too**

```
cd ..
flutter analyze
```
Expected: no new issues.

- [ ] **Step 5: Commit**

```bash
git add example/lib/main.dart
git commit -m "Example: descriptor picker, full dive list + verbose console dump over BLE"
```

---

### Task 6: Android BLE permissions in the example

`universal_ble` requests the runtime permissions itself during `startScan` (confirmed from its README) — so this task is manifest-only plus an optional friendly pre-flight. No `permission_handler` dependency.

**Files:**
- Modify: `example/android/app/src/main/AndroidManifest.xml`
- Modify: `example/lib/main.dart` (optional pre-flight call — see Step 2)
- Check (modify only if needed): `example/android/app/build.gradle` (`minSdkVersion`)

**Interfaces:**
- Consumes: `UniversalBle.requestPermissions` (from `package:universal_ble`, already a dependency).
- Produces: nothing exported.

- [ ] **Step 1: Add the permissions to the manifest**

In `example/android/app/src/main/AndroidManifest.xml`, add these as children of `<manifest>` (siblings of `<application>`, before it):

```xml
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.BLUETOOTH"
        android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
        android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
        android:maxSdkVersion="30" />
```

- [ ] **Step 2: Optional pre-flight in `_startScan`**

At the top of `_startScan()` in `example/lib/main.dart`, before subscribing:

```dart
    try {
      await UniversalBle.requestPermissions();
    } catch (e) {
      _print('Permission request failed: $e');
      return;
    }
```

Add `import 'package:universal_ble/universal_ble.dart';` if not already present, and make `_startScan` `async`. (If `requestPermissions` isn't in the resolved `universal_ble` version's API, skip this step — `startScan` requests them anyway; note the skip in the commit message.)

- [ ] **Step 3: Check `minSdkVersion`**

```
grep -n "minSdkVersion" example/android/app/build.gradle
```
`universal_ble` needs ≥ 21. If it reads `flutter.minSdkVersion` (which is ≥ 21 on current Flutter) or an explicit ≥ 21, leave it. Only if it's an explicit value below 21, set it to 21.

- [ ] **Step 4: Resolve and analyze**

```
cd example
flutter pub get
flutter analyze
```
Expected: no errors.

- [ ] **Step 5: Verify the manifest merges (if an Android toolchain is available)**

```
cd example
flutter build apk --debug
```
Expected: builds. If no Android SDK is configured in this environment, skip and note it — Task 7's manual checklist covers the real-device run.

- [ ] **Step 6: Commit**

```bash
cd ..
git add example/android/app/src/main/AndroidManifest.xml example/lib/main.dart
git commit -m "Example: declare Android BLE permissions"
```

---

### Task 7: Whole-feature verification and doc updates

Not a code task — a verification checklist and the doc bookkeeping that spans all prior tasks.

**Files:**
- Modify: `docs/superpowers/plans/2026-08-26-ble-transport.md` (deferred-hardening section)
- Modify: `CHANGELOG.md` (only if prior tasks left it inconsistent)

- [ ] **Step 1: Full automated suite**

```
flutter test
flutter analyze
cd example && flutter test && flutter analyze && cd ..
```
Expected: all green; no new analyzer issues vs. the 4-issue baseline in `progress.md`.

- [ ] **Step 2: Windows build smoke (if a Visual Studio C++ toolchain is available)**

```
cd example
flutter build windows --debug
```
Expected: builds. If no toolchain, note it for the user to run.

- [ ] **Step 3: Update the deferred-hardening list**

In `docs/superpowers/plans/2026-08-26-ble-transport.md`, under "Deferred hardening pass":
- `#17` (`example/lib/main.dart` `mounted` guards / `finally` masking the error): mark **DONE** in commit for Task 5.
- `#20` (`BleProfiles.known` empty → example scan shows nothing): mark **DONE** — `known` now has Mares + Cressi entries.
- `#10` (profile-mismatch still retries 3×): leave as-is; note that a matched-but-wrong-model device is now handled by the example's descriptor dropdown, but the `BleTransport` retry-3×/log-wording part is still open.

- [ ] **Step 4: Commit the doc updates**

```bash
git add docs/superpowers/plans/2026-08-26-ble-transport.md CHANGELOG.md
git commit -m "Record Mares/Cressi BLE example work against the hardening list"
```

- [ ] **Step 5: Manual hardware verification (user-run — cannot be automated)**

Run `cd example && flutter run -d windows` (or `-d android`), open the "BLE debug" tab, then for each available device:

1. **Scan** — tap "Scan for Mares / Cressi". Confirm the Mares (BlueLink dongle powered on / Genius awake) and/or Cressi (in sync/PC mode) appears within ~15 s. If not: note its exact advertised name (visible in nRF Connect / the OS Bluetooth panel) and widen `BleProfiles` `namePatterns`.
2. **Descriptor** — tap the device. Confirm the dropdown lists same-vendor computers and preselects a sensible one (Genius / Goa). Adjust if you know your model.
3. **Connect & download** — tap it. With `enableDebugLogging()` on, confirm `finest` read/write hex lines flow both directions, then `Downloaded N dives`.
4. **All dives** — confirm N equals the number of dives actually stored on the device (this is the point of the feature — not capped at 5), the on-screen list shows one card per dive with a plausible date / duration / depth, and the console dump lists every sample.
5. **Clean failure** — during a download, power off / walk away from the device. Confirm the app logs a disconnect and `download()` throws/returns within the timeout rather than hanging, and no `severe` bridge-callback exceptions appear.
6. Report: which devices, whether each step passed, exact advertised names seen, any `namePatterns` / descriptor adjustments made.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| 1 — `BleProfile` multi-pattern + regex | Task 1 |
| 2 — Registry (widen Mares, add Cressi) | Task 2 |
| 3 — Descriptor resolution (example) | Task 4 (helpers) + Task 5 (UI) |
| 4 — Remove debug dive cap | Task 3 |
| 5 — Example BLE screen rework | Task 5 (+ formatter in Task 4) |
| 6 — Android permissions | Task 6 |
| 7 — Tests | Tasks 1–4 (unit) + Task 7 (manual checklist) |
| Non-goals (no Classic/iOS, no hardware verification here, no broader hardening) | Respected; only `#17`/`#20` touched, per spec |

Spec's `permission_handler` line is intentionally superseded — Task 6's note explains `universal_ble` handles runtime requests itself (confirmed from its README). The spec file is updated to match.

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". Every code step has real code. The two "if the API/toolchain isn't available, skip and note it" steps (Task 6 Step 2, Task 6 Step 5, Task 7 Step 2) are genuine environment conditionals, not vague placeholders.

**Type consistency:** `candidateComputersFor` / `defaultComputerFor` / `formatDiveSummary` / `describeDiveVerbose` signatures match between Task 4's Produces block, its implementation, and Task 5's consumption. `BleProfile` constructor (`namePatterns` required, `nameRegExp` optional, chars/`writeWithResponse` optional) is consistent across Tasks 1, 2, 4. `known` is `static final` (not `const`) from Task 2 onward because `cressiGoa` holds a `RegExp` — called out in Task 2 Step 3.
