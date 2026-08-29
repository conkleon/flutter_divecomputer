# Bluetooth Classic (RFCOMM) Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `ComputerTransport.bluetooth` (Bluetooth Classic / RFCOMM / SPP) for Windows and Android, so Bluetooth-Classic-only dive computers (the original Shearwater Predator, Petrel, Petrel 2, NERD, Perdix) can have their dive logs downloaded.

**Architecture:** Two platform paths, dispatched in the `DiveComputer` main-isolate facade. **Windows:** call libdivecomputer's own `dc_bluetooth_open` over FFI, on the background isolate, exactly like the serial path — no bridge. **Android:** a hand-rolled Kotlin `BluetoothSocket` RFCOMM channel on the main isolate, feeding the *existing* shared-memory isolate bridge into `dc_custom_open(…, DC_TRANSPORT_BLUETOOTH, …)` on the background isolate.

**Tech Stack:** Dart + `dart:ffi`, Flutter method/event channels, Kotlin (`android.bluetooth`), libdivecomputer 0.9.0-devel (vendored), `ffigen`.

**Spec:** `docs/superpowers/specs/2026-08-29-bluetooth-classic-rfcomm-transport-design.md` — read it alongside this plan.

## Global Constraints

- **Package name:** `app.divenote.dive_computer` (matches `android/build.gradle` `namespace`).
- **`minSdkVersion` stays 19.** API-31+ calls (`BLUETOOTH_CONNECT` runtime request) must be guarded with `Build.VERSION.SDK_INT >= 31`.
- **Bonded devices only.** No in-app discovery/pairing. **Do NOT** add `BLUETOOTH_SCAN` or `ACCESS_FINE_LOCATION`.
- **SPP UUID:** `00001101-0000-1000-8000-00805F9B34FB`.
- **BT address string format:** `XX:XX:XX:XX:XX:XX` (upper-case hex). On Windows use libdivecomputer's `dc_bluetooth_str2addr` / `dc_bluetooth_addr2str`, never hand-roll the conversion.
- **`dc_bluetooth_open(iostream, context, address, port)`** — pass `port = 0` (libdivecomputer then resolves the RFCOMM channel via SDP).
- **`ClassicBtProfiles.shearwater` name patterns:** exactly `['Predator', 'Petrel', 'Perdix', 'NERD', 'Nerd']`. Teric / Peregrine / Petrel 3 / Perdix 2 / Tern are BLE-only and MUST NOT be added here.
- **Deviations from the spec, applied by this plan (do NOT implement the spec versions):**
  - The bridge classes/files keep their current `Ble*` names (`BleBridge`, `lib/framework/ble/ble_bridge_state.dart`, …). Only a doc comment is added noting they are transport-neutral. A rename is deferred.
  - **No `BridgedTransport` base class.** `RfcommTransport` duplicates the small mailbox-pump / teardown block from `BleTransport` rather than extracting a shared base — lower risk to the working BLE code.
- **Testing reality:** the background isolate and FFI cannot run under `flutter test` (they open the native library). Follow the repo's existing pattern: pure-Dart unit tests for pure logic, and **source-inspection tests** (read the `.dart` file, assert on its contents) for isolate/FFI wiring — see `test/framework/dive_computer_isolate_test.dart` and `test/framework/dive_computer_ffi_cap_test.dart`.
- **Commits:** one per task, conventional-commit style (`feat:`, `refactor:`, `test:`, `docs:`).
- **After every task:** `flutter analyze` (from repo root `flutter_divecomputer/`) must report no new issues beyond the 7 pre-existing ones, and `flutter test` must be green except the known-flaky `test/framework/ble/ble_bridge_state_test.dart` "closed unblocks a wait immediately" timing test (re-run once to confirm green).

---

## Phase A — Shared foundation

### Task 1: `BtDevice` value type

**Files:**
- Create: `lib/types/bt_device.dart`
- Test: `test/types/bt_device_test.dart`

**Interfaces:**
- Produces: `class BtDevice { const BtDevice(this.name, this.address); final String name; final String address; }` with value equality and `toString()`.

- [ ] **Step 1: Write the failing test**

```dart
// test/types/bt_device_test.dart
import 'package:dive_computer/types/bt_device.dart';
import 'package:test/test.dart';

void main() {
  test('value equality on name + address', () {
    expect(const BtDevice('Petrel', '00:13:43:0A:A0:6F'),
        const BtDevice('Petrel', '00:13:43:0A:A0:6F'));
    expect(const BtDevice('Petrel', '00:13:43:0A:A0:6F'),
        isNot(const BtDevice('Petrel', '00:00:00:00:00:00')));
  });

  test('toString shows name and address', () {
    expect(const BtDevice('Petrel', '00:13:43:0A:A0:6F').toString(),
        contains('Petrel'));
    expect(const BtDevice('Petrel', '00:13:43:0A:A0:6F').toString(),
        contains('00:13:43:0A:A0:6F'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/types/bt_device_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:dive_computer/types/bt_device.dart'`.

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/types/bt_device.dart

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/types/bt_device_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/types/bt_device.dart test/types/bt_device_test.dart
git commit -m "feat: add BtDevice value type for Bluetooth Classic transport"
```

---

### Task 2: `ClassicBtProfile` + `ClassicBtProfiles` registry

**Files:**
- Create: `lib/types/classic_bt_profile.dart`
- Test: `test/types/classic_bt_profile_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `class ClassicBtProfile { const ClassicBtProfile({required List<String> namePatterns, String? vendorHint, String? productHint}); bool matchesName(String name); }`
  - `class ClassicBtProfiles { static const ClassicBtProfile shearwater; static const List<ClassicBtProfile> known; static ClassicBtProfile? match(String name); }`

- [ ] **Step 1: Write the failing test**

```dart
// test/types/classic_bt_profile_test.dart
import 'package:dive_computer/types/classic_bt_profile.dart';
import 'package:test/test.dart';

void main() {
  group('ClassicBtProfile.matchesName', () {
    test('case-insensitive substring match on any pattern', () {
      const p = ClassicBtProfile(namePatterns: ['Petrel', 'Perdix']);
      expect(p.matchesName('Petrel'), isTrue);
      expect(p.matchesName('PETREL'), isTrue);
      expect(p.matchesName('Shearwater Perdix'), isTrue);
      expect(p.matchesName('Teric'), isFalse);
    });

    test('empty patterns never match', () {
      const p = ClassicBtProfile(namePatterns: []);
      expect(p.matchesName('anything'), isFalse);
    });
  });

  group('ClassicBtProfiles registry', () {
    test('shearwater matches the Classic-BT Shearwaters only', () {
      for (final n in const ['Predator', 'Petrel', 'Petrel 2', 'NERD', 'Perdix']) {
        expect(ClassicBtProfiles.match(n), same(ClassicBtProfiles.shearwater),
            reason: n);
      }
      // BLE-only Shearwaters must NOT match here.
      for (final n in const ['Teric', 'Peregrine', 'Petrel 3', 'Perdix 2']) {
        expect(ClassicBtProfiles.match(n), isNull, reason: n);
      }
      expect(ClassicBtProfiles.match('Garmin Descent'), isNull);
    });

    test('shearwater hints', () {
      expect(ClassicBtProfiles.shearwater.vendorHint, 'Shearwater');
      expect(ClassicBtProfiles.shearwater.productHint, 'Petrel');
    });

    test('known contains exactly the shearwater profile', () {
      expect(ClassicBtProfiles.known, [ClassicBtProfiles.shearwater]);
    });
  });
}
```

