# Mares & Cressi BLE — example app end-to-end

**Date:** 2026-08-28
**Status:** Design approved, pending spec review
**Builds on:** `docs/superpowers/specs/2026-08-26-ble-transport-design.md` (BLE transport,
Windows-first) and its "Deferred hardening pass" section.

## Goal

Make the example app able to connect to a Mares (BlueLink dongle / Genius) or Cressi
(Goa family) dive computer over BLE, download **every** logged dive, and show them —
a scrollable per-dive summary in the UI plus a full field/sample dump to the console.

Target platforms: Windows and Android.

## Background

The BLE transport (`BleBridge`, the background-isolate FFI callbacks, `BleTransport`,
the isolate wiring, and `DiveComputerFfi._connectBle`) is implemented and works
end-to-end on Windows. `example/lib/main.dart` already has a "BLE debug" tab that
scans, connects, downloads, and prints a dive *count*.

What blocks the goal today:

1. **Profile registry is nearly empty.** `BleProfiles.known` has exactly one entry,
   `maresBluelink`, whose `namePattern` is `"Sirius"`. There is no Cressi profile.
   Scanning only surfaces devices matching a `known` profile
   (`BleTransport.scanForDevices` → `BleProfiles.match`), so a Cressi never appears
   and most Mares devices don't either.

2. **Name matching is single-substring.** `BleProfile.namePattern` is one `String`;
   `matchesName` does a case-insensitive `contains`. Cressi devices advertise as
   `GOA_xxxx`, `CARESIO_xxxx`, or a bare `<model>_<4 hex>` (Subsurface
   `core/btdiscovery.cpp` regex `^([1-9][0-9]?)_[0-9a-f]{4}$`). One substring can't
   cover that. Mares similarly spans `"Mares bluelink pro"`, `"Mares Genius"`,
   `"Genius"`.

3. **BLE download needs a real libdivecomputer descriptor.**
   `DiveComputerFfi.download` looks up `_computerDescriptorCache[computer]!` and passes
   the resulting `dc_descriptor_t*` to `dc_device_open`, which uses it to select the
   vendor backend/parser. The example currently synthesizes
   `Computer(device.profile?.vendorHint ?? 'Unknown', device.profile?.productHint ?? device.name)`.
   If that `Computer` (compared by vendor+product only) doesn't match an enumerated
   descriptor, the `!` throws a null-check error. The plan's Task 12 comment claiming
   "the BLE path doesn't use libdivecomputer's descriptor-driven enumeration" is
   wrong — it does.

4. **Hard 5-dive cap in debug builds.** `DiveComputerFfi._dive_callback` contains
   `if (kDebugMode && _divesCache.length >= 5) return 0;`, which stops the download
   after 5 dives in any non-release build. Directly contradicts "download every dive".

5. **Android has no Bluetooth permissions.** `example/android/app/src/main/AndroidManifest.xml`
   declares none, and nothing requests them at runtime.

### Reference data (external, unverified against hardware)

From Subsurface `core/qt-ble.cpp` `serial_service_uuids[]` and `core/btdiscovery.cpp`
`namePattern[]`:

| Vendor | GATT service UUID | Advertised name patterns |
|---|---|---|
| Mares BlueLink Pro | `544e326b-5b72-c6b0-1c46-41c1bc448118` | `Mares bluelink pro`, `Mares Genius`, `Sirius`, `Quad`, `Mares` |
| Cressi | `6e400001-b5a3-f393-e0a9-e50e24dc10b8` | `GOA_…`, `CARESIO_…`, `^[1-9][0-9]?_[0-9a-f]{4}$` |

Note the Cressi service is **not** the generic Nordic UART service
(`…e50e24dcca9e`) — it is Cressi's own 128-bit UUID ending `…e50e24dc10b8`. The
repo's existing `maresBluelink.serviceUuid` already matches the reference.

Write/notify characteristics are left to `BleTransport`'s property-based discovery
(added in commit `91bc5bc`): the first `write`/`writeWithoutResponse` characteristic
in the service is the write char, the first `notify`/`indicate` is the notify char.
Subsurface decides write-with-response the same way (`WriteNoResponse` property →
without response). No characteristic UUIDs are hard-coded in this design.

### libdivecomputer descriptors available in this build

The vendored `native/lib/.../libdivecomputer` is `0.9.0-devel`. String-table
inspection confirms `mares_iconhd` (including `"Mares bluelink pro"` and
`"Mares Genius"`) and `cressi_goa` (`"Goa"`, `"Cartesio"`, `"Neon"`,
`"Michelangelo"`) backends are present. There is **no** `"Sirius"` product string —
this build predates the Mares Sirius descriptor (libdivecomputer model `0x2F`,
added upstream late 2023). A Sirius owner can still try the download by picking a
`Genius`/Icon-HD descriptor manually (see Descriptor resolution); whether the
`mares_iconhd` backend copes is a hardware-verification question, not something
this design can settle.

## Non-goals

- Bluetooth Classic / RFCOMM (`ComputerTransport.bluetooth`) — stays
  `UnimplementedError`.