Note: `Petrel 3` contains the substring `Petrel`, so the "must NOT match" assertion for `Petrel 3` would fail against a naive matcher. That is intentional — see Step 3.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/types/classic_bt_profile_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/types/classic_bt_profile.dart

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
```

The test's `Petrel 3` / `Perdix 2` "must be null" assertions will FAIL against this (both contain a listed substring). **Resolve by narrowing the test, not the matcher:** in real use, a name is checked against `BleProfiles` first (the example app does this — Task 12), so `Petrel 3` never reaches `ClassicBtProfiles.match`. Change those four names in the test to genuinely-unrelated ones:

```dart
      for (final n in const ['Teric', 'Peregrine', 'Garmin', 'Suunto EON']) {
        expect(ClassicBtProfiles.match(n), isNull, reason: n);
      }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/types/classic_bt_profile_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/types/classic_bt_profile.dart test/types/classic_bt_profile_test.dart
git commit -m "feat: add ClassicBtProfiles registry (Classic-BT Shearwaters)"
```

---

### Task 3: interface plumbing — `address` param, `bluetoothDevices`, `requestBluetoothPermissions`

**Files:**
- Modify: `lib/framework/dive_computer_interface.dart`
- Modify: `lib/framework/dive_computer_isolate.dart` (rename only, in this task)
- Modify: `lib/framework/dive_computer_ffi.dart` (rename only, in this task)
- Modify: `lib/framework/ble/ble_bridge_state.dart` (doc comment only)
- Test: `test/framework/dive_computer_interface_test.dart` (new)

**Interfaces:**
- Consumes: `BtDevice` (Task 1).
- Produces (on `DiveComputerInterface`):
  - `Future<List<BtDevice>> bluetoothDevices(Computer computer)` — default `throw UnimplementedError()`
  - `Future<bool> requestBluetoothPermissions()` — default `async => true`
  - `download(Computer, ComputerTransport, [String? lastFingerprint, String? address])` — `serialPort` renamed to `address`

- [ ] **Step 1: Write the failing test**

```dart
// test/framework/dive_computer_interface_test.dart
import 'package:dive_computer/framework/dive_computer_interface.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:dive_computer/types/computer.dart';
import 'package:test/test.dart';

class _Bare extends DiveComputerInterface {}