- iOS.
- The rest of the deferred-hardening list (`#4` single-flight guard, `#8` ring
  overflow surfacing, `#9` full `BleException` hierarchy, `#12`–`#15`, `#18`–`#19`).
  Only the parts this screen rework naturally subsumes are in scope (`#17`:
  `mounted` guards / not masking errors in `finally`).
- Verifying UUIDs or advertised-name patterns against real Mares/Cressi hardware.
  That is a manual pass the user runs after this lands; the registry comments keep
  saying "unverified".
- macOS (unchanged; should keep building).

## Design

### 1. `BleProfile`: multi-pattern + regex name matching

`lib/types/ble_profile.dart`.

Replace the single `namePattern` field with:

- `namePatterns` — `List<String>`, each matched case-insensitively as a substring
  (same semantics as today, just a list).
- `nameRegExp` — optional `RegExp`, matched against the raw advertised name.

`matchesName(String advertisedName)` returns true if **any** `namePatterns` entry is
a case-insensitive substring, **or** `nameRegExp` matches. Empty `namePatterns` +
null `nameRegExp` → never matches (preserves the "blank pattern matches nothing"
guard the `nordicUart` reference constant relies on).

`BleProfiles.match` is unchanged in shape (first `known` profile whose `matchesName`
is true, else null).

The `nordicUart` reference constant moves to `namePatterns: []` (still deliberately
non-matching, still not in `known`).

Rationale for a `RegExp` field rather than forcing everything into substrings: the
Cressi bare-model form (`2_ab12`) genuinely needs anchored-pattern matching; a
substring like `_` would match half the BLE devices in range.

### 2. Profile registry

`lib/types/ble_profile.dart`, `BleProfiles`.

**`maresBluelink`** (keep the name, widen matching):

```
namePatterns: ['Mares bluelink pro', 'Mares Genius', 'Genius', 'Sirius']
serviceUuid:  '544e326b-5b72-c6b0-1c46-41c1bc448118'   // unchanged
vendorHint:   'Mares'
productHint:  'Genius'                                   // was 'Sirius'
```

`productHint` changes to `'Genius'` because that descriptor exists in this build and
`'Sirius'` does not. Doc comment explains the BlueLink-dongle vs BLE-native split and
that non-Genius models rely on the descriptor picker.

**`cressiGoa`** (new):

```
namePatterns: ['GOA_', 'CARESIO_']
nameRegExp:   RegExp(r'^[1-9][0-9]?_[0-9a-f]{4}$')
serviceUuid:  '6e400001-b5a3-f393-e0a9-e50e24dc10b8'
vendorHint:   'Cressi'
productHint:  'Goa'
```

`BleProfiles.known = [maresBluelink, cressiGoa]`.

Both entries keep/get a comment: UUIDs and name patterns are derived from Subsurface
and vendor write-ups, unverified against hardware, adjust `namePatterns` here first
if a device never shows up in a scan.

### 3. Descriptor resolution (example app)

New small helper, `example/lib/ble_computer_picker.dart` (or inline in `main.dart` if
it stays under ~40 lines):

```
Computer? defaultComputerFor(BleScanResult device, List<Computer> supported)
List<Computer> candidatesFor(BleScanResult device, List<Computer> supported)
```

- `candidatesFor`: every `Computer` in `supported` whose `vendor` equals the
  profile's `vendorHint` (case-insensitive) **and** whose `transports` contains
  `ComputerTransport.ble`. If none have `ble` (older descriptor metadata), fall back
  to all same-vendor computers.
- `defaultComputerFor`: the candidate whose `product` equals `productHint`
  (case-insensitive); else the first candidate; else null.

The BLE screen holds a `Computer? _selectedComputer` per connect flow, initialized
from `defaultComputerFor`, with a `DropdownButton` listing `candidatesFor` so the
user can override before hitting download. If resolution yields null, the screen
shows "No matching libdivecomputer descriptor for <vendor> — is the plugin
connection open?" instead of proceeding.

`download()` is called with the selected `Computer` and `ComputerTransport.ble`.

### 4. Remove the debug dive cap

`lib/framework/dive_computer_ffi.dart`, `_dive_callback`: delete

```
if (kDebugMode && _divesCache.length >= 5) return 0;
```

Keep the fingerprint short-circuit above it. `kDebugMode` stays imported (used
elsewhere). This is a library behavior change: all builds now download the device's
full log. Call it out in `CHANGELOG.md`.

No API change. `download(..., lastFingerprint)` still trims already-seen dives.

### 5. Example BLE screen rework

`example/lib/main.dart`, `_BleDebugScreenState`.

- Add `List<Dive> _dives = []` and `Computer? _selectedComputer` to state.
- Scan list: unchanged behavior (one row per recognized device), but tapping a row
  now (a) resolves candidates/default and (b) shows the connect panel with the
  descriptor dropdown + a "Connect & download" button.