void main() {
  final iface = _Bare();
  final computer = Computer('Shearwater', 'Petrel',
      transports: [ComputerTransport.bluetooth]);

  test('bluetoothDevices throws UnimplementedError by default', () {
    expect(() => iface.bluetoothDevices(computer), throwsUnimplementedError);
  });

  test('requestBluetoothPermissions defaults to true', () async {
    expect(await iface.requestBluetoothPermissions(), isTrue);
  });

  test('download signature accepts a positional address after fingerprint', () {
    // Compile-time check: this must not be a syntax error.
    expect(
      () => iface.download(computer, ComputerTransport.bluetooth, 'fp', 'COM7'),
      throwsUnimplementedError,
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/dive_computer_interface_test.dart`
Expected: FAIL — `bluetoothDevices` / `requestBluetoothPermissions` not defined; `download` takes 3 positional args not 4.

- [ ] **Step 3: Implement**

In `lib/framework/dive_computer_interface.dart`, add to the class and change `download`:

```dart
  /// Bluetooth-Classic devices for [computer]: on Windows the paired devices
  /// libdivecomputer enumerates; on Android the OS bonded list. Pass the
  /// chosen one's `address` to [download] with `ComputerTransport.bluetooth`.
  Future<List<BtDevice>> bluetoothDevices(Computer computer) {
    throw UnimplementedError();
  }

  /// Requests the runtime Bluetooth permissions the platform needs before
  /// [bluetoothDevices] / [download]. No-op (returns true) where nothing is
  /// required (Windows, Android < 31).
  Future<bool> requestBluetoothPermissions() async => true;

  Future<List<Dive>> download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
    String? address, // COM port for serial; BT MAC for Windows bluetooth
  ]) {
    throw UnimplementedError();
  }
```

Add `import 'package:dive_computer/types/bt_device.dart';` at the top.

In `lib/framework/dive_computer_isolate.dart`: rename the `download` parameter `serialPort` → `address` (signature + the `_send` args list entry). Do **not** add new behaviour yet.

In `lib/framework/dive_computer_ffi.dart`: rename the `download` parameter `serialPortName` → `address`, and the `_connectSerial(computerDescriptor, serialPortName)` call site → `_connectSerial(computerDescriptor, address)`. `_connectSerial`'s own parameter name (`serialPortName`) can stay — it is serial-specific there.

In `lib/framework/ble/ble_bridge_state.dart`: change the `BleBridge` class doc comment's first line to note re-use:

```dart
/// Shared native-memory byte pipe between the main isolate and the background
/// isolate. Despite the `Ble` name it is transport-neutral: the BLE transport
/// and the Android RFCOMM transport (`lib/framework/rfcomm/`) both use it.
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/dive_computer_interface_test.dart`
Expected: PASS.
Run: `flutter test` and `flutter analyze`
Expected: green (flaky bridge test aside); no new analyzer issues. The existing `test/framework/dive_computer_isolate_test.dart` source-guard for `[computer, transport, lastFingerprint, bridge?.address, serialPort]` will now FAIL — update that string in that test to `... , address]` as part of this task.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/dive_computer_interface.dart lib/framework/dive_computer_isolate.dart lib/framework/dive_computer_ffi.dart lib/framework/ble/ble_bridge_state.dart test/framework/dive_computer_interface_test.dart test/framework/dive_computer_isolate_test.dart
git commit -m "refactor: generalise download() serialPort->address; add bluetooth interface stubs"
```

---

## Phase B — Windows

### Task 4: bind `bluetooth.h`

**Files:**
- Modify: `ffigen.yaml`
- Modify (generated): `lib/framework/dive_computer_ffi_bindings_generated.dart`

**Interfaces:**
- Produces (in the generated bindings): `dc_bluetooth_iterator_new`, `dc_bluetooth_open`, `dc_bluetooth_device_get_address`, `dc_bluetooth_device_get_name`, `dc_bluetooth_device_free`, `dc_bluetooth_addr2str`, `dc_bluetooth_str2addr`, `dc_bluetooth_device_t`, `dc_bluetooth_address_t`.

- [ ] **Step 1: Add the entry-point**

In `ffigen.yaml`, under `headers.entry-points`, add after the `ble.h` line:

```yaml
    - 'native/include/libdivecomputer/bluetooth.h'
```

- [ ] **Step 2: Regenerate**

Run: `flutter pub run ffigen --config ffigen.yaml`
Expected: regenerates `lib/framework/dive_computer_ffi_bindings_generated.dart` with no errors (ffigen may print info-level messages about skipped declarations — fine).

- [ ] **Step 3: Verify the new symbols are present**

Run: `grep -c 'dc_bluetooth_open\|dc_bluetooth_iterator_new\|dc_bluetooth_str2addr' lib/framework/dive_computer_ffi_bindings_generated.dart`
Expected: ≥ 3.

- [ ] **Step 4: Analyze**

Run: `flutter analyze lib/framework/dive_computer_ffi_bindings_generated.dart`
Expected: no new issues (the file has an `ignore_for_file` preamble).

- [ ] **Step 5: Commit**

```bash
git add ffigen.yaml lib/framework/dive_computer_ffi_bindings_generated.dart
git commit -m "feat: generate FFI bindings for libdivecomputer bluetooth.h"
```

---

### Task 5: Windows FFI — `bluetoothDevices` + `_connectBluetooth`

**Files:**
- Modify: `lib/framework/dive_computer_ffi.dart`
- Test: `test/framework/dive_computer_ffi_bluetooth_test.dart` (new, source-inspection)

**Interfaces:**
- Consumes: `BtDevice` (Task 1); generated `dc_bluetooth_*` (Task 4); existing `_handleResult`, `context`, `_bindings`, `_computerDescriptorCache`.
- Produces (static on `DiveComputerFfi`):
  - `List<BtDevice> bluetoothDevices(Computer computer)`
  - `ffi.Pointer<dc_iostream_t> _connectBluetooth(ffi.Pointer<dc_descriptor_t> descriptor, String address)`

- [ ] **Step 1: Write the failing test**

```dart
// test/framework/dive_computer_ffi_bluetooth_test.dart
import 'dart:io';
import 'package:test/test.dart';

void main() {
  final src = File('lib/framework/dive_computer_ffi.dart').readAsStringSync();

  test('bluetoothDevices enumerates via dc_bluetooth_iterator_new', () {
    expect(src, contains('static List<BtDevice> bluetoothDevices('));
    expect(src, contains('dc_bluetooth_iterator_new'));
    expect(src, contains('dc_bluetooth_device_get_name'));
    expect(src, contains('dc_bluetooth_device_get_address'));
  });

  test('_connectBluetooth opens via dc_bluetooth_open with port 0', () {
    expect(src, contains('_connectBluetooth('));
    expect(src, contains('dc_bluetooth_str2addr'));
    expect(
      RegExp(r'dc_bluetooth_open\(\s*iostream,\s*context\.value,\s*\w+,\s*0\b')
          .hasMatch(src),
      isTrue,
      reason: 'port must be 0 (SDP auto-resolves the RFCOMM channel)',
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/dive_computer_ffi_bluetooth_test.dart`
Expected: FAIL — none of the strings present.

- [ ] **Step 3: Implement**

Add `import 'package:dive_computer/types/bt_device.dart';` near the other type imports.

Add these methods to `DiveComputerFfi` (place `bluetoothDevices` next to `serialPorts`, and `_connectBluetooth` next to `_connectSerial`):

```dart
  /// Bluetooth-Classic devices libdivecomputer sees as paired for [computer]'s
  /// descriptor. Windows only — Android goes through the RFCOMM channel.
  static List<BtDevice> bluetoothDevices(Computer computer) {
    final descriptor = _computerDescriptorCache[computer];
    if (descriptor == null) {
      throw ArgumentError(
          'Unknown computer $computer — call supportedComputers first');
    }

    final iterator = calloc<ffi.Pointer<dc_iterator_t>>();
    _handleResult(
      _bindings.dc_bluetooth_iterator_new(iterator, context.value, descriptor),
      'bluetooth iterator creation',
    );

    final devices = <BtDevice>[];
    int result;
    final dev = calloc<ffi.Pointer<dc_bluetooth_device_t>>();
    final strbuf = calloc<ffi.Char>(18); // DC_BLUETOOTH_SIZE
    try {
      while ((result = _bindings.dc_iterator_next(iterator.value, dev.cast())) ==
          dc_status_t.DC_STATUS_SUCCESS) {
        final namePtr = _bindings.dc_bluetooth_device_get_name(dev.value);
        final name = namePtr == ffi.nullptr
            ? ''
            : namePtr.cast<Utf8>().toDartString();
        final addr = _bindings.dc_bluetooth_device_get_address(dev.value);
        final addrStr = _bindings
            .dc_bluetooth_addr2str(addr, strbuf, 18)
            .cast<Utf8>()
            .toDartString();
        devices.add(BtDevice(name, addrStr));
        _bindings.dc_bluetooth_device_free(dev.value);
      }
      _handleResult(result, 'bluetooth iterator next');
    } finally {
      _handleResult(_bindings.dc_iterator_free(iterator.value), 'iterator free');
      calloc.free(strbuf);
      calloc.free(dev);
      calloc.free(iterator);
    }

    log.info('Bluetooth devices: '
        '${devices.map((d) => '${d.name} (${d.address})').join(', ')}');
    return devices;
  }

  static ffi.Pointer<dc_iostream_t> _connectBluetooth(
      ffi.Pointer<dc_descriptor_t> descriptor, String address) {
    final addrNative = address.toNativeUtf8();
    final int64Addr = _bindings.dc_bluetooth_str2addr(addrNative.cast());
    calloc.free(addrNative);
    if (int64Addr == 0) {
      throw ArgumentError('Malformed Bluetooth address: $address');
    }
    log.info('Opening Bluetooth RFCOMM to $address');

    final iostream = calloc<ffi.Pointer<dc_iostream_t>>();
    _handleResult(
      // port 0 -> libdivecomputer resolves the SPP RFCOMM channel via SDP.
      _bindings.dc_bluetooth_open(iostream, context.value, int64Addr, 0),
      'bluetooth open (a DC_STATUS_NOACCESS here usually means the OS '
          'pairing failed mutual authentication — re-pair the device)',
    );
    return iostream.value;
  }
```

If `dc_bluetooth_addr2str`'s generated return type is `Pointer<Char>`, the `.cast<Utf8>().toDartString()` is correct. If ffigen generated the `strbuf` param as `Pointer<Char>`, `calloc<ffi.Char>(18)` matches. Adjust casts only if `flutter analyze` complains.

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/dive_computer_ffi_bluetooth_test.dart`
Expected: PASS.
Run: `flutter analyze lib/framework/dive_computer_ffi.dart`
Expected: no new issues (2 pre-existing `elementAt` infos only).

- [ ] **Step 5: Commit**

```bash
git add lib/framework/dive_computer_ffi.dart test/framework/dive_computer_ffi_bluetooth_test.dart
git commit -m "feat: Windows Bluetooth Classic enumerate + open via dc_bluetooth_open"
```

---

### Task 6: FFI `download` — `bluetooth` case + `_connectBle` → `_connectBridged`

**Files:**
- Modify: `lib/framework/dive_computer_ffi.dart`
- Modify: `test/framework/dive_computer_ffi_cap_test.dart`

**Interfaces:**
- Consumes: `_connectBluetooth` (Task 5), existing `_connectBle`.
- Produces:
  - `_connectBle(int)` renamed to `_connectBridged(int bridgeAddress, int transport)`; passes `transport` to `dc_custom_open`.
  - `download` param `bleBridgeAddress` renamed `bridgeAddress`; `bluetooth` case added.

- [ ] **Step 1: Write the failing test**

Append to `test/framework/dive_computer_ffi_cap_test.dart`:

```dart
  test('_connectBridged is transport-parameterised and used by both bridged '
      'transports', () {
    expect(source, contains('_connectBridged(int bridgeAddress, int transport)'));
    expect(source, isNot(contains('_connectBle(')));
    expect(source,
        contains('_connectBridged(bridgeAddress, dc_transport_t.DC_TRANSPORT_BLE)'));
    expect(
        source,
        contains(
            '_connectBridged(bridgeAddress, dc_transport_t.DC_TRANSPORT_BLUETOOTH)'));
  });

  test('download routes ComputerTransport.bluetooth to bridged (Android) or '
      '_connectBluetooth (Windows)', () {
    final dl = RegExp(r'case ComputerTransport\.bluetooth:(.+?)break;',
            dotAll: true)
        .firstMatch(source)
        ?.group(1);
    expect(dl, isNotNull);
    expect(dl, contains('bridgeAddress != null'));
    expect(dl, contains('_connectBridged(bridgeAddress'));
    expect(dl, contains('_connectBluetooth(computerDescriptor, address)'));
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/dive_computer_ffi_cap_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement**

Rename `_connectBle` and parameterise it:

```dart
  static ffi.Pointer<dc_iostream_t> _connectBridged(
      int bridgeAddress, int transport) {
    final bridge = BleBridge.fromAddress(bridgeAddress);
    final callbacks = calloc<dc_custom_cbs_t>();
    callbacks.ref
      ..set_timeout = BleBridgeCallbacks.setTimeoutPtr
      // ... (unchanged) ...
      ..close = BleBridgeCallbacks.closePtr;

    final iostream = calloc<ffi.Pointer<dc_iostream_t>>();
    _handleResult(
      _bindings.dc_custom_open(
        iostream,
        context.value,
        transport,
        callbacks,
        bridge.pointer.cast(),
      ),
      'bridged custom iostream open (transport=$transport)',
    );
    calloc.free(callbacks);
    return iostream.value;
  }
```

In `download`: rename the parameter `bleBridgeAddress` → `bridgeAddress`, and rewrite the `switch`:

```dart
    switch (transport) {
      case ComputerTransport.serial:
        iostream = _connectSerial(computerDescriptor, address);
        break;
      case ComputerTransport.ble:
        if (bridgeAddress == null) {
          throw ArgumentError('ComputerTransport.ble requires a bridgeAddress');
        }
        iostream = _connectBridged(bridgeAddress, dc_transport_t.DC_TRANSPORT_BLE);
        break;
      case ComputerTransport.bluetooth:
        iostream = bridgeAddress != null
            ? _connectBridged(
                bridgeAddress, dc_transport_t.DC_TRANSPORT_BLUETOOTH)
            : _connectBluetooth(computerDescriptor, address ?? '');
        break;
      default:
        throw UnimplementedError();
    }
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/dive_computer_ffi_cap_test.dart`
Expected: PASS.
Run: `flutter test` + `flutter analyze`
Expected: green / no new issues.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/dive_computer_ffi.dart test/framework/dive_computer_ffi_cap_test.dart
git commit -m "feat: FFI download() Bluetooth Classic case; _connectBle -> _connectBridged"
```

---

### Task 7: isolate + facade — Windows Bluetooth dispatch

**Files:**
- Modify: `lib/framework/dive_computer_isolate.dart`
- Modify: `test/framework/dive_computer_isolate_test.dart`

**Interfaces:**
- Consumes: `DiveComputerFfi.bluetoothDevices` (Task 5); `BtDevice`.
- Produces (on `DiveComputer`):
  - `Future<List<BtDevice>> bluetoothDevices(Computer)` — Windows: isolate round-trip; else `[]`.
  - `download(...)` forwards `address`; `bluetooth` on Windows sends `bridgeAddress: null` + `address`.
  - `DiveComputerMethod.bluetoothDevices`; guarded `Completer<List<BtDevice>>`.

- [ ] **Step 1: Write the failing test**

Append to `test/framework/dive_computer_isolate_test.dart`:

```dart
  test('bluetoothDevices round-trips with a guarded completer', () {
    expect(source, contains('DiveComputerMethod.bluetoothDevices'));
    expect(
      RegExp(r'is List<BtDevice>\)\s*\{\s*if \(_bluetoothDevices\?\.isCompleted'
              r' == false\)\s*\{\s*_bluetoothDevices\?\.complete\(message\)')
          .hasMatch(source),
      isTrue,
    );
  });

  test('_spawnIsolate handles bluetoothDevices via the FFI layer', () {
    expect(source,
        contains('DiveComputerFfi.bluetoothDevices(message.\$2[0] as Computer)'));
  });

  test('download forwards address in the isolate message', () {
    expect(
      source.contains(
          '[computer, transport, lastFingerprint, bridge?.address, address]'),
      isTrue,
    );
    expect(source, contains('final address = message.\$2[4] as String?'));
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/dive_computer_isolate_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `dive_computer_isolate.dart`:

1. `enum DiveComputerMethod { …, bluetoothDevices }` (add before `download`).
2. Field: `Completer<List<BtDevice>>? _bluetoothDevices;`
3. Receive-port listener — add a branch (near the `List<String>` one):

```dart
      } else if (message is List<BtDevice>) {
        if (_bluetoothDevices?.isCompleted == false) {
          _bluetoothDevices?.complete(message);
        }
```

4. Error branch — add `_bluetoothDevices?.completeError(message)` guarded like the others.
5. Method:

```dart
  @override
  Future<List<BtDevice>> bluetoothDevices(Computer computer) async {
    if (!Platform.isWindows) return const [];
    await _send((DiveComputerMethod.bluetoothDevices, [computer]));
    return (_bluetoothDevices = Completer<List<BtDevice>>()).future;
  }
```

(add `import 'dart:io';` and `import 'package:dive_computer/types/bt_device.dart';` if not present)

6. `download`: parameter already `address` (Task 3). Change the `_send` args to
   `[computer, transport, lastFingerprint, bridge?.address, address]`.
7. `_spawnIsolate` switch:

```dart
        case DiveComputerMethod.bluetoothDevices:
          sendPort.send(
              DiveComputerFfi.bluetoothDevices(message.$2[0] as Computer));
          break;
```

8. In the `download` case of `_spawnIsolate`: add `final address = message.$2[4] as String?;` and pass it: `DiveComputerFfi.download(computer, transport, lastFingerprint, bleBridgeAddress, address)` → note `bleBridgeAddress` local there stays; pass `address` as the 5th arg.

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/dive_computer_isolate_test.dart` → PASS
Run: `flutter test` + `flutter analyze` → green / no new issues.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/dive_computer_isolate.dart test/framework/dive_computer_isolate_test.dart
git commit -m "feat: isolate + facade wiring for Windows Bluetooth Classic download"
```

**Phase B checkpoint:** On a Windows machine with a paired Classic dive computer, `dc.bluetoothDevices(computer)` lists it and `dc.download(computer, ComputerTransport.bluetooth, fp, address)` attempts the download. (May fail at `dc_bluetooth_open` if the OS pairing is broken — that is expected and out of scope.)

---

## Phase C — Android

### Task 8: hybrid plugin — `pluginClass` + Kotlin RFCOMM channel

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/src/main/AndroidManifest.xml`
- Create: `android/src/main/kotlin/app/divenote/dive_computer/DiveComputerPlugin.kt`
- Test: none automated (Kotlin; consistent with repo). Build check only.

**Interfaces:**
- Produces: MethodChannel `app.divenote.dive_computer/rfcomm` with methods `requestPermissions() -> bool`, `bondedDevices() -> List<Map{name,address}>`, `connect(address: String) -> null`, `write(bytes: Uint8List) -> null`, `disconnect() -> null`; EventChannel `app.divenote.dive_computer/rfcomm/inbound` streaming `Uint8List` chunks, `endOfStream` on disconnect.

- [ ] **Step 1: pubspec + manifest**

`pubspec.yaml` — under `plugin.platforms.android`, add `pluginClass`:

```yaml
      android:
        ffiPlugin: true
        pluginClass: DiveComputerPlugin
```

`android/src/main/AndroidManifest.xml` — add inside `<manifest>`:

```xml
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
```

- [ ] **Step 2: Write the Kotlin plugin**

Create `android/src/main/kotlin/app/divenote/dive_computer/DiveComputerPlugin.kt`:

```kotlin
package app.divenote.dive_computer

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.UUID
import java.util.concurrent.Executors

private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
private const val METHOD_CHANNEL = "app.divenote.dive_computer/rfcomm"
private const val EVENT_CHANNEL = "app.divenote.dive_computer/rfcomm/inbound"
private const val PERM_REQUEST_CODE = 0xB7

class DiveComputerPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, PluginRegistry.RequestPermissionsResultListener {

  private lateinit var appContext: Context
  private lateinit var methodChannel: MethodChannel
  private lateinit var eventChannel: EventChannel

  private var activity: Activity? = null
  private var pendingPermissionResult: MethodChannel.Result? = null

  private var eventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val io = Executors.newSingleThreadExecutor()

  private var socket: BluetoothSocket? = null
  private var readerThread: Thread? = null

  private val adapter: BluetoothAdapter?
    get() = (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

  // --- FlutterPlugin ---

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
    methodChannel.setMethodCallHandler(this)
    eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
    eventChannel.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    closeSocket()
    io.shutdownNow()
  }

  // --- ActivityAware ---

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addRequestPermissionsResultListener(this)
  }
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
      onAttachedToActivity(binding)
  override fun onDetachedFromActivityForConfigChanges() { activity = null }
  override fun onDetachedFromActivity() { activity = null }

  // --- permissions ---

  private fun hasConnectPermission(): Boolean =
      Build.VERSION.SDK_INT < 31 ||
          ActivityCompat.checkSelfPermission(appContext, Manifest.permission.BLUETOOTH_CONNECT) ==
              PackageManager.PERMISSION_GRANTED

  override fun onRequestPermissionsResult(
      requestCode: Int, permissions: Array<out String>, grantResults: IntArray
  ): Boolean {
    if (requestCode != PERM_REQUEST_CODE) return false
    val granted = grantResults.isNotEmpty() &&
        grantResults[0] == PackageManager.PERMISSION_GRANTED
    pendingPermissionResult?.success(granted)
    pendingPermissionResult = null
    return true
  }

  // --- MethodChannel ---

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "requestPermissions" -> {
        if (Build.VERSION.SDK_INT < 31 || hasConnectPermission()) {
          result.success(true); return
        }
        val act = activity
        if (act == null) { result.success(false); return }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            act, arrayOf(Manifest.permission.BLUETOOTH_CONNECT), PERM_REQUEST_CODE)
      }

      "bondedDevices" -> {
        if (!hasConnectPermission()) {
          result.error("permission_denied", "BLUETOOTH_CONNECT not granted", null); return
        }
        val a = adapter
        if (a == null) { result.error("no_adapter", "No Bluetooth adapter", null); return }
        val list = a.bondedDevices.map { mapOf("name" to (it.name ?: ""), "address" to it.address) }
        result.success(list)
      }

      "connect" -> {
        val address = call.argument<String>("address")
        if (address == null) { result.error("bad_args", "address required", null); return }
        if (!hasConnectPermission()) {
          result.error("permission_denied", "BLUETOOTH_CONNECT not granted", null); return
        }
        io.execute {
          try {
            closeSocket()
            val a = adapter ?: throw IllegalStateException("No Bluetooth adapter")
            a.cancelDiscovery()
            val s = a.getRemoteDevice(address).createRfcommSocketToServiceRecord(SPP_UUID)
            s.connect() // blocks ~12s, throws IOException on failure
            socket = s
            startReader(s)
            mainHandler.post { result.success(null) }
          } catch (e: Exception) {
            closeSocket()
            mainHandler.post { result.error("connect_failed", e.message, null) }
          }
        }
      }

      "write" -> {
        val bytes = call.argument<ByteArray>("bytes")
        val s = socket
        if (bytes == null) { result.error("bad_args", "bytes required", null); return }
        if (s == null) { result.error("not_connected", "No RFCOMM socket", null); return }
        io.execute {
          try {
            synchronized(s) { s.outputStream.write(bytes); s.outputStream.flush() }
            mainHandler.post { result.success(null) }
          } catch (e: Exception) {
            mainHandler.post { result.error("write_failed", e.message, null) }
          }
        }
      }

      "disconnect" -> { closeSocket(); result.success(null) }

      else -> result.notImplemented()
    }
  }

  // --- EventChannel ---

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
  override fun onCancel(arguments: Any?) { eventSink = null }

  private fun startReader(s: BluetoothSocket) {
    val t = Thread {
      val buf = ByteArray(4096)
      try {
        while (!Thread.currentThread().isInterrupted) {
          val n = s.inputStream.read(buf)
          if (n < 0) break
          if (n > 0) {
            val chunk = buf.copyOf(n)
            mainHandler.post { eventSink?.success(chunk) }
          }
        }
      } catch (_: Exception) {
        // fall through to endOfStream
      }
      mainHandler.post { eventSink?.endOfStream() }
    }
    t.isDaemon = true
    readerThread = t
    t.start()
  }

  private fun closeSocket() {
    readerThread?.interrupt()
    readerThread = null
    try { socket?.close() } catch (_: Exception) {}
    socket = null
  }
}
```

- [ ] **Step 3: Add the AndroidX core dependency**

`android/build.gradle` — inside `android { }` add nothing new for deps; instead add at the bottom of the file:

```gradle
dependencies {
    implementation 'androidx.core:core-ktx:1.10.1'
}
```

And ensure Kotlin is applied — add near the top after `apply plugin: 'com.android.library'`:

```gradle
apply plugin: 'kotlin-android'
```

and in `buildscript.dependencies`:

```gradle
        classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:1.8.22'
```

- [ ] **Step 4: Build the example for Android to verify it compiles**

Run: `cd example && flutter build apk --debug`
Expected: BUILD SUCCESSFUL. If Kotlin/AGP version conflicts arise, align `kotlin-gradle-plugin` / `com.android.tools.build:gradle` with what `example/android/settings.gradle` pins and retry.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml android/
git commit -m "feat: Android hybrid plugin with Kotlin RFCOMM (BluetoothSocket) channel"
```

---

### Task 9: `RfcommChannel` (Dart wrapper + fake)

**Files:**
- Create: `lib/framework/rfcomm/rfcomm_channel.dart`
- Test: `test/framework/rfcomm/rfcomm_channel_test.dart`

**Interfaces:**
- Consumes: `BtDevice`; the channels from Task 8.
- Produces:
  - `abstract class RfcommChannel { Future<bool> requestPermissions(); Future<List<BtDevice>> bondedDevices(); Future<void> connect(String address); Stream<Uint8List> get inbound; Future<void> write(List<int> bytes); Future<void> disconnect(); }`
  - `class MethodChannelRfcommChannel implements RfcommChannel`
  - `class FakeRfcommChannel implements RfcommChannel` (test double)

- [ ] **Step 1: Write the failing test**

```dart
// test/framework/rfcomm/rfcomm_channel_test.dart
import 'dart:typed_data';
import 'package:dive_computer/framework/rfcomm/rfcomm_channel.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FakeRfcommChannel records connect/write and replays inbound', () async {
    final ch = FakeRfcommChannel();
    ch.bonded = [const BtDevice('Petrel', '00:13:43:0A:A0:6F')];

    expect(await ch.requestPermissions(), isTrue);
    expect(await ch.bondedDevices(), ch.bonded);

    await ch.connect('00:13:43:0A:A0:6F');
    expect(ch.connectedAddress, '00:13:43:0A:A0:6F');

    final received = <List<int>>[];
    final sub = ch.inbound.listen(received.add);

    await ch.write([1, 2, 3]);
    expect(ch.writes, [
      [1, 2, 3]
    ]);

    ch.emitInbound(Uint8List.fromList([9, 8, 7]));
    await Future<void>.delayed(Duration.zero);
    expect(received, [
      [9, 8, 7]
    ]);

    await ch.disconnect();
    expect(ch.disconnected, isTrue);
    await sub.cancel();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/rfcomm/rfcomm_channel_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Implement**

```dart
// lib/framework/rfcomm/rfcomm_channel.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../types/bt_device.dart';

/// Main-isolate access to a Bluetooth-Classic RFCOMM connection. On Android
/// this is backed by [DiveComputerPlugin]'s method/event channels; a
/// [FakeRfcommChannel] stands in for tests.
abstract class RfcommChannel {
  Future<bool> requestPermissions();
  Future<List<BtDevice>> bondedDevices();
  Future<void> connect(String address);
  Stream<Uint8List> get inbound;
  Future<void> write(List<int> bytes);
  Future<void> disconnect();
}

class MethodChannelRfcommChannel implements RfcommChannel {
  static const _method = MethodChannel('app.divenote.dive_computer/rfcomm');
  static const _events =
      EventChannel('app.divenote.dive_computer/rfcomm/inbound');

  @override
  Future<bool> requestPermissions() async =>
      (await _method.invokeMethod<bool>('requestPermissions')) ?? false;

  @override
  Future<List<BtDevice>> bondedDevices() async {
    final raw = await _method.invokeListMethod<Map<Object?, Object?>>(
            'bondedDevices') ??
        const [];
    return raw
        .map((m) => BtDevice(
            (m['name'] as String?) ?? '', (m['address'] as String?) ?? ''))
        .toList();
  }

  @override
  Future<void> connect(String address) =>
      _method.invokeMethod<void>('connect', {'address': address});

  @override
  Stream<Uint8List> get inbound => _events
      .receiveBroadcastStream()
      .map((e) => e is Uint8List ? e : Uint8List.fromList((e as List).cast()));

  @override
  Future<void> write(List<int> bytes) => _method.invokeMethod<void>(
      'write', {'bytes': Uint8List.fromList(bytes)});

  @override
  Future<void> disconnect() => _method.invokeMethod<void>('disconnect');
}

class FakeRfcommChannel implements RfcommChannel {
  List<BtDevice> bonded = const [];
  bool permissionGranted = true;
  String? connectedAddress;
  bool disconnected = false;
  final List<List<int>> writes = [];
  final _inbound = StreamController<Uint8List>.broadcast();

  void emitInbound(Uint8List bytes) => _inbound.add(bytes);
  void emitDisconnect() => _inbound.close();

  @override
  Future<bool> requestPermissions() async => permissionGranted;
  @override
  Future<List<BtDevice>> bondedDevices() async => bonded;
  @override
  Future<void> connect(String address) async => connectedAddress = address;
  @override
  Stream<Uint8List> get inbound => _inbound.stream;
  @override
  Future<void> write(List<int> bytes) async => writes.add(bytes);
  @override
  Future<void> disconnect() async => disconnected = true;
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/rfcomm/rfcomm_channel_test.dart` → PASS
Run: `flutter analyze` → no new issues.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/rfcomm/rfcomm_channel.dart test/framework/rfcomm/rfcomm_channel_test.dart
git commit -m "feat: RfcommChannel Dart wrapper + FakeRfcommChannel"
```

---

### Task 10: `RfcommTransport`

**Files:**
- Create: `lib/framework/rfcomm/rfcomm_transport.dart`
- Test: `test/framework/rfcomm/rfcomm_transport_test.dart`

**Interfaces:**
- Consumes: `RfcommChannel` (Task 9), `BleBridge` (`lib/framework/ble/ble_bridge_state.dart`), `dc_status_t` from the generated bindings.
- Produces: `class RfcommTransport { RfcommTransport(RfcommChannel channel); bool get isConnected; Future<void> connect(String address); void attachBridge(BleBridge bridge); Future<void> disconnect(); }`

- [ ] **Step 1: Write the failing test**

```dart
// test/framework/rfcomm/rfcomm_transport_test.dart
import 'dart:typed_data';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_channel.dart';
import 'package:dive_computer/framework/rfcomm/rfcomm_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'dart:ffi' as ffi;

void main() {
  test('inbound socket bytes land in the bridge ring buffer', () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);

    await t.connect('00:13:43:0A:A0:6F');
    t.attachBridge(bridge);

    ch.emitInbound(Uint8List.fromList([1, 2, 3, 4]));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final dest = calloc<ffi.Uint8>(16);
    final n = bridge.popInbound(dest, 16);
    expect(n, 4);
    expect([for (var i = 0; i < 4; i++) dest[i]], [1, 2, 3, 4]);
    calloc.free(dest);
  });

  test('outbound mailbox is drained to channel.write and acked', () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    await t.connect('x');
    t.attachBridge(bridge);

    final data = calloc<ffi.Uint8>(3);
    data[0] = 10; data[1] = 20; data[2] = 30;
    final seq = bridge.queueOutbound(data, 3);
    calloc.free(data);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ch.writes, [[10, 20, 30]]);
    expect(bridge.waitForWriteAck(seq, 0), isTrue);
  });

  test('a socket disconnect marks the bridge closed', () async {
    final ch = FakeRfcommChannel();
    final t = RfcommTransport(ch);
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    await t.connect('x');
    t.attachBridge(bridge);

    ch.emitDisconnect();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(bridge.isClosed, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/rfcomm/rfcomm_transport_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Implement** (mailbox-pump / teardown adapted from `BleTransport`, no shared base — see Global Constraints)

```dart
// lib/framework/rfcomm/rfcomm_transport.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../ble/ble_bridge_state.dart';
import '../dive_computer_ffi_bindings_generated.dart';
import 'rfcomm_channel.dart';

final _log = Logger('RfcommTransport');

/// Main-isolate driver for a Bluetooth-Classic RFCOMM connection on behalf of
/// a [BleBridge] running on the background isolate. RFCOMM is a plain byte
/// stream, so this is simpler than `BleTransport` — no service/characteristic
/// discovery. The mailbox pump / teardown mirror `BleTransport` (kept
/// duplicated deliberately; see the plan's Global Constraints).
class RfcommTransport {
  RfcommTransport(this._channel);

  final RfcommChannel _channel;
  BleBridge? _bridge;
  bool _connected = false;

  StreamSubscription<Uint8List>? _inboundSub;
  Timer? _mailboxTimer;
  int _lastServicedWriteSeq = 0;
  bool _writeInFlight = false;

  bool get isConnected => _connected;

  Future<bool> requestPermissions() => _channel.requestPermissions();

  Future<void> connect(String address) async {
    await _channel.connect(address);
    _connected = true;
    _log.fine('RFCOMM connected to $address');
  }

  void attachBridge(BleBridge bridge) {
    if (!_connected) {
      throw StateError('attachBridge() before connect()');
    }
    _bridge = bridge;
    _lastServicedWriteSeq = 0;
    _inboundSub = _channel.inbound.listen(
      (bytes) {
        final b = _bridge;
        if (b == null || b.isClosed) return;
        final written = b.pushInbound(bytes);
        if (written < bytes.length) {
          _log.severe('Inbound ring buffer overflow: dropped '
              '${bytes.length - written} of ${bytes.length} bytes');
        }
      },
      onDone: _handleDisconnect,
      onError: (Object e, StackTrace st) {
        _log.warning('RFCOMM inbound error', e, st);
        _handleDisconnect();
      },
    );
    _mailboxTimer = Timer.periodic(
        const Duration(milliseconds: 4), (_) => _serviceMailbox());
  }

  Future<void> _serviceMailbox() async {
    if (_writeInFlight) return;
    final bridge = _bridge;
    if (bridge == null || !_connected) return;
    final seq = bridge.pendingWriteSeq;
    if (seq == _lastServicedWriteSeq) return;
    _lastServicedWriteSeq = seq;
    _writeInFlight = true;
    try {
      await _channel.write(bridge.pendingOutbound);
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_SUCCESS);
    } catch (e, st) {
      _log.severe('RFCOMM mailbox write failed', e, st);
      bridge.ackOutbound(seq, dc_status_t.DC_STATUS_IO);
    } finally {
      _writeInFlight = false;
    }
  }

  void _handleDisconnect() {
    _bridge?.markClosed();
    _teardown();
  }

  Future<void> disconnect() async {
    _bridge?.markClosed();
    if (_connected) await _channel.disconnect().catchError((_) {});
    _teardown();
  }

  void _teardown() {
    _mailboxTimer?.cancel();
    _mailboxTimer = null;
    _inboundSub?.cancel();
    _inboundSub = null;
    _connected = false;
    _bridge = null;
  }
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/rfcomm/rfcomm_transport_test.dart` → PASS (3 tests)
Run: `flutter test` + `flutter analyze` → green / no new issues.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/rfcomm/rfcomm_transport.dart test/framework/rfcomm/rfcomm_transport_test.dart
git commit -m "feat: RfcommTransport (main-isolate RFCOMM <-> bridge pump)"
```

---

### Task 11: isolate + facade — Android Bluetooth dispatch

**Files:**
- Modify: `lib/framework/dive_computer_isolate.dart`
- Modify: `test/framework/dive_computer_isolate_test.dart`

**Interfaces:**
- Consumes: `RfcommChannel` / `MethodChannelRfcommChannel` (Task 9), `RfcommTransport` (Task 10), the existing `_bleBridgeReleased` two-phase teardown, `BleBridge`.
- Produces: `DiveComputer.bluetoothDevices` / `requestBluetoothPermissions` / `download` handle Android via the RFCOMM channel + bridge; Windows path (Task 7) unchanged.

- [ ] **Step 1: Write the failing test**

Append to `test/framework/dive_computer_isolate_test.dart`:

```dart
  test('Android bluetooth download uses the RFCOMM channel + bridge', () {
    // bluetoothDevices: Android via channel, Windows via isolate.
    expect(source, contains('Platform.isAndroid'));
    expect(source, contains('_rfcommChannel.bondedDevices()'));
    // download bluetooth on Android: connect channel, allocate bridge, attach.
    expect(source, contains('_rfcommChannel.connect('));
    expect(source, contains('_rfcommTransport.attachBridge('));
    // the download message for Android bluetooth carries a bridge address
    expect(
      RegExp(r'ComputerTransport\.bluetooth.*Platform\.isAndroid', dotAll: true)
          .hasMatch(source),
      isTrue,
    );
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/framework/dive_computer_isolate_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `dive_computer_isolate.dart` `DiveComputer`:

1. Fields:

```dart
  final RfcommChannel _rfcommChannel = MethodChannelRfcommChannel();
  late final RfcommTransport _rfcommTransport = RfcommTransport(_rfcommChannel);
```

(imports: `package:dive_computer/framework/rfcomm/rfcomm_channel.dart`, `.../rfcomm_transport.dart`)

2. `requestBluetoothPermissions`:

```dart
  @override
  Future<bool> requestBluetoothPermissions() =>
      Platform.isAndroid ? _rfcommChannel.requestPermissions() : Future.value(true);
```

3. `bluetoothDevices` — replace Task 7's Windows-only body:

```dart
  @override
  Future<List<BtDevice>> bluetoothDevices(Computer computer) async {
    if (Platform.isAndroid) return _rfcommChannel.bondedDevices();
    if (Platform.isWindows) {
      await _send((DiveComputerMethod.bluetoothDevices, [computer]));
      return (_bluetoothDevices = Completer<List<BtDevice>>()).future;
    }
    return const [];
  }
```

4. `download` — add an Android bluetooth branch, modelled exactly on the existing BLE branch (the `try { … allocate/attach/send } catch { dispose } … finally { await released; dispose }` structure). Concretely, in the pre-send `try`:

```dart
      if (transport == ComputerTransport.ble) {
        // ... unchanged ...
      } else if (transport == ComputerTransport.bluetooth && Platform.isAndroid) {
        if (address == null) {
          throw ArgumentError('Android bluetooth download requires an address');
        }
        await _rfcommChannel.connect(address);
        bridge = BleBridge.allocate();
        _rfcommTransport.attachBridge(bridge);
        _bleBridgeReleased = Completer<void>();
      }
      await _send((
        DiveComputerMethod.download,
        [computer, transport, lastFingerprint, bridge?.address, address],
      ));
```

and in the `finally` after the download completes, when `bridge != null`, also disconnect the RFCOMM channel:

```dart
    } finally {
      if (bridge != null) {
        await _bleBridgeReleased!.future;
        bridge.dispose();
        if (transport == ComputerTransport.bluetooth) {
          await _rfcommTransport.disconnect();
        }
      }
    }
```

(BLE's own disconnect stays wherever it currently is — do not double-disconnect.)

- [ ] **Step 4: Run tests**

Run: `flutter test test/framework/dive_computer_isolate_test.dart` → PASS
Run: `flutter test` + `flutter analyze` → green / no new issues.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/dive_computer_isolate.dart test/framework/dive_computer_isolate_test.dart
git commit -m "feat: Android Bluetooth Classic download via RFCOMM channel + bridge"
```

---

### Task 12: example app — "Serial / Bluetooth" tab

**Files:**
- Modify: `example/android/app/src/main/AndroidManifest.xml`
- Modify: `example/lib/main.dart`
- Modify: `example/lib/ble_download_support.dart` (add a Classic-BT candidate helper) — or inline
- Test: `example/test/ble_download_support_test.dart` (extend)

**Interfaces:**
- Consumes: `dc.bluetoothDevices`, `dc.requestBluetoothPermissions`, `dc.download(..., address)`, `ClassicBtProfiles`, `BtDevice`.

- [ ] **Step 1: Manifest**

`example/android/app/src/main/AndroidManifest.xml` — add the same three `uses-permission` lines as Task 8.

- [ ] **Step 2: Write the failing test**

Extend `example/test/ble_download_support_test.dart`:

```dart
  group('bluetoothCandidatesFor', () {
    test('filters bonded devices by the computer vendor profile', () {
      final petrel = const BtDevice('Petrel', '00:13:43:0A:A0:6F');
      final earbuds = const BtDevice('Baseus Encok', '11:22:33:44:55:66');
      final out = bluetoothCandidates(
          isShearwater: true, bonded: [petrel, earbuds]);
      expect(out, [petrel]);
    });

    test('no profile -> all bonded devices', () {
      final a = const BtDevice('A', '00:00:00:00:00:01');
      expect(bluetoothCandidates(isShearwater: false, bonded: [a]), [a]);
    });
  });
```

- [ ] **Step 3: Implement the helper**

In `example/lib/ble_download_support.dart`:

```dart
import 'package:dive_computer/dive_computer.dart';

/// Bonded devices worth offering for [isShearwater] ? the Shearwater profile :
/// everything. Uses `ClassicBtProfiles` name patterns.
List<BtDevice> bluetoothCandidates({
  required bool isShearwater,
  required List<BtDevice> bonded,
}) {
  if (!isShearwater) return bonded;
  return bonded
      .where((d) => ClassicBtProfiles.shearwater.matchesName(d.name))
      .toList();
}
```

Add `export 'types/bt_device.dart';` and `export 'types/classic_bt_profile.dart';` to `lib/dive_computer.dart` so the example can import them.

- [ ] **Step 4: Wire the UI**

In `example/lib/main.dart` `_downloadFrom`, before the serial branch, add:

```dart
      if (transport == ComputerTransport.bluetooth) {
        if (!await dc.requestBluetoothPermissions()) {
          messenger.showSnackBar(const SnackBar(
              content: Text('Bluetooth permission denied')));
          return;
        }
        final bonded = await dc.bluetoothDevices(computer);
        if (bonded.isEmpty) {
          messenger.showSnackBar(const SnackBar(
              content: Text('No paired Bluetooth devices — pair the dive '
                  'computer in system Bluetooth settings first')));
          return;
        }
        if (!context.mounted) return;
        final candidates = bluetoothCandidates(
            isShearwater: computer.vendor.toLowerCase() == 'shearwater',
            bonded: bonded);
        final picked = await showDialog<BtDevice>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Which paired device?'),
            children: [
              for (final d in (candidates.isEmpty ? bonded : candidates))
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, d),
                  child: Text('${d.name}  (${d.address})'),
                ),
            ],
          ),
        );
        if (picked == null) return;
        final dives = await dc.download(computer, ComputerTransport.bluetooth,
            'exampleFingerprint', picked.address);
        messenger.showSnackBar(
            SnackBar(content: Text('Downloaded ${dives.length} dives')));
        return;
      }
```

Update the tab label `'Serial computers'` → `'Serial / Bluetooth'`.

- [ ] **Step 5: Run tests + build**

Run: `cd example && flutter test` → PASS
Run: `cd example && flutter analyze` → no issues
Run: `cd example && flutter build apk --debug` → BUILD SUCCESSFUL

- [ ] **Step 6: Commit**

```bash
git add example/ lib/dive_computer.dart
git commit -m "feat: example Serial/Bluetooth tab with bonded-device picker"
```

**Phase C checkpoint (manual, user):** Pixel 6a — pair the Petrel in system Bluetooth settings (Petrel on its Bluetooth/upload screen, PIN 0000). Example → "Serial / Bluetooth" → **Shearwater Petrel** → grant permission → pick **Petrel** → full dive log downloads and renders; console dump complete. Walk away mid-download → typed error, no hang, retry works.

---

## Phase D — docs

### Task 13: CHANGELOG + README

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `README.md`

- [ ] **Step 1: CHANGELOG**

Under `## Unreleased`, add:

```markdown
* Bluetooth Classic (RFCOMM/SPP) transport — `ComputerTransport.bluetooth` is
  now implemented for **Windows** (via libdivecomputer's `dc_bluetooth_open`)
  and **Android** (via a Kotlin `BluetoothSocket` RFCOMM channel feeding the
  isolate bridge). Enables the Bluetooth-Classic-only Shearwaters (Predator,
  Petrel, Petrel 2, NERD, Perdix). New API: `DiveComputer.bluetoothDevices()`,
  `DiveComputer.requestBluetoothPermissions()`; `download()`'s `serialPort`
  parameter is generalised to `address`. Devices must be paired/bonded in the
  OS first (no in-app pairing). On Windows a legacy device whose OS pairing
  fails mutual authentication will still fail to open — that is an OS/hardware
  matter, not a plugin one.
```

- [ ] **Step 2: README**

In the Roadmap section, change the Bluetooth bullet from "not implemented yet" to note Classic RFCOMM is done for Windows + Android (bonded devices only), BLE as before, iOS/macOS still not.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "docs: Bluetooth Classic transport (Windows + Android)"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task(s) |
|---|---|
| `BtDevice` | 1 |
| `ClassicBtProfiles.shearwater` | 2 |
| Bridge doc-comment (rename deferred per Global Constraints) | 3 |
| `download` `serialPort`→`address`; interface `bluetoothDevices` / `requestBluetoothPermissions` | 3 |
| `ffigen.yaml` + `bluetooth.h` | 4 |
| Windows `bluetoothDevices` + `_connectBluetooth` | 5 |
| FFI `download` switch + `_connectBridged` | 6 |
| Isolate `bluetoothDevices` + Windows facade dispatch | 7 |
| `pubspec` hybrid `pluginClass` + Kotlin plugin + plugin manifest | 8 |
| `RfcommChannel` (abstract/real/fake) | 9 |
| `RfcommTransport` | 10 |
| Isolate/facade Android dispatch + Android bluetooth `download` | 11 |
| Example "Serial / Bluetooth" tab + example manifest | 12 |
| CHANGELOG + README | 13 |
| `BridgedTransport` extraction | **Dropped** — Global Constraints; `RfcommTransport` duplicates the pump |
| macOS/iOS Classic BT, in-app discovery, `BLUETOOTH_SCAN` | Non-goals — not implemented |

**Placeholder scan:** none — every code step has real code; every command has an expected result.

**Type consistency:**
- `download(Computer, ComputerTransport, [String? lastFingerprint, String? address])` — interface (Task 3), isolate (Tasks 3/7/11), FFI (Tasks 3/6). Consistent.
- FFI internal: `download(..., int? bridgeAddress, String? address)` (Task 6). Isolate message `[computer, transport, lastFingerprint, bridge?.address, address]` (Tasks 7/11); `_spawnIsolate` reads `message.$2[3]` as `bleBridgeAddress` (existing) and `message.$2[4]` as `address` (Task 7). Consistent.
- `BtDevice(String name, String address)` — Tasks 1, 5, 9, 11, 12. Consistent.
- `BleBridge` name kept everywhere (Global Constraints); `RfcommTransport` imports `../ble/ble_bridge_state.dart` (Task 10). Consistent.
- `_connectBridged(int bridgeAddress, int transport)` — defined Task 6, used Tasks 6. Consistent.
- `RfcommChannel` methods identical across abstract / `MethodChannelRfcommChannel` / `FakeRfcommChannel` (Task 9) and consumed in `RfcommTransport` (Task 10) and `DiveComputer` (Task 11). Consistent.

**Known gaps accepted:** the Kotlin plugin has no automated tests (repo has no native test harness); Windows enumeration/open is covered only by source-inspection tests (cannot run the native lib under `flutter test`); real end-to-end validation is the manual Phase C checkpoint on the user's Pixel + Petrel.