- `_connectAndDownload`:
  - `mounted` guard after every `await` before `setState` / `ScaffoldMessenger`
    (hardening `#17`).
  - `try { connect; download } catch (log) finally { disconnect }`, but the
    `finally`'s `disconnectBle()` is wrapped so it can't mask the original error
    (hardening `#17`).
  - On success: `setState(() => _dives = dives)` and `_dumpAllDives(dives)`.
- Dive list UI: `ListView` of `Card`s, one per dive — date/time, duration
  (`diveTime` s → `m:ss`), max depth, min/max temp, gas mix count, sample count.
  Tapping a card calls `_dumpDive(dive)`.
- `_dumpAllDives` / `_dumpDive`: `print()` (and mirror into the on-screen `_log`)
  every non-null `Dive` field, then every `Sample` (`time`, `depth`, `temperature`,
  pressures, events, deco, ppo2…). This is the "full console dump".
- Keep `dc.enableDebugLogging()` in `initState` so the `finest` byte-level BLE logs
  are available.

No change to the "Serial computers" tab.

### 6. Android

- `example/android/app/src/main/AndroidManifest.xml`: add
  - `BLUETOOTH_SCAN` (with `android:usesPermissionFlags="neverForLocation"` — the app
    doesn't derive location from BLE),
  - `BLUETOOTH_CONNECT`,
  - `ACCESS_FINE_LOCATION` (needed for scans on API < 31),
  - legacy `BLUETOOTH` / `BLUETOOTH_ADMIN` with `android:maxSdkVersion="30"`.
- Runtime request before the first scan. Add `permission_handler` to
  `example/pubspec.yaml` (example-only dep) and request
  `bluetoothScan` + `bluetoothConnect` (+ `locationWhenInUse` on older APIs);
  if denied, the scan button shows a message and does nothing.
- `minSdkVersion`: confirm the example's is ≥ 21 (universal_ble's floor);
  bump in `example/android/app/build.gradle` only if it's lower.
- Windows: no changes (capabilities already work per the Tier 0 gate).

### 7. Tests

- `test/types/ble_profile_test.dart`: rewrite for `namePatterns` + `nameRegExp`
  (multiple substrings match; regex matches the `2_ab12` form; empty+null matches
  nothing; `BleProfiles.match` picks the first `known` hit). Assert `known` now
  contains `maresBluelink` and `cressiGoa` with the expected service UUIDs.
- New `test/types/ble_profiles_registry_test.dart` (or fold into the above): a
  representative Mares name (`"Mares bluelink pro"`, `"Mares Genius"`) resolves to
  `maresBluelink`; `"GOA_1234"`, `"CARESIO_9f"`, `"2_ab12"` resolve to `cressiGoa`;
  an unrelated name (`"Garmin Descent"`) resolves to null.
- Descriptor-resolution helper: pure-function unit test with a hand-built
  `List<Computer>` — default picks the hinted product, dropdown candidates are
  filtered by vendor + `ble`, null when nothing matches.
- No test touches real Bluetooth or the spawned isolate. Everything else in the
  suite stays green (`flutter test`, `flutter analyze`).
- Manual hardware verification is a checklist in the implementation plan, run by the
  user: scan finds the device, connect succeeds, full log downloads, dives render,
  console dump is complete, mid-download walk-away fails cleanly.

## Risks / open questions for the hardware pass

- Advertised-name patterns are guesses. If a device doesn't appear in a scan, widen
  `namePatterns`.
- Descriptor choice for BlueLink-dongle Mares models and non-Goa Cressi models may
  need the dropdown override; the `mares_iconhd`/`cressi_goa` backends may or may not
  self-correct a mismatched model.
- `permission_handler` version pin needs to resolve against the example's Flutter/Dart
  SDK (same constraint dance the `universal_ble` pin went through — SDK 3.8.1 here).
- Whether `cressi_goa` / `mares_iconhd` descriptors in this 0.9.0-devel build actually
  advertise `DC_TRANSPORT_BLE` in their transport bitmask — if not, `candidatesFor`'s
  fallback-to-all-same-vendor branch is what carries the flow.

## Files touched

| File | Change |
|---|---|
| `lib/types/ble_profile.dart` | `namePatterns`/`nameRegExp`; widen `maresBluelink`; add `cressiGoa`; both into `known` |
| `lib/framework/dive_computer_ffi.dart` | delete the `kDebugMode` 5-dive cap |
| `example/lib/main.dart` | BLE screen: dive list, console dump, descriptor dropdown, `mounted` guards |
| `example/lib/ble_computer_picker.dart` | new — descriptor resolution helpers (or inline) |
| `example/pubspec.yaml` | add `permission_handler` (example-only) |
| `example/android/app/src/main/AndroidManifest.xml` | BLE permissions |
| `example/android/app/build.gradle` | `minSdkVersion` bump only if < 21 |
| `test/types/ble_profile_test.dart` | rewrite for new matching + registry |
| `test/types/ble_profiles_registry_test.dart` | new (or folded in) |
| `CHANGELOG.md` | note the removed debug cap + new profiles |
| `docs/superpowers/plans/2026-08-26-ble-transport.md` | tick hardening `#10`/`#17`/`#20` as addressed where true |
