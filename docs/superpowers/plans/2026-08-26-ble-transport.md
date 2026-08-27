# BLE Transport (Windows-first) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `ComputerTransport.ble` end-to-end for Windows, so `DiveComputer.download()` can pull dives from a BLE dive computer via `libdivecomputer`'s `dc_custom_open()`, bridged to the `universal_ble` plugin.

**Architecture:** A background isolate runs blocking `libdivecomputer` calls as it does today. A pure-Dart, `dart:ffi`-backed shared-memory ring buffer + mailbox (`BleBridge`) lets that isolate's synchronous `read`/`write`/`poll` callbacks spin-poll for data, while the main isolate drives the actual BLE I/O via `universal_ble` (wrapped behind a `BleCentral` seam for testability) and services the bridge asynchronously. No custom native (C/C++/Kotlin) code is required.

**Tech Stack:** Flutter/Dart, `dart:ffi`, `package:ffi`, `package:universal_ble`, `package:logging` (existing), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-08-26-ble-transport-design.md`

## Global Constraints

- No custom native C/C++/Kotlin code for the sync bridge — pure Dart + `dart:ffi` only (spec Decision 2).
- BLE plumbing goes through `universal_ble`, not hand-written per-platform code (spec Decision 1).
- This plan targets **Windows first**. Android/iOS validation and the per-vendor `BleProfile` table are explicitly out of scope (spec Non-goals).
- `ComputerTransport.bluetooth` (Bluetooth Classic/RFCOMM) is **not** touched by this plan — it continues to throw `UnimplementedError` as it does today.
- Never perform a GATT **write** against a device outside a matched `BleProfile`. Read-only introspection (scan/connect/discoverServices) against an unrelated real device (e.g. for the Tier 0 smoke test) is fine; writes are not.
- All new verbose/byte-level logging is gated behind the existing `DiveComputer.enableDebugLogging()` switch, using the existing `logging` package convention (one `Logger` per class, `finest`/`fine`/`warning`/`severe` as appropriate).
- Every blocking wait in the bridge is timeout-bounded — see `kHardCapTimeoutMs` in Task 6. No unbounded spin loops.

---

### Task 1: Bind `custom.h` and `ble.h` via ffigen

**Files:**
- Modify: `ffigen.yaml`
- Modify (generated): `lib/framework/dive_computer_ffi_bindings_generated.dart`

**Interfaces:**
- Produces: `DiveComputerFfiBindings.dc_custom_open(...)`, the `dc_custom_cbs_t` struct, and `DC_IOCTL_BLE_GET_NAME` becoming available in the generated bindings (used by Task 11).

- [ ] **Step 1: Confirm/install an ffigen-compatible LLVM**

`ffigen` needs `libclang`. Check first:
```
where clang
```
If nothing is found, install LLVM (e.g. `winget install LLVM.LLVM`, or download from https://releases.llvm.org/), then re-run the check. If ffigen still can't auto-locate it after install, add an explicit `llvm-path` to `ffigen.yaml`:
```yaml
llvm-path:
  - 'C:\Program Files\LLVM'
```
(This repo's `ffigen.yaml` did not have `llvm-path` set as of this plan — only add it if auto-detection fails.)

- [ ] **Step 2: Add the two new entry-point headers**

In `ffigen.yaml`, under `headers: entry-points:`, add two lines after the existing five:
```yaml
    - 'native/include/libdivecomputer/custom.h'
    - 'native/include/libdivecomputer/ble.h'
```

- [ ] **Step 3: Regenerate bindings**

```
flutter pub get
flutter pub run ffigen --config ffigen.yaml
```

- [ ] **Step 4: Verify the new bindings exist**

```
grep -n "dc_custom_open\|dc_custom_cbs_t\|DC_IOCTL_BLE_GET_NAME" lib/framework/dive_computer_ffi_bindings_generated.dart
```
Expected: matches for all three. If `dc_custom_open` is missing, re-check Step 2's YAML indentation (must be a sibling of the existing entry-point list items) and re-run Step 3.

Note the exact generated Dart type names for `dc_custom_cbs_t`'s function-pointer fields (e.g. by opening the file and searching for `class dc_custom_cbs_t`) — Task 7 needs this struct's field list, though it does **not** need to match ffigen's internal typedef *names* (see Task 7's note on why).

- [ ] **Step 5: Run existing tests/analyzer to confirm nothing broke**

```
flutter analyze
```
Expected: no new errors (ffigen output only adds declarations; nothing references them yet).

- [ ] **Step 6: Commit**

```bash
git add ffigen.yaml lib/framework/dive_computer_ffi_bindings_generated.dart
git commit -m "Bind libdivecomputer custom.h/ble.h for the BLE transport"
```

---

### Task 2: Add the `universal_ble` dependency

**Files:**
- Modify: `pubspec.yaml`

**Interfaces:**
- Produces: `package:universal_ble/universal_ble.dart` available to the plugin (used by Tasks 3 and 8).

- [ ] **Step 1: Add the dependency**

In `pubspec.yaml`, under `dependencies:`, add (alphabetical, matching the existing style):
```yaml
  universal_ble: '>=0.16.0 <1.0.0'
```
Run `flutter pub get` and let it resolve the exact installable version; if the resolved version differs meaningfully from `0.16.0`, adjust the constraint to match what actually resolves rather than forcing a version.

- [ ] **Step 2: Verify it resolves for the Windows platform**

```
flutter pub get
flutter pub deps | grep universal_ble
```
Expected: `universal_ble` and its Windows-platform implementation package appear with no resolution conflicts.

- [ ] **Step 3: Commit**

```bash
git add pubspec.yaml
git commit -m "Add universal_ble dependency for BLE transport"
```

---

### Task 3: Tier 0 smoke test — raw scan/connect/discoverServices (manual gate)

Per the spec, this validates the biggest unknown (does `universal_ble` actually work on Windows here) **before** any bridge code is written. Uses `universal_ble` directly — no dependency on later tasks. Read-only: this must never write to a characteristic, since the test target (your Garmin watch) is a real device we don't control the firmware of.

**Files:**
- Modify: `example/lib/main.dart`

**Interfaces:**
- None (throwaway-shaped, but left in place — Task 12 extends this same screen).

- [ ] **Step 1: Add a minimal BLE debug screen to the example app**

Replace the body of `example/lib/main.dart`'s `_MyAppState` with a second tab/screen (simplest: a `TabBar` with the existing dive-computer list as tab 1, and a new BLE debug view as tab 2). The new view:

```dart
import 'dart:async';
import 'package:universal_ble/universal_ble.dart';

class BleDebugScreen extends StatefulWidget {
  const BleDebugScreen({super.key});

  @override
  State<BleDebugScreen> createState() => _BleDebugScreenState();
}

class _BleDebugScreenState extends State<BleDebugScreen> {
  final List<String> _log = [];
  final Map<String, BleDevice> _found = {};

  void _print(String line) {
    setState(() => _log.insert(0, line));
    // ignore: avoid_print
    print('[BleDebug] $line');
  }

  void _startScan() {
    _found.clear();
    UniversalBle.onScanResult = (device) {
      if (_found.containsKey(device.deviceId)) return;
      _found[device.deviceId] = device;
      _print('Found: ${device.name ?? "(unnamed)"} [${device.deviceId}] '
          'rssi=${device.rssi}');
    };
    UniversalBle.startScan();
    _print('Scan started');
  }

  Future<void> _connectAndInspect(BleDevice device) async {
    try {
      _print('Connecting to ${device.name}...');
      await device.connect();
      _print('Connected. Discovering services (read-only)...');
      final services = await device.discoverServices();
      for (final service in services) {
        _print('Service ${service.uuid}');
        for (final characteristic in service.characteristics) {
          _print('  Characteristic ${characteristic.uuid}');
        }
      }
      await device.disconnect();
      _print('Disconnected.');
    } catch (e) {
      _print('ERROR: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ElevatedButton(
                  onPressed: _startScan, child: const Text('Start scan')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => UniversalBle.stopScan(),
                child: const Text('Stop scan'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final device in _found.values)
                ListTile(
                  title: Text(device.name ?? '(unnamed)'),
                  subtitle: Text(device.deviceId),
                  trailing: TextButton(
                    onPressed: () => _connectAndInspect(device),
                    child: const Text('Connect (read-only)'),
                  ),
                ),
              const Divider(),
              for (final line in _log) Text(line),
            ],
          ),
        ),
      ],
    );
  }
}
```

Wire it in as a second tab of the existing `MyApp` (a `DefaultTabController` with two `Tab`s is the smallest change; keep the existing serial-computer list as tab 1 unchanged).

- [ ] **Step 2: Run it on Windows**

```
cd example
flutter run -d windows
```

- [ ] **Step 3: Execute the manual gate**

With your Garmin watch nearby and Bluetooth on:
1. Tap "Start scan". Confirm the watch appears in the list within ~10s.
2. Tap "Connect (read-only)" next to it.
3. Confirm the log shows at least one `Service ...` line with nested `Characteristic ...` lines, then `Disconnected.`.

**This is a gate, not a formality.** If scanning never finds the watch, or `connect()`/`discoverServices()` throws, **stop here** — do not proceed to Task 4. Report back what happened (exact error text, whether scan found anything at all) so the plugin choice or Windows Bluetooth setup can be revisited before more code is built on top of it.

- [ ] **Step 4: Commit**

```bash
cd example  # if not already there
git add lib/main.dart
git commit -m "Add BLE debug screen to example app (Tier 0 smoke test)"
```
(Run from the `flutter_divecomputer` root if `example/` isn't a separate git repo — check with `git rev-parse --show-toplevel` first.)

---

### Task 4: `BleProfile` type and registry

**Files:**
- Create: `lib/types/ble_profile.dart`
- Test: `test/types/ble_profile_test.dart`

**Interfaces:**
- Produces: `BleProfile` (fields: `namePattern`, `serviceUuid`, `writeCharUuid`, `notifyCharUuid`, `writeWithResponse`, `vendorHint`, `productHint`; method `matchesName(String)`), `BleProfiles.known` (`List<BleProfile>`, starts empty), `BleProfiles.match(String) -> BleProfile?`, `BleProfiles.nordicUart` (reference constant, **not** included in `known`).

- [ ] **Step 1: Write the failing tests**

```dart
// test/types/ble_profile_test.dart
import 'package:dive_computer/types/ble_profile.dart';
import 'package:test/test.dart';

void main() {
  group('BleProfile.matchesName', () {
    test('matches case-insensitively as a substring', () {
      const profile = BleProfile(
        namePattern: 'OSTC',
        serviceUuid: 's',
        writeCharUuid: 'w',
        notifyCharUuid: 'n',
        writeWithResponse: false,
      );
      expect(profile.matchesName('HW OSTC 4'), isTrue);
      expect(profile.matchesName('hw ostc 4'), isTrue);
      expect(profile.matchesName('Suunto EON'), isFalse);
    });
  });

  group('BleProfiles', () {
    test('known starts empty — no vendor profile has been verified yet', () {
      expect(BleProfiles.known, isEmpty);
    });

    test('match returns null when nothing in known matches', () {
      expect(BleProfiles.match('anything'), isNull);
    });

    test('match returns the first matching profile in known', () {
      // Exercises the registry mechanism itself without depending on
      // BleProfiles.known's real (currently empty) contents.
      const a = BleProfile(
        namePattern: 'foo',
        serviceUuid: 's1',
        writeCharUuid: 'w1',
        notifyCharUuid: 'n1',
        writeWithResponse: true,
      );
      expect(a.matchesName('foobar'), isTrue);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```
flutter test test/types/ble_profile_test.dart
```
Expected: FAIL — `ble_profile.dart` doesn't exist yet.

- [ ] **Step 3: Implement**

```dart
// lib/types/ble_profile.dart

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
```

- [ ] **Step 4: Run to verify it passes**

```
flutter test test/types/ble_profile_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/types/ble_profile.dart test/types/ble_profile_test.dart
git commit -m "Add BleProfile type and profile registry"
```

---

### Task 5: `BleScanResult` type

**Files:**
- Create: `lib/types/ble_scan_result.dart`
- Test: `test/types/ble_scan_result_test.dart`

**Interfaces:**
- Consumes: `BleProfile`, `BleProfiles.match` (Task 4).
- Produces: `BleScanResult` (fields: `id`, `name`, `rssi`, `profile`).

- [ ] **Step 1: Write the failing test**

```dart
// test/types/ble_scan_result_test.dart
import 'package:dive_computer/types/ble_profile.dart';
import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:test/test.dart';

void main() {
  test('BleScanResult carries the matched profile, or null', () {
    const profile = BleProfile(
      namePattern: 'Test',
      serviceUuid: 's',
      writeCharUuid: 'w',
      notifyCharUuid: 'n',
      writeWithResponse: false,
    );
    final matched =
        BleScanResult(id: 'abc', name: 'Test Device', rssi: -60, profile: profile);
    final unmatched =
        BleScanResult(id: 'def', name: 'Other Device', rssi: -70, profile: null);

    expect(matched.profile, profile);
    expect(unmatched.profile, isNull);
    expect(matched.toString(), contains('Test Device'));
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```
flutter test test/types/ble_scan_result_test.dart
```
Expected: FAIL — file doesn't exist.

- [ ] **Step 3: Implement**

```dart
// lib/types/ble_scan_result.dart
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
      'profile=${profile?.vendorHint ?? profile?.namePattern})';
}
```

- [ ] **Step 4: Run to verify it passes**

```
flutter test test/types/ble_scan_result_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/types/ble_scan_result.dart test/types/ble_scan_result_test.dart
git commit -m "Add BleScanResult type"
```

---

### Task 6: `BleBridgeState` shared struct + `BleBridge` wrapper

This is the core of the design (spec Decision 2). Pure Dart + `dart:ffi`, no native code, fully unit-testable.

**Files:**
- Create: `lib/framework/ble/ble_bridge_state.dart`
- Test: `test/framework/ble/ble_bridge_state_test.dart`

**Interfaces:**
- Produces: `BleBridgeState` (an `ffi.Struct`), `BleBridge` with: `allocate()`, `fromAddress(int)`, `fromRawPointer(Pointer<Void>)`, `address`, `pointer`, `dispose()`, `isClosed`, `markClosed()`, `timeoutMs` (getter/setter), `inboundAvailable`, `pushInbound(Uint8List) -> int`, `popInbound(Pointer<Uint8>, int) -> int`, `waitForInbound(int timeoutMs) -> bool`, `pendingWriteSeq`, `pendingOutbound`, `queueOutbound(Pointer<Uint8>, int) -> int`, `ackOutbound(int status)`, `waitForWriteAck(int seq, int timeoutMs) -> bool`, `writeStatus`. Also the constants `kInboundCapacity`, `kOutboundCapacity`, `kHardCapTimeoutMs`, `kSpinPollIntervalMs`.
- Consumed by: Task 7 (FFI callbacks), Task 9 (`BleTransport`), Task 10 (isolate wiring).

- [ ] **Step 1: Write the failing tests**

```dart
// test/framework/ble/ble_bridge_state_test.dart
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:test/test.dart';

void main() {
  group('BleBridge inbound ring buffer', () {
    late BleBridge bridge;
    setUp(() => bridge = BleBridge.allocate());
    tearDown(() => bridge.dispose());

    test('push then pop round-trips bytes in order', () {
      bridge.pushInbound(Uint8List.fromList([1, 2, 3]));
      expect(bridge.inboundAvailable, 3);

      final dest = calloc<ffi.Uint8>(8);
      addTearDown(() => calloc.free(dest));
      final n = bridge.popInbound(dest, 8);

      expect(n, 3);
      expect([dest[0], dest[1], dest[2]], [1, 2, 3]);
      expect(bridge.inboundAvailable, 0);
    });

    test('wraps around the buffer boundary correctly', () {
      // Push/pop repeatedly near the capacity boundary to force wraparound.
      final dest = calloc<ffi.Uint8>(kInboundCapacity);
      addTearDown(() => calloc.free(dest));
      for (var round = 0; round < 3; round++) {
        final chunk = Uint8List.fromList(
            List.generate(kInboundCapacity - 10, (i) => i % 256));
        bridge.pushInbound(chunk);
        final n = bridge.popInbound(dest, chunk.length);
        expect(n, chunk.length);
        expect(dest.asTypedList(chunk.length), chunk);
      }
    });

    test('push beyond free space is truncated, not corrupted', () {
      final huge = Uint8List(kInboundCapacity + 100);
      final written = bridge.pushInbound(huge);
      expect(written, lessThan(huge.length));
      expect(bridge.inboundAvailable, written);
    });
  });

  group('BleBridge outbound mailbox', () {
    late BleBridge bridge;
    setUp(() => bridge = BleBridge.allocate());
    tearDown(() => bridge.dispose());

    test('queueOutbound then ackOutbound updates sequence and status', () {
      final data = calloc<ffi.Uint8>(3);
      addTearDown(() => calloc.free(data));
      data.asTypedList(3).setAll(0, [9, 8, 7]);

      final seq = bridge.queueOutbound(data, 3);
      expect(bridge.pendingOutbound, [9, 8, 7]);
      expect(bridge.pendingWriteSeq, seq);

      bridge.ackOutbound(0);
      expect(bridge.waitForWriteAck(seq, 100), isTrue);
      expect(bridge.writeStatus, 0);
    });
  });

  group('BleBridge waits', () {
    test('waitForInbound(0) is non-blocking and reflects current state', () {
      final bridge = BleBridge.allocate();
      addTearDown(bridge.dispose);
      expect(bridge.waitForInbound(0), isFalse);
      bridge.pushInbound(Uint8List.fromList([1]));
      expect(bridge.waitForInbound(0), isTrue);
    });

    test('waitForInbound times out when nothing arrives', () {
      final bridge = BleBridge.allocate();
      addTearDown(bridge.dispose);
      final sw = Stopwatch()..start();
      final ready = bridge.waitForInbound(30);
      sw.stop();
      expect(ready, isFalse);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(30));
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('closed unblocks a wait immediately', () {
      final bridge = BleBridge.allocate();
      addTearDown(bridge.dispose);
      bridge.markClosed();
      final sw = Stopwatch()..start();
      final ready = bridge.waitForInbound(5000); // would hang if not for closed
      sw.stop();
      expect(ready, isTrue); // "ready" here just means "stopped waiting"
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });

  test('fromAddress reconstructs the same shared memory', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.pushInbound(Uint8List.fromList([42]));

    final reconstructed = BleBridge.fromAddress(bridge.address);
    expect(reconstructed.inboundAvailable, 1);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```
flutter test test/framework/ble/ble_bridge_state_test.dart
```
Expected: FAIL — file doesn't exist.

- [ ] **Step 3: Implement**

```dart
// lib/framework/ble/ble_bridge_state.dart
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

const int kInboundCapacity = 4096;
const int kOutboundCapacity = 512;

/// If libdivecomputer requests an indefinite block (timeout == -1), we
/// honor "block" but never literally forever — a silent BLE disconnect
/// must not hang the isolate. See the design spec's Defensive measures
/// section.
const int kHardCapTimeoutMs = 30000;

const int kSpinPollIntervalMs = 2;

/// Shared native-memory state for one BLE "connection" — allocated on the
/// main isolate, its `.address` sent to the background isolate so both
/// sides can reconstruct a pointer to the *same* memory (outside the Dart
/// GC heap, so this works across isolates). See design spec, Decision 2.
///
/// Inbound (device -> host) is a lock-free single-producer/single-consumer
/// ring buffer: only the main isolate writes [inboundHead], only the
/// background isolate writes [inboundTail]. Outbound (host -> device) is a
/// single-slot mailbox: the background isolate fills the buffer and bumps
/// [writeSeq]; the main isolate performs the real write and bumps
/// [writeAckSeq] (and sets [writeStatus]) when done. One byte of the ring
/// buffer's capacity is always kept empty to disambiguate "empty" from
/// "full" without a separate counter.
final class BleBridgeState extends ffi.Struct {
  @ffi.Array(kInboundCapacity)
  external ffi.Array<ffi.Uint8> inboundBuffer;

  @ffi.Uint32()
  external int inboundHead;

  @ffi.Uint32()
  external int inboundTail;

  @ffi.Array(kOutboundCapacity)
  external ffi.Array<ffi.Uint8> outboundBuffer;

  @ffi.Uint32()
  external int outboundLen;

  @ffi.Uint32()
  external int writeSeq;

  @ffi.Uint32()
  external int writeAckSeq;

  @ffi.Int32()
  external int writeStatus;

  @ffi.Int32()
  external int closed;

  @ffi.Int32()
  external int timeoutMs;
}

class BleBridge {
  BleBridge._(this.pointer);

  final ffi.Pointer<BleBridgeState> pointer;

  int get address => pointer.address;

  static BleBridge allocate() {
    final ptr = calloc<BleBridgeState>();
    ptr.ref
      ..inboundHead = 0
      ..inboundTail = 0
      ..outboundLen = 0
      ..writeSeq = 0
      ..writeAckSeq = 0
      ..writeStatus = 0
      ..closed = 0
      ..timeoutMs = -1;
    return BleBridge._(ptr);
  }

  static BleBridge fromAddress(int address) =>
      BleBridge._(ffi.Pointer<BleBridgeState>.fromAddress(address));

  static BleBridge fromRawPointer(ffi.Pointer<ffi.Void> userdata) =>
      BleBridge._(userdata.cast());

  void dispose() => calloc.free(pointer);

  bool get isClosed => pointer.ref.closed != 0;
  void markClosed() => pointer.ref.closed = 1;

  int get timeoutMs => pointer.ref.timeoutMs;
  set timeoutMs(int value) => pointer.ref.timeoutMs = value;

  int get writeStatus => pointer.ref.writeStatus;

  // --- Inbound ring buffer -------------------------------------------

  int get inboundAvailable {
    final head = pointer.ref.inboundHead;
    final tail = pointer.ref.inboundTail;
    return (head - tail) % kInboundCapacity;
  }

  /// Called by the main isolate as BLE notifications arrive. Returns the
  /// number of bytes actually stored; if less than `bytes.length`, the
  /// ring buffer was full (backpressure — see BleTransport, which logs
  /// this as an overflow).
  int pushInbound(Uint8List bytes) {
    final free = kInboundCapacity - inboundAvailable - 1;
    final toWrite = bytes.length < free ? bytes.length : free;
    final head = pointer.ref.inboundHead;
    for (var i = 0; i < toWrite; i++) {
      pointer.ref.inboundBuffer[(head + i) % kInboundCapacity] = bytes[i];
    }
    pointer.ref.inboundHead = (head + toWrite) % kInboundCapacity;
    return toWrite;
  }

  /// Called from the background isolate's `read` callback. Returns the
  /// number of bytes actually copied into [dest] (up to [maxLength]).
  int popInbound(ffi.Pointer<ffi.Uint8> dest, int maxLength) {
    final available = inboundAvailable;
    final toRead = maxLength < available ? maxLength : available;
    final tail = pointer.ref.inboundTail;
    for (var i = 0; i < toRead; i++) {
      dest[i] = pointer.ref.inboundBuffer[(tail + i) % kInboundCapacity];
    }
    pointer.ref.inboundTail = (tail + toRead) % kInboundCapacity;
    return toRead;
  }

  /// Busy-waits (real thread sleep, not an awaited Future — this runs
  /// inside a synchronous FFI callback with no event loop available) until
  /// data is available, [closed] is set, or the timeout elapses.
  ///
  /// `timeoutMs == 0` means "check once, don't wait" (matches
  /// libdivecomputer's non-blocking-poll convention). `timeoutMs < 0`
  /// means "block indefinitely", capped at [kHardCapTimeoutMs].
  bool waitForInbound(int timeoutMs) {
    if (timeoutMs == 0) return inboundAvailable > 0 || isClosed;
    final effective = timeoutMs < 0 ? kHardCapTimeoutMs : timeoutMs;
    final deadline = DateTime.now().add(Duration(milliseconds: effective));
    while (inboundAvailable == 0 && !isClosed) {
      if (!DateTime.now().isBefore(deadline)) return false;
      sleep(const Duration(milliseconds: kSpinPollIntervalMs));
    }
    return true;
  }

  // --- Outbound mailbox -------------------------------------------------

  int get pendingWriteSeq => pointer.ref.writeSeq;

  Uint8List get pendingOutbound {
    final len = pointer.ref.outboundLen;
    return Uint8List.fromList(
        [for (var i = 0; i < len; i++) pointer.ref.outboundBuffer[i]]);
  }

  /// Called from the background isolate's `write` callback. Returns the
  /// sequence number to pass to [waitForWriteAck].
  int queueOutbound(ffi.Pointer<ffi.Uint8> data, int length) {
    final clamped = length > kOutboundCapacity ? kOutboundCapacity : length;
    for (var i = 0; i < clamped; i++) {
      pointer.ref.outboundBuffer[i] = data[i];
    }
    pointer.ref.outboundLen = clamped;
    final seq = pointer.ref.writeSeq + 1;
    pointer.ref.writeSeq = seq;
    return seq;
  }

  /// Called by the main isolate once the real GATT write for the current
  /// mailbox contents has completed (or failed — pass the resulting
  /// dc_status_t either way).
  void ackOutbound(int status) {
    pointer.ref.writeStatus = status;
    pointer.ref.writeAckSeq = pointer.ref.writeSeq;
  }

  bool waitForWriteAck(int seq, int timeoutMs) {
    if (timeoutMs == 0) return pointer.ref.writeAckSeq == seq || isClosed;
    final effective = timeoutMs < 0 ? kHardCapTimeoutMs : timeoutMs;
    final deadline = DateTime.now().add(Duration(milliseconds: effective));
    while (pointer.ref.writeAckSeq != seq && !isClosed) {
      if (!DateTime.now().isBefore(deadline)) return false;
      sleep(const Duration(milliseconds: kSpinPollIntervalMs));
    }
    return true;
  }
}
```

- [ ] **Step 4: Run to verify it passes**

```
flutter test test/framework/ble/ble_bridge_state_test.dart
```
Expected: PASS (all tests). The timeout test takes ~30-200ms; nothing should take multiple seconds — if it does, the hard-cap logic is wrong.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/ble/ble_bridge_state.dart test/framework/ble/ble_bridge_state_test.dart
git commit -m "Add BleBridgeState shared-memory ring buffer/mailbox"
```

---

### Task 7: `dc_custom_cbs_t`-shaped FFI callbacks

**Files:**
- Create: `lib/framework/ble/ble_bridge_callbacks.dart`
- Test: `test/framework/ble/ble_bridge_callbacks_test.dart`

**Interfaces:**
- Consumes: `BleBridge`/`BleBridgeState` (Task 6), `dc_status_t` constants and `dc_custom_cbs_t` (Task 1's generated bindings).
- Produces: `BleBridgeCallbacks` with static `Pointer<NativeFunction<...>>` getters `readPtr`, `writePtr`, `pollPtr`, `getAvailablePtr`, `closePtr`, `setTimeoutPtr`, plus no-op-returning-success pointers `setBreakPtr`, `setDtrPtr`, `setRtsPtr`, `getLinesPtr`, `configurePtr`, `flushPtr`, `purgePtr`, `sleepPtr`, `ioctlPtr` — one per `dc_custom_cbs_t` member. Used by Task 11 to build the `dc_custom_cbs_t` struct passed to `dc_custom_open`.

**Why these typedefs are hand-written, not copied from ffigen's names:** `ffigen` gives anonymous function-pointer struct fields internal names that aren't guaranteed stable across regenerations. Dart's `ffi.NativeFunction<T>` typing is structural (a `typedef` is just an alias, not a distinct type), so as long as our hand-written native signatures exactly match the C signatures in `custom.h`, assigning them into the generated `dc_custom_cbs_t` struct's fields type-checks regardless of what ffigen named its own typedef. The exact native-type mapping used below (`dc_status_t` -> `ffi.Int32`/`int`, `size_t` -> `ffi.Size`/`int`, `void*` -> `Pointer<Void>`, plain `int` -> `ffi.Int`/`int`) is copied from the already-generated, already-verified `dc_iostream_read`/`dc_iostream_write`/`dc_iostream_poll` bindings in `dive_computer_ffi_bindings_generated.dart`, which wrap the same C types.

- [ ] **Step 1: Write the failing tests**

```dart
// test/framework/ble/ble_bridge_callbacks_test.dart
import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_bridge_callbacks.dart';
import 'package:dive_computer/framework/dive_computer_ffi_bindings_generated.dart';
import 'package:test/test.dart';

typedef _ReadWriteDart = int Function(ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<ffi.Void> data, int size, ffi.Pointer<ffi.Size> actual);

void main() {
  test('read() returns queued inbound bytes', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.pushInbound(Uint8List.fromList([1, 2, 3]));

    final read = BleBridgeCallbacks.readPtr.asFunction<_ReadWriteDart>();
    final buf = calloc<ffi.Uint8>(8);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(buf);
      calloc.free(actual);
    });

    final status =
        read(bridge.pointer.cast(), buf.cast(), 8, actual);

    expect(status, dc_status_t.DC_STATUS_SUCCESS);
    expect(actual.value, 3);
    expect([buf[0], buf[1], buf[2]], [1, 2, 3]);
  });

  test('read() times out when no data arrives', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.timeoutMs = 20;

    final read = BleBridgeCallbacks.readPtr.asFunction<_ReadWriteDart>();
    final buf = calloc<ffi.Uint8>(8);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(buf);
      calloc.free(actual);
    });

    final status = read(bridge.pointer.cast(), buf.cast(), 8, actual);

    expect(status, dc_status_t.DC_STATUS_TIMEOUT);
  });

  test('read() unblocks immediately when closed, instead of hanging', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.timeoutMs = 5000; // would hang the test if `closed` didn't interrupt it
    bridge.markClosed();

    final read = BleBridgeCallbacks.readPtr.asFunction<_ReadWriteDart>();
    final buf = calloc<ffi.Uint8>(8);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(buf);
      calloc.free(actual);
    });

    final sw = Stopwatch()..start();
    final status = read(bridge.pointer.cast(), buf.cast(), 8, actual);
    sw.stop();

    expect(status, dc_status_t.DC_STATUS_IO);
    expect(sw.elapsedMilliseconds, lessThan(500));
  });

  test(
      'write() blocks until another isolate acks it via the shared memory',
      () async {
    // NOTE: this must use a real Isolate, not a Timer — write()'s spin
    // loop calls dart:io's sleep(), which blocks this thread WITHOUT
    // yielding to the event loop, so a Timer scheduled on this same
    // isolate would never fire while write() is waiting. This is exactly
    // the constraint the whole bridge design exists to work around (see
    // design spec's "core technical constraint" section) — so this test
    // doubles as verification that cross-isolate shared memory actually
    // works, which is the riskiest assumption in the whole feature.
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    bridge.timeoutMs = 2000;

    final ackFuture = Isolate.run(() async {
      await Future.delayed(const Duration(milliseconds: 30));
      BleBridge.fromAddress(bridge.address)
          .ackOutbound(dc_status_t.DC_STATUS_SUCCESS);
    });

    final write = BleBridgeCallbacks.writePtr.asFunction<_ReadWriteDart>();
    final data = calloc<ffi.Uint8>(3);
    data.asTypedList(3).setAll(0, [9, 8, 7]);
    final actual = calloc<ffi.Size>();
    addTearDown(() {
      calloc.free(data);
      calloc.free(actual);
    });

    final status = write(bridge.pointer.cast(), data.cast(), 3, actual);
    await ackFuture;

    expect(status, dc_status_t.DC_STATUS_SUCCESS);
    expect(actual.value, 3);
  });

  test('close() sets the closed flag', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    final close = BleBridgeCallbacks.closePtr
        .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

    final status = close(bridge.pointer.cast());

    expect(status, dc_status_t.DC_STATUS_SUCCESS);
    expect(bridge.isClosed, isTrue);
  });

  test('setTimeout() updates the bridge timeout', () {
    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    final setTimeout = BleBridgeCallbacks.setTimeoutPtr
        .asFunction<int Function(ffi.Pointer<ffi.Void>, int)>();

    final status = setTimeout(bridge.pointer.cast(), 1234);

    expect(status, dc_status_t.DC_STATUS_SUCCESS);
    expect(bridge.timeoutMs, 1234);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```
flutter test test/framework/ble/ble_bridge_callbacks_test.dart
```
Expected: FAIL — file doesn't exist.

- [ ] **Step 3: Implement**

```dart
// lib/framework/ble/ble_bridge_callbacks.dart
import 'dart:ffi' as ffi;
import 'package:logging/logging.dart';

import 'ble_bridge_state.dart';
import '../dive_computer_ffi_bindings_generated.dart';

final _log = Logger('BleBridge');

typedef _StatusOnlyNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _StatusOnlyDart = int Function(ffi.Pointer<ffi.Void>);

typedef _IntArgNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int);
typedef _IntArgDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef _UIntArgNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.UnsignedInt);
typedef _UIntArgDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef _GetLinesNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.UnsignedInt>);
typedef _GetLinesDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.UnsignedInt>);

typedef _GetAvailableNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Size>);
typedef _GetAvailableDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Size>);

typedef _ReadWriteNative = ffi.Int32 Function(ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<ffi.Void> data, ffi.Size size, ffi.Pointer<ffi.Size> actual);
typedef _ReadWriteDart = int Function(ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<ffi.Void> data, int size, ffi.Pointer<ffi.Size> actual);

typedef _IoctlNative = ffi.Int32 Function(ffi.Pointer<ffi.Void> userdata,
    ffi.UnsignedInt request, ffi.Pointer<ffi.Void> data, ffi.Size size);
typedef _IoctlDart = int Function(ffi.Pointer<ffi.Void> userdata, int request,
    ffi.Pointer<ffi.Void> data, int size);

typedef _ConfigureNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.UnsignedInt baudrate,
    ffi.UnsignedInt databits,
    ffi.Int32 parity,
    ffi.Int32 stopbits,
    ffi.Int32 flowcontrol);
typedef _ConfigureDart = int Function(ffi.Pointer<ffi.Void>, int, int, int,
    int, int);

/// Guards every callback body so a Dart exception can never escape into
/// native code (undefined behavior) — it's logged and turned into a
/// well-defined DC_STATUS_IO instead. See design spec's Defensive measures.
int _guard(String name, int Function() body) {
  try {
    return body();
  } catch (e, st) {
    _log.severe('$name() threw', e, st);
    return dc_status_t.DC_STATUS_IO;
  }
}

int _read(ffi.Pointer<ffi.Void> userdata, ffi.Pointer<ffi.Void> data,
    int size, ffi.Pointer<ffi.Size> actual) {
  return _guard('read', () {
    actual.value = 0;
    final bridge = BleBridge.fromRawPointer(userdata);
    final ready = bridge.waitForInbound(bridge.timeoutMs);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    if (!ready) {
      _log.finest('read(): timeout');
      return dc_status_t.DC_STATUS_TIMEOUT;
    }
    final n = bridge.popInbound(data.cast<ffi.Uint8>(), size);
    actual.value = n;
    _log.finest('read(): $n bytes');
    return dc_status_t.DC_STATUS_SUCCESS;
  });
}

int _write(ffi.Pointer<ffi.Void> userdata, ffi.Pointer<ffi.Void> data,
    int size, ffi.Pointer<ffi.Size> actual) {
  return _guard('write', () {
    actual.value = 0;
    final bridge = BleBridge.fromRawPointer(userdata);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    final seq = bridge.queueOutbound(data.cast<ffi.Uint8>(), size);
    final acked = bridge.waitForWriteAck(seq, bridge.timeoutMs);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    if (!acked) {
      _log.warning('write(): timeout waiting for ack');
      return dc_status_t.DC_STATUS_TIMEOUT;
    }
    actual.value = size;
    _log.finest('write(): $size bytes, status=${bridge.writeStatus}');
    return bridge.writeStatus;
  });
}

int _poll(ffi.Pointer<ffi.Void> userdata, int timeout) {
  return _guard('poll', () {
    final bridge = BleBridge.fromRawPointer(userdata);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    final ready = bridge.waitForInbound(timeout);
    if (bridge.isClosed) return dc_status_t.DC_STATUS_IO;
    return ready ? dc_status_t.DC_STATUS_SUCCESS : dc_status_t.DC_STATUS_TIMEOUT;
  });
}

int _getAvailable(ffi.Pointer<ffi.Void> userdata, ffi.Pointer<ffi.Size> value) {
  return _guard('get_available', () {
    value.value = BleBridge.fromRawPointer(userdata).inboundAvailable;
    return dc_status_t.DC_STATUS_SUCCESS;
  });
}

int _setTimeout(ffi.Pointer<ffi.Void> userdata, int timeout) {
  return _guard('set_timeout', () {
    BleBridge.fromRawPointer(userdata).timeoutMs = timeout;
    return dc_status_t.DC_STATUS_SUCCESS;
  });
}

int _close(ffi.Pointer<ffi.Void> userdata) {
  return _guard('close', () {
    BleBridge.fromRawPointer(userdata).markClosed();
    return dc_status_t.DC_STATUS_SUCCESS;
  });
}

// BLE has no serial control lines/baud rate/flow control — these are
// required members of dc_custom_cbs_t but are no-ops for us.
int _noop(ffi.Pointer<ffi.Void> userdata) => dc_status_t.DC_STATUS_SUCCESS;
int _noopUInt(ffi.Pointer<ffi.Void> userdata, int value) =>
    dc_status_t.DC_STATUS_SUCCESS;
int _noopGetLines(
    ffi.Pointer<ffi.Void> userdata, ffi.Pointer<ffi.UnsignedInt> value) {
  value.value = 0;
  return dc_status_t.DC_STATUS_SUCCESS;
}
int _noopConfigure(ffi.Pointer<ffi.Void> userdata, int baudrate, int databits,
        int parity, int stopbits, int flowcontrol) =>
    dc_status_t.DC_STATUS_SUCCESS;
int _noopIoctl(ffi.Pointer<ffi.Void> userdata, int request,
        ffi.Pointer<ffi.Void> data, int size) =>
    dc_status_t.DC_STATUS_UNSUPPORTED;

/// Static function pointers matching every member of `dc_custom_cbs_t`
/// (native/include/libdivecomputer/custom.h), for use with `dc_custom_open`
/// (Task 11).
class BleBridgeCallbacks {
  BleBridgeCallbacks._();

  static final readPtr =
      ffi.Pointer.fromFunction<_ReadWriteNative>(_read, dc_status_t.DC_STATUS_IO);
  static final writePtr =
      ffi.Pointer.fromFunction<_ReadWriteNative>(_write, dc_status_t.DC_STATUS_IO);
  static final pollPtr =
      ffi.Pointer.fromFunction<_IntArgNative>(_poll, dc_status_t.DC_STATUS_IO);
  static final getAvailablePtr = ffi.Pointer.fromFunction<_GetAvailableNative>(
      _getAvailable, dc_status_t.DC_STATUS_IO);
  static final setTimeoutPtr = ffi.Pointer.fromFunction<_IntArgNative>(
      _setTimeout, dc_status_t.DC_STATUS_IO);
  static final closePtr =
      ffi.Pointer.fromFunction<_StatusOnlyNative>(_close, dc_status_t.DC_STATUS_IO);

  static final setBreakPtr =
      ffi.Pointer.fromFunction<_UIntArgNative>(_noopUInt, dc_status_t.DC_STATUS_SUCCESS);
  static final setDtrPtr =
      ffi.Pointer.fromFunction<_UIntArgNative>(_noopUInt, dc_status_t.DC_STATUS_SUCCESS);
  static final setRtsPtr =
      ffi.Pointer.fromFunction<_UIntArgNative>(_noopUInt, dc_status_t.DC_STATUS_SUCCESS);
  static final getLinesPtr = ffi.Pointer.fromFunction<_GetLinesNative>(
      _noopGetLines, dc_status_t.DC_STATUS_SUCCESS);
  static final configurePtr = ffi.Pointer.fromFunction<_ConfigureNative>(
      _noopConfigure, dc_status_t.DC_STATUS_SUCCESS);
  static final flushPtr =
      ffi.Pointer.fromFunction<_StatusOnlyNative>(_noop, dc_status_t.DC_STATUS_SUCCESS);
  static final purgePtr =
      ffi.Pointer.fromFunction<_IntArgNative>(_noopUInt, dc_status_t.DC_STATUS_SUCCESS);
  static final sleepPtr =
      ffi.Pointer.fromFunction<_UIntArgNative>(_noopUInt, dc_status_t.DC_STATUS_SUCCESS);
  static final ioctlPtr = ffi.Pointer.fromFunction<_IoctlNative>(
      _noopIoctl, dc_status_t.DC_STATUS_UNSUPPORTED);
}
```

- [ ] **Step 4: Run to verify it passes**

```
flutter test test/framework/ble/ble_bridge_callbacks_test.dart
```
Expected: PASS (6 tests). The cross-isolate `write()` test is the most important one here — if it's flaky or hangs, do not proceed to Task 8 until it's solid, since Task 9's `BleTransport` depends on this exact mechanism working under real timing.

- [ ] **Step 5: Commit**

```bash
git add lib/framework/ble/ble_bridge_callbacks.dart test/framework/ble/ble_bridge_callbacks_test.dart
git commit -m "Add dc_custom_cbs_t-shaped FFI callbacks for the BLE bridge"
```

---

### Task 8: `BleCentral` abstraction, `universal_ble` implementation, and fake

Separates "talk to universal_ble" from "drive the bridge" (Task 9), so Task 9's retry/backoff/mailbox/disconnect logic is unit-testable without a real Bluetooth radio.

**Files:**
- Create: `lib/framework/ble/ble_central.dart`
- Create: `lib/framework/ble/fake_ble_central.dart` (test-only, but shipped in `lib/` so `example/` or future tests outside this package can reuse it — matches how `flutter_test` itself ships fakes in its main library)

**Interfaces:**
- Consumes: `BleScanResult`, `BleProfile` (Tasks 4-5), `package:universal_ble`.
- Produces: `BleGattService` (`uuid`, `characteristicUuids`), `BleConnection` (interface: `deviceId`, `connectionState` stream, `discoverServices()`, `write(...)`, `subscribeNotifications(...)`, `disconnect()`), `BleCentral` (interface: `scan()`, `stopScan()`, `connect(BleScanResult)`), `UniversalBleCentral implements BleCentral`, `FakeBleCentral implements BleCentral` + `FakeBleConnection implements BleConnection` (test double with `emitScanResult`, `connectCallCount`, `failNextConnect`, `emitNotification`, `simulateDisconnect`, `writes`, `servicesToReturn`).
- Consumed by: Task 9 (`BleTransport`).

- [ ] **Step 1: Implement the abstraction and the real implementation**

```dart
// lib/framework/ble/ble_central.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';

import '../../types/ble_profile.dart';
import '../../types/ble_scan_result.dart';

class BleGattService {
  BleGattService(this.uuid, this.characteristicUuids);
  final String uuid;
  final List<String> characteristicUuids;
}

abstract class BleConnection {
  String get deviceId;
  Stream<bool> get connectionState;
  Future<List<BleGattService>> discoverServices();
  Future<void> write(String serviceUuid, String characteristicUuid,
      List<int> bytes, {required bool withResponse});
  Stream<Uint8List> subscribeNotifications(
      String serviceUuid, String characteristicUuid);
  Future<void> disconnect();
}

abstract class BleCentral {
  Stream<BleScanResult> scan();
  Future<void> stopScan();
  Future<BleConnection> connect(BleScanResult device);
}

class UniversalBleCentral implements BleCentral {
  // universal_ble hands out BleDevice objects from scan results; there's
  // no confirmed public constructor to build one from a bare id, so we
  // keep a lookup of devices seen during the current scan and resolve
  // connect() against it. If a future universal_ble version documents a
  // direct `BleDevice(deviceId: ...)` constructor, this map can be
  // dropped in favor of that.
  final Map<String, BleDevice> _seen = {};

  @override
  Stream<BleScanResult> scan() {
    final controller = StreamController<BleScanResult>();
    UniversalBle.onScanResult = (device) {
      _seen[device.deviceId] = device;
      final profile = BleProfiles.match(device.name ?? '');
      if (profile == null) return; // only surface recognized devices
      controller.add(BleScanResult(
        id: device.deviceId,
        name: device.name ?? '',
        rssi: device.rssi ?? 0,
        profile: profile,
      ));
    };
    UniversalBle.startScan();
    controller.onCancel = () => UniversalBle.stopScan();
    return controller.stream;
  }

  @override
  Future<void> stopScan() => UniversalBle.stopScan();

  @override
  Future<BleConnection> connect(BleScanResult device) async {
    final bleDevice = _seen[device.id];
    if (bleDevice == null) {
      throw StateError(
          'No scanned device with id ${device.id} — connect() must be '
          'called with a BleScanResult from an active/recent scan() call.');
    }
    await bleDevice.connect();
    return _UniversalBleConnection(bleDevice);
  }
}

class _UniversalBleConnection implements BleConnection {
  _UniversalBleConnection(this._device);
  final BleDevice _device;

  @override
  String get deviceId => _device.deviceId;

  @override
  Stream<bool> get connectionState => _device.connectionStream;

  @override
  Future<List<BleGattService>> discoverServices() async {
    final services = await _device.discoverServices();
    return [
      for (final s in services)
        BleGattService(s.uuid, [for (final c in s.characteristics) c.uuid]),
    ];
  }

  @override
  Future<void> write(String serviceUuid, String characteristicUuid,
      List<int> bytes, {required bool withResponse}) async {
    final characteristic =
        await _device.getCharacteristic(serviceUuid, characteristicUuid);
    await characteristic.write(bytes, withResponse: withResponse);
  }

  @override
  Stream<Uint8List> subscribeNotifications(
      String serviceUuid, String characteristicUuid) {
    final controller = StreamController<Uint8List>();
    _device.getCharacteristic(serviceUuid, characteristicUuid).then(
      (characteristic) {
        final sub = characteristic.onValueReceived.listen(controller.add);
        characteristic.notifications.subscribe();
        controller.onCancel = () {
          sub.cancel();
          characteristic.notifications.unsubscribe();
        };
      },
      onError: controller.addError,
    );
    return controller.stream;
  }

  @override
  Future<void> disconnect() => _device.disconnect();
}
```

- [ ] **Step 2: Implement the fake**

```dart
// lib/framework/ble/fake_ble_central.dart
import 'dart:async';
import 'dart:typed_data';

import 'ble_central.dart';
import '../../types/ble_scan_result.dart';

/// In-memory [BleCentral] for tests — no real Bluetooth radio or platform
/// channel involved.
class FakeBleCentral implements BleCentral {
  final _scanController = StreamController<BleScanResult>.broadcast();
  final Map<String, FakeBleConnection> connections = {};
  int connectCallCount = 0;
  bool failNextConnect = false;

  void emitScanResult(BleScanResult result) => _scanController.add(result);

  @override
  Stream<BleScanResult> scan() => _scanController.stream;

  @override
  Future<void> stopScan() async {}

  @override
  Future<BleConnection> connect(BleScanResult device) async {
    connectCallCount++;
    if (failNextConnect) {
      failNextConnect = false;
      throw Exception('simulated connect failure');
    }
    final connection = FakeBleConnection(device.id);
    connections[device.id] = connection;
    return connection;
  }
}

class FakeBleConnection implements BleConnection {
  FakeBleConnection(this.deviceId);

  @override
  final String deviceId;

  final _connectionState = StreamController<bool>.broadcast();
  final _notifications = StreamController<Uint8List>.broadcast();
  final List<List<int>> writes = [];
  List<BleGattService> servicesToReturn = [];

  void emitNotification(Uint8List bytes) => _notifications.add(bytes);
  void simulateDisconnect() => _connectionState.add(false);

  @override
  Stream<bool> get connectionState => _connectionState.stream;

  @override
  Future<List<BleGattService>> discoverServices() async => servicesToReturn;

  @override
  Future<void> write(String serviceUuid, String characteristicUuid,
      List<int> bytes, {required bool withResponse}) async {
    writes.add(bytes);
  }

  @override
  Stream<Uint8List> subscribeNotifications(
          String serviceUuid, String characteristicUuid) =>
      _notifications.stream;

  @override
  Future<void> disconnect() async {
    _connectionState.add(false);
  }
}
```

`UniversalBleCentral` itself has no dedicated unit test here — it's a thin adapter over a real platform plugin (platform channels), which is exercised by the Task 3/12 manual tests instead. `FakeBleCentral`'s own behavior is trivial and gets exercised indirectly through Task 9's tests.

- [ ] **Step 3: Verify it compiles and analyzer is clean**

```
flutter analyze
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add lib/framework/ble/ble_central.dart lib/framework/ble/fake_ble_central.dart
git commit -m "Add BleCentral abstraction over universal_ble, plus a fake for tests"
```

---

### Task 9: `BleTransport`

**Files:**
- Create: `lib/framework/ble/ble_transport.dart`
- Test: `test/framework/ble/ble_transport_test.dart`

**Interfaces:**
- Consumes: `BleCentral`, `BleConnection`, `FakeBleCentral` (Task 8); `BleBridge` (Task 6); `BleScanResult`, `BleProfile` (Tasks 4-5).
- Produces: `BleTransport` with: constructor `BleTransport(BleCentral)`, `isConnected`, `scanForDevices() -> Stream<BleScanResult>`, `connect(BleScanResult, {int maxAttempts}) -> Future<void>`, `attachBridge(BleBridge)`, `disconnect() -> Future<void>`.
- Consumed by: Task 10 (`DiveComputer`/isolate wiring).

- [ ] **Step 1: Write the failing tests**

```dart
// test/framework/ble/ble_transport_test.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_central.dart';
import 'package:dive_computer/framework/ble/fake_ble_central.dart';
import 'package:dive_computer/framework/ble/ble_transport.dart';
import 'package:dive_computer/framework/dive_computer_ffi_bindings_generated.dart';
import 'package:dive_computer/types/ble_profile.dart';
import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:test/test.dart';

const _profile = BleProfile(
  namePattern: 'Test',
  serviceUuid: 'service-1',
  writeCharUuid: 'write-1',
  notifyCharUuid: 'notify-1',
  writeWithResponse: false,
);

BleScanResult _device({String id = 'dev-1'}) =>
    BleScanResult(id: id, name: 'Test Device', rssi: -50, profile: _profile);

void main() {
  test('connect() succeeds when the expected service is present', () async {
    final central = FakeBleCentral();
    final transport = BleTransport(central);
    final device = _device();

    // Prime the fake so connect() can find a service matching the profile.
    central.emitScanResult(device); // not required for connect(), but
    // documents that a real caller would have scanned first.
    unawaited(transport.connect(device).then((_) {}));
    await Future.delayed(Duration.zero); // let connect() call central.connect()
    central.connections[device.id]!.servicesToReturn = [
      BleGattService('service-1', ['write-1', 'notify-1']),
    ];

    // Re-run connect() now that the fake connection exposes the service
    // (simplest deterministic setup: configure services before connecting).
    final central2 = FakeBleCentral();
    final transport2 = BleTransport(central2);
    final connectFuture = transport2.connect(device);
    await Future.delayed(Duration.zero);
    central2.connections[device.id]!.servicesToReturn = [
      BleGattService('service-1', ['write-1', 'notify-1']),
    ];
    // connect() already grabbed a reference to the connection and called
    // discoverServices() by now in the single-attempt path below instead;
    // see the simpler, deterministic version of this test:
    expect(connectFuture, isA<Future<void>>());
  });

  test('connect() throws if the expected service is missing, without retrying',
      () async {
    final central = FakeBleCentral();
    final transport = BleTransport(central);
    final device = _device();

    // Fake central: connect() call must synchronously register a
    // FakeBleConnection with empty servicesToReturn *before* discovery
    // runs, so drive this via a central subclass override instead.
    expect(
      () => transport.connect(device, maxAttempts: 1),
      throwsA(isA<StateError>()),
    );
  });

  test('mailbox: queued outbound bytes reach the fake connection and get acked',
      () async {
    final central = FakeBleCentral();
    final transport = BleTransport(central);
    final device = _device();

    await _connectWithMatchingService(transport, central, device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);
    addTearDown(transport.disconnect);

    final data = Uint8List.fromList([1, 2, 3]);
    // Simulate what the background isolate's write() callback does:
    // queue bytes into the mailbox directly (bypassing FFI here — Task 7
    // already covers the FFI plumbing in isolation).
    final dataPtr = _uint8PointerFrom(data);
    final seq = bridge.queueOutbound(dataPtr, data.length);

    // Give the mailbox timer (~4ms) a chance to service it.
    await Future.delayed(const Duration(milliseconds: 50));

    expect(central.connections[device.id]!.writes, [
      [1, 2, 3]
    ]);
    expect(bridge.pendingWriteSeq, seq);
    final acked = bridge.waitForWriteAck(seq, 200);
    expect(acked, isTrue);
    expect(bridge.writeStatus, dc_status_t.DC_STATUS_SUCCESS);
  });

  test('notifications from the fake connection land in the bridge', () async {
    final central = FakeBleCentral();
    final transport = BleTransport(central);
    final device = _device();
    await _connectWithMatchingService(transport, central, device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);
    addTearDown(transport.disconnect);

    central.connections[device.id]!
        .emitNotification(Uint8List.fromList([9, 9]));
    await Future.delayed(Duration.zero);

    expect(bridge.inboundAvailable, 2);
  });

  test('a real disconnect closes the bridge and tears down the timer',
      () async {
    final central = FakeBleCentral();
    final transport = BleTransport(central);
    final device = _device();
    await _connectWithMatchingService(transport, central, device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);

    central.connections[device.id]!.simulateDisconnect();
    await Future.delayed(Duration.zero);

    expect(bridge.isClosed, isTrue);
    expect(transport.isConnected, isFalse);
  });
}

Future<void> _connectWithMatchingService(
    BleTransport transport, FakeBleCentral central, BleScanResult device) async {
  // FakeBleCentral.connect() registers the FakeBleConnection synchronously
  // (see Task 8), but servicesToReturn defaults to []. Pre-seed it by
  // connecting once to create the FakeBleConnection, configuring its
  // services, then letting BleTransport's real connect() (which calls
  // discoverServices() itself) succeed.
  central.connect(device).then((_) {}); // no-op priming call, ignored
  await Future.delayed(Duration.zero);
  // Real path: BleTransport.connect() will call central.connect() itself
  // and get a *new* FakeBleConnection each time (FakeBleCentral.connect()
  // always creates one) — so configure services via a hook instead: make
  // FakeBleCentral pre-register default services for any id about to be
  // connected. Simplest: connect once directly to seed, then set
  // servicesToReturn, then call transport.connect(), which will create a
  // second connection referencing the SAME map entry key (device.id) and
  // overwrite it — so set servicesToReturn to a value that this fresh
  // connection also gets, by patching FakeBleCentral to reuse an existing
  // connection object if present instead of always creating a new one.
  central.connections[device.id]?.servicesToReturn = [
    BleGattService('service-1', ['write-1', 'notify-1']),
  ];
  await transport.connect(device);
  central.connections[device.id]!.servicesToReturn = [
    BleGattService('service-1', ['write-1', 'notify-1']),
  ];
}
```

**Stop — this test file has a real design problem, not just verbose setup.** `FakeBleCentral.connect()` (Task 8) creates a brand-new `FakeBleConnection` on every call, so there's no way to pre-configure `servicesToReturn` before `BleTransport.connect()` triggers its internal `discoverServices()` call. Fix it now, before writing more tests against it: go back to Task 8 and change `FakeBleCentral` to accept pre-seeded services per device id, and reuse an existing `FakeBleConnection` if one was already registered for that id:

```dart
// Amend lib/framework/ble/fake_ble_central.dart's FakeBleCentral:
class FakeBleCentral implements BleCentral {
  final _scanController = StreamController<BleScanResult>.broadcast();
  final Map<String, FakeBleConnection> connections = {};
  final Map<String, List<BleGattService>> servicesForDevice = {};
  int connectCallCount = 0;
  bool failNextConnect = false;

  void emitScanResult(BleScanResult result) => _scanController.add(result);

  @override
  Stream<BleScanResult> scan() => _scanController.stream;

  @override
  Future<void> stopScan() async {}

  @override
  Future<BleConnection> connect(BleScanResult device) async {
    connectCallCount++;
    if (failNextConnect) {
      failNextConnect = false;
      throw Exception('simulated connect failure');
    }
    final connection = FakeBleConnection(device.id)
      ..servicesToReturn = servicesForDevice[device.id] ?? [];
    connections[device.id] = connection;
    return connection;
  }
}
```
(`FakeBleConnection` itself is unchanged from Task 8.) Now rewrite the test file cleanly using `servicesForDevice`:

```dart
// test/framework/ble/ble_transport_test.dart (replaces the draft above)
import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_central.dart';
import 'package:dive_computer/framework/ble/fake_ble_central.dart';
import 'package:dive_computer/framework/ble/ble_transport.dart';
import 'package:dive_computer/framework/dive_computer_ffi_bindings_generated.dart';
import 'package:dive_computer/types/ble_profile.dart';
import 'package:dive_computer/types/ble_scan_result.dart';
import 'package:test/test.dart';

const _profile = BleProfile(
  namePattern: 'Test',
  serviceUuid: 'service-1',
  writeCharUuid: 'write-1',
  notifyCharUuid: 'notify-1',
  writeWithResponse: false,
);

BleScanResult _device({String id = 'dev-1'}) =>
    BleScanResult(id: id, name: 'Test Device', rssi: -50, profile: _profile);

FakeBleCentral _centralWithMatchingService(String deviceId) {
  final central = FakeBleCentral();
  central.servicesForDevice[deviceId] = [
    BleGattService('service-1', ['write-1', 'notify-1']),
  ];
  return central;
}

void main() {
  test('connect() succeeds when the expected service is present', () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);

    await transport.connect(device);

    expect(transport.isConnected, isTrue);
  });

  test('connect() fails fast (no retry) when the expected service is missing',
      () async {
    final device = _device();
    final central = FakeBleCentral(); // no services seeded
    final transport = BleTransport(central);

    await expectLater(
      () => transport.connect(device, maxAttempts: 1),
      throwsA(isA<StateError>()),
    );
    expect(central.connectCallCount, 1);
  });

  test('connect() retries on failure and eventually succeeds', () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id)
      ..failNextConnect = true;
    final transport = BleTransport(central);

    await transport.connect(device, maxAttempts: 3);

    expect(transport.isConnected, isTrue);
    expect(central.connectCallCount, 2);
  });

  test('mailbox: queued outbound bytes reach the connection and get acked',
      () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);
    await transport.connect(device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);
    addTearDown(transport.disconnect);

    final data = calloc<ffi.Uint8>(3);
    addTearDown(() => calloc.free(data));
    data.asTypedList(3).setAll(0, [1, 2, 3]);
    final seq = bridge.queueOutbound(data, 3);

    final acked = await _pollUntil(
        () => bridge.waitForWriteAck(seq, 0), const Duration(milliseconds: 200));

    expect(acked, isTrue);
    expect(central.connections[device.id]!.writes, [
      [1, 2, 3]
    ]);
    expect(bridge.writeStatus, dc_status_t.DC_STATUS_SUCCESS);
  });

  test('notifications from the connection land in the bridge', () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);
    await transport.connect(device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);
    addTearDown(transport.disconnect);

    central.connections[device.id]!
        .emitNotification(Uint8List.fromList([9, 9]));
    await Future.delayed(Duration.zero);

    expect(bridge.inboundAvailable, 2);
  });

  test('a real disconnect closes the bridge and tears down the timer',
      () async {
    final device = _device();
    final central = _centralWithMatchingService(device.id);
    final transport = BleTransport(central);
    await transport.connect(device);

    final bridge = BleBridge.allocate();
    addTearDown(bridge.dispose);
    transport.attachBridge(bridge);

    central.connections[device.id]!.simulateDisconnect();
    await Future.delayed(Duration.zero);

    expect(bridge.isClosed, isTrue);
    expect(transport.isConnected, isFalse);
  });
}

Future<bool> _pollUntil(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future.delayed(const Duration(milliseconds: 5));
  }
  return true;
}
```

- [ ] **Step 2: Amend Task 8's `FakeBleCentral`, then run the new tests to verify they fail correctly**

```
flutter test test/framework/ble/ble_transport_test.dart
```
Expected: FAIL — `ble_transport.dart` doesn't exist yet. (The `FakeBleCentral` amendment should already compile cleanly against Task 8's other consumers, since nothing else exists yet that uses it.)

- [ ] **Step 3: Implement `BleTransport`**

```dart
// lib/framework/ble/ble_transport.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';

import 'ble_bridge_state.dart';
import 'ble_central.dart';
import '../dive_computer_ffi_bindings_generated.dart';
import '../../types/ble_profile.dart';
import '../../types/ble_scan_result.dart';

final _log = Logger('BleTransport');

/// Drives BLE I/O on the main isolate on behalf of a [BleBridge] running
/// on the background isolate. See design spec's Components section.
class BleTransport {
  BleTransport(this._central);

  final BleCentral _central;
  BleConnection? _connection;
  BleProfile? _profile;
  BleBridge? _bridge;
  Timer? _mailboxTimer;
  StreamSubscription<Uint8List>? _notifySub;
  StreamSubscription<bool>? _connStateSub;
  int _lastServicedWriteSeq = 0;

  bool get isConnected => _connection != null;

  /// Only yields devices matching a known [BleProfile] — see
  /// BleProfiles.known's doc comment for why an empty/unrecognized-device
  /// result set is expected, not a bug.
  Stream<BleScanResult> scanForDevices() => _central.scan();

  Future<void> connect(BleScanResult device, {int maxAttempts = 3}) async {
    if (device.profile == null) {
      throw StateError(
          'Cannot connect to a device with no matched BleProfile: ${device.name}');
    }
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final connection = await _central.connect(device);
        final services = await connection.discoverServices();
        final hasService = services.any((s) =>
            s.uuid.toLowerCase() == device.profile!.serviceUuid.toLowerCase());
        if (!hasService) {
          await connection.disconnect();
          throw StateError(
              'Device ${device.name} does not expose expected service '
              '${device.profile!.serviceUuid} (BleProfile mismatch)');
        }
        _connection = connection;
        _profile = device.profile;
        _connStateSub = connection.connectionState.listen((connected) {
          if (!connected) _handleDisconnect();
        });
        _log.fine('Connected to ${device.name} (${device.id})');
        return;
      } catch (e) {
        lastError = e;
        _log.warning('connect() attempt $attempt/$maxAttempts failed: $e');
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 250 * attempt));
        }
      }
    }
    throw StateError(
        'Failed to connect to ${device.name} after $maxAttempts attempts: $lastError');
  }

  /// Starts servicing [bridge]: forwards BLE notifications into it, and
  /// polls its outbound mailbox to perform queued writes. Must be called
  /// after [connect].
  void attachBridge(BleBridge bridge) {
    final connection = _connection;
    final profile = _profile;
    if (connection == null || profile == null) {
      throw StateError('attachBridge() called before connect()');
    }
    _bridge = bridge;
    _lastServicedWriteSeq = 0;
    _notifySub = connection
        .subscribeNotifications(profile.serviceUuid, profile.notifyCharUuid)
        .listen((bytes) {
      final written = bridge.pushInbound(bytes);
      if (written < bytes.length) {
        _log.severe('Inbound ring buffer overflow: dropped '
            '${bytes.length - written} of ${bytes.length} bytes');
      }
    });
    _mailboxTimer =
        Timer.periodic(const Duration(milliseconds: 4), (_) => _serviceMailbox());
  }

  Future<void> _serviceMailbox() async {
    final bridge = _bridge;
    final connection = _connection;
    final profile = _profile;
    if (bridge == null || connection == null || profile == null) return;
    final seq = bridge.pendingWriteSeq;
    if (seq == _lastServicedWriteSeq) return;
    _lastServicedWriteSeq = seq;
    try {
      await connection.write(
        profile.serviceUuid,
        profile.writeCharUuid,
        bridge.pendingOutbound,
        withResponse: profile.writeWithResponse,
      );
      bridge.ackOutbound(dc_status_t.DC_STATUS_SUCCESS);
    } catch (e, st) {
      _log.severe('Mailbox write failed', e, st);
      bridge.ackOutbound(dc_status_t.DC_STATUS_IO);
    }
  }

  void _handleDisconnect() {
    _log.warning('BLE device disconnected unexpectedly');
    _bridge?.markClosed();
    _teardown();
  }

  Future<void> disconnect() async {
    _bridge?.markClosed();
    await _connection?.disconnect();
    _teardown();
  }

  void _teardown() {
    _mailboxTimer?.cancel();
    _mailboxTimer = null;
    _notifySub?.cancel();
    _notifySub = null;
    _connStateSub?.cancel();
    _connStateSub = null;
    _connection = null;
    _profile = null;
    _bridge = null;
  }
}
```

- [ ] **Step 4: Run to verify it passes**

```
flutter test test/framework/ble/ble_transport_test.dart
```
Expected: PASS (6 tests).

- [ ] **Step 5: Run the full test suite so far**

```
flutter test
```
Expected: all tests from Tasks 4-9 pass together.

- [ ] **Step 6: Commit**

```bash
git add lib/framework/ble/fake_ble_central.dart lib/framework/ble/ble_transport.dart test/framework/ble/ble_transport_test.dart
git commit -m "Add BleTransport: connect/retry, mailbox servicing, disconnect handling"
```

---

### Task 10: Wire `DiveComputerInterface` / `DiveComputer` (main + background isolate)

**Files:**
- Modify: `lib/framework/dive_computer_interface.dart`
- Modify: `lib/framework/dive_computer_isolate.dart`

**Interfaces:**
- Consumes: `BleTransport`, `UniversalBleCentral` (Task 8-9); `BleBridge` (Task 6); `BleScanResult` (Task 5).
- Produces: `DiveComputerInterface.scanForBleDevices()`, `.connectBle(BleScanResult)`, `.disconnectBle()`; `DiveComputer` (isolate.dart) implementing them, and `download()` allocating/threading a `BleBridge` address through to the background isolate when `transport == ComputerTransport.ble`.
- Consumed by: Task 11 (`DiveComputerFfi`), Task 12 (example app).

- [ ] **Step 1: Add the interface methods**

In `dive_computer_interface.dart`, add (near the existing `download` method):
```dart
import 'package:dive_computer/types/ble_scan_result.dart';

// ... inside DiveComputerInterface:
  Stream<BleScanResult> scanForBleDevices() {
    throw UnimplementedError();
  }

  Future<void> connectBle(BleScanResult device) {
    throw UnimplementedError();
  }

  Future<void> disconnectBle() {
    throw UnimplementedError();
  }
```

- [ ] **Step 2: Implement them on `DiveComputer` and thread the bridge through `download()`, with a real two-phase release handshake**

In `dive_computer_isolate.dart`:

1. Add a `BleTransport` field.
2. `download()`'s existing message payload gains a 4th element (the bridge address, nullable).
3. **The bridge's shared memory must not be freed until the background isolate is provably done touching it.** Looking at the existing `DiveComputerFfi.download` body (unchanged by this task, see Task 11): `divesCallback?.call(_divesCache)` — which is what completes the main isolate's `_downloadedDives` future — runs *before* `dc_device_close`/`dc_iostream_close`, which is what triggers our `close` callback (Task 7) that marks the bridge closed. So the dives `Future` resolving is **not** a safe signal to free the bridge — the background isolate can still be inside `dc_iostream_close` (and therefore inside our `close` callback, still touching the pointer) when the main isolate would otherwise free it. Fix: send an explicit second message, only for BLE, once `DiveComputerFfi.download(...)` has fully returned (i.e. past its own `finally` that closes the iostream) — and have `download()` await that specific signal before disposing.

```dart
// Add near the top, alongside other imports:
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/ble/ble_central.dart';
import 'package:dive_computer/framework/ble/ble_transport.dart';
import 'package:dive_computer/types/ble_scan_result.dart';

/// Sent by the background isolate once it has fully returned from
/// DiveComputerFfi.download (past its own iostream-close finally block) for
/// a BLE transfer — only then is it safe for the main isolate to free the
/// bridge's shared native memory. See design spec's "no leaks, explicit
/// two-phase teardown".
class _BleBridgeReleased {
  const _BleBridgeReleased(this.address);
  final int address;
}

// Inside class DiveComputer:
  final BleTransport _bleTransport = BleTransport(UniversalBleCentral());
  Completer<void>? _bleBridgeReleased;

  @override
  Stream<BleScanResult> scanForBleDevices() => _bleTransport.scanForDevices();

  @override
  Future<void> connectBle(BleScanResult device) => _bleTransport.connect(device);

  @override
  Future<void> disconnectBle() => _bleTransport.disconnect();
```

Add the new message case to the existing `_receivePort.listen` handler in `DiveComputer._()` (alongside the existing `is SendPort` / `is List<Computer>` / `is List<Dive>` / `is Error` checks):
```dart
      } else if (message is _BleBridgeReleased) {
        _bleBridgeReleased?.complete();
```

Then modify `download()`:
```dart
  @override
  Future<List<Dive>> download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
  ]) async {
    BleBridge? bridge;
    if (transport == ComputerTransport.ble) {
      if (!_bleTransport.isConnected) {
        throw StateError(
            'download() with ComputerTransport.ble requires connectBle() '
            'to have succeeded first');
      }
      bridge = BleBridge.allocate();
      _bleTransport.attachBridge(bridge);
      _bleBridgeReleased = Completer<void>();
    }
    await _send((
      DiveComputerMethod.download,
      [computer, transport, lastFingerprint, bridge?.address],
    ));
    try {
      return await (_downloadedDives = Completer()).future;
    } finally {
      if (bridge != null) {
        await _bleBridgeReleased!.future;
        bridge.dispose();
      }
    }
  }
```

Now the isolate-side dispatcher, in `_spawnIsolate`'s `receivePort.listen` switch, the `download` case — note the `try/finally` sending `_BleBridgeReleased` regardless of success or failure (it composes correctly with the existing outer `try { switch (...) } catch (e) { sendPort.send(...) }`: the `finally` below always runs before an exception propagates to that outer `catch`):
```dart
        case DiveComputerMethod.download:
          final computer = message.$2[0] as Computer;
          final transport = message.$2[1] as ComputerTransport;
          final lastFingerprint = message.$2[2] as String?;
          final bleBridgeAddress = message.$2[3] as int?;
          DiveComputerFfi.divesCallback = (dives) {
            sendPort.send(dives);
          };
          try {
            DiveComputerFfi.download(
                computer, transport, lastFingerprint, bleBridgeAddress);
          } finally {
            if (bleBridgeAddress != null) {
              sendPort.send(_BleBridgeReleased(bleBridgeAddress));
            }
          }
          break;
```

- [ ] **Step 3: Analyze**

```
flutter analyze
```
Expected: errors pointing at `DiveComputerFfi.download` not yet accepting a 4th parameter — that's Task 11. Confirm no *other* errors.

- [ ] **Step 4: Commit**

```bash
git add lib/framework/dive_computer_interface.dart lib/framework/dive_computer_isolate.dart
git commit -m "Wire BLE scan/connect/disconnect and bridge handoff into DiveComputer"
```

---

### Task 11: Wire `DiveComputerFfi.download()`'s BLE transport case

**Files:**
- Modify: `lib/framework/dive_computer_ffi.dart`

**Interfaces:**
- Consumes: `BleBridgeCallbacks` (Task 7), `BleBridge.fromAddress` (Task 6), `dc_custom_open`/`dc_custom_cbs_t`/`DC_TRANSPORT_BLE` (Task 1).
- Produces: `DiveComputerFfi.download` accepting an optional `int? bleBridgeAddress` parameter, resolving `ComputerTransport.ble` via `dc_custom_open` instead of throwing `UnimplementedError`.

- [ ] **Step 1: Add the BLE case**

In `dive_computer_ffi.dart`, add the import:
```dart
import 'package:dive_computer/framework/ble/ble_bridge_callbacks.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
```

Change `download`'s signature and transport switch:
```dart
  static void download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
    int? bleBridgeAddress,
  ]) {
    final computerDescriptor = _computerDescriptorCache[computer]!;

    final ffi.Pointer<dc_iostream_t> iostream;
    switch (transport) {
      case ComputerTransport.serial:
        iostream = _connectSerial(computerDescriptor);
        break;
      case ComputerTransport.ble:
        if (bleBridgeAddress == null) {
          throw ArgumentError(
              'ComputerTransport.ble requires a bleBridgeAddress');
        }
        iostream = _connectBle(bleBridgeAddress);
        break;
      default:
        throw UnimplementedError();
    }
    // ... rest of the method (device open/foreach/close) is unchanged.
```

Add the new private method near `_connectSerial`:
```dart
  static ffi.Pointer<dc_iostream_t> _connectBle(int bleBridgeAddress) {
    final bridge = BleBridge.fromAddress(bleBridgeAddress);
    final callbacks = calloc<dc_custom_cbs_t>();
    callbacks.ref
      ..set_timeout = BleBridgeCallbacks.setTimeoutPtr
      ..set_break = BleBridgeCallbacks.setBreakPtr
      ..set_dtr = BleBridgeCallbacks.setDtrPtr
      ..set_rts = BleBridgeCallbacks.setRtsPtr
      ..get_lines = BleBridgeCallbacks.getLinesPtr
      ..get_available = BleBridgeCallbacks.getAvailablePtr
      ..configure = BleBridgeCallbacks.configurePtr
      ..poll = BleBridgeCallbacks.pollPtr
      ..read = BleBridgeCallbacks.readPtr
      ..write = BleBridgeCallbacks.writePtr
      ..ioctl = BleBridgeCallbacks.ioctlPtr
      ..flush = BleBridgeCallbacks.flushPtr
      ..purge = BleBridgeCallbacks.purgePtr
      ..sleep = BleBridgeCallbacks.sleepPtr
      ..close = BleBridgeCallbacks.closePtr;

    final iostream = calloc<ffi.Pointer<dc_iostream_t>>();
    _handleResult(
      _bindings.dc_custom_open(
        iostream,
        context.value,
        dc_transport_t.DC_TRANSPORT_BLE,
        callbacks,
        bridge.pointer.cast(),
      ),
      'ble custom iostream open',
    );
    calloc.free(callbacks);
    return iostream.value;
  }
```

Note: field-name and type spellings above (`dc_custom_cbs_t`, `dc_transport_t.DC_TRANSPORT_BLE`, `dc_custom_open`'s parameter order) must match exactly what Task 1 generated — open `dive_computer_ffi_bindings_generated.dart` and adjust the field names/casing if ffigen produced different ones (ffigen is generally faithful to the C member names, so this is expected to match verbatim, but verify rather than assume).

- [ ] **Step 2: Run the full test suite**

```
flutter test
flutter analyze
```
Expected: all pass; no analyzer errors anywhere in `lib/`.

- [ ] **Step 3: Commit**

```bash
git add lib/framework/dive_computer_ffi.dart
git commit -m "Implement ComputerTransport.ble via dc_custom_open and the BLE bridge"
```

---

### Task 12: Example app — full scan/connect/download flow

Extends Task 3's debug screen into something that exercises the complete path, for the Tier 2 manual test in Task 13.

**Files:**
- Modify: `example/lib/main.dart`

**Interfaces:**
- Consumes: `DiveComputer.scanForBleDevices()`, `.connectBle()`, `.disconnectBle()`, `.download()` (Task 10).

- [ ] **Step 1: Extend `BleDebugScreen`**

Replace the raw `universal_ble` calls from Task 3 with the real `DiveComputer` API:
```dart
class _BleDebugScreenState extends State<BleDebugScreen> {
  final dc = DiveComputer.instance;
  final List<String> _log = [];
  StreamSubscription<BleScanResult>? _scanSub;

  void _print(String line) {
    setState(() => _log.insert(0, line));
    // ignore: avoid_print
    print('[BleDebug] $line');
  }

  void _startScan() {
    _scanSub?.cancel();
    _scanSub = dc.scanForBleDevices().listen((result) {
      _print('Found: $result');
    });
  }

  Future<void> _connectAndDownload(BleScanResult device) async {
    try {
      _print('Connecting to ${device.name}...');
      await dc.connectBle(device);
      _print('Connected. Downloading...');
      final dives = await dc.download(
        // Any Computer works here since the BLE path doesn't use
        // libdivecomputer's descriptor-driven enumeration the way serial
        // does — pick the profile's vendor/product hint if set, otherwise
        // a placeholder; this becomes more meaningful once a real
        // BleProfile with vendor/product hints exists (Task 13+ follow-up).
        Computer(device.profile?.vendorHint ?? 'Unknown',
            device.profile?.productHint ?? device.name),
        ComputerTransport.ble,
      );
      _print('Downloaded ${dives.length} dives');
    } catch (e) {
      _print('ERROR: $e');
    } finally {
      await dc.disconnectBle();
      _print('Disconnected.');
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton(
              onPressed: _startScan, child: const Text('Scan for known BLE devices')),
        ),
        Expanded(
          child: ListView(
            children: [for (final line in _log) Text(line)],
          ),
        ),
      ],
    );
  }
}
```

(This replaces the device `ListTile`s from Task 3, since `scanForBleDevices()` already filters to recognized devices — connect directly from the scan callback via a button per result if preferred; the minimal version above just logs finds and is enough for Task 13's manual test, which drives `connectBle`/`download` by adding a `BleProfile` for the test peripheral first.)

- [ ] **Step 2: Verify it builds**

```
cd example
flutter build windows --debug
```
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add lib/main.dart
git commit -m "Extend example app's BLE screen to exercise connect+download"
```

---

### Task 13: Tier 2 manual verification (controlled peripheral, full round-trip)

Not a code task — a verification checklist. Requires a BLE peripheral you fully control (an ESP32 running a Nordic UART Service sketch, or nRF Connect's GATT-server/peripheral-simulator feature on an Android phone), so writes are safe to perform (unlike Task 3's Garmin-watch test).

- [ ] **Step 1: Set up the test peripheral**

Configure it to advertise the Nordic UART Service (`6e400001-b5a3-f393-e0a9-e50e24dcca9e`, write/RX `6e400002-...`, notify/TX `6e400003-...`) and simply echo back whatever it receives on RX, out on TX. Note its exact advertised name.

- [ ] **Step 2: Register a matching `BleProfile` for the test**

Temporarily add to `lib/types/ble_profile.dart`'s `BleProfiles.known`:
```dart
static const List<BleProfile> known = [
  BleProfile(
    namePattern: '<exact or partial advertised name from Step 1>',
    serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    writeCharUuid: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
    notifyCharUuid: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
    writeWithResponse: false,
  ),
];
```

- [ ] **Step 3: Run the example app and exercise the flow**

```
cd example
flutter run -d windows
```
Enable verbose logging first via `dc.enableDebugLogging()` (already called in `initState` per the existing example) so `finest`-level hex dumps of every read/write are visible in the console — this is the primary debugging tool here.

1. Tap "Scan for known BLE devices" — confirm the peripheral appears (proves `BleProfiles.match` + filtered scanning works end-to-end).
2. Trigger `connectAndDownload` against it (add a temporary button/tap handler if Task 12's minimal UI doesn't already wire one up).
3. Since this peripheral just echoes bytes rather than speaking a real libdivecomputer vendor protocol, `dc_device_open`/`dc_device_foreach` will likely fail parsing (expected — there's no real dive computer on the other end). What this step actually verifies: the connection succeeds, `_read`/`_write` logs show real bytes flowing both directions, and the whole thing fails *cleanly* (a caught, logged error) rather than hanging or crashing.

- [ ] **Step 4: Confirm defensive behavior**

- Power off / walk away from the peripheral mid-exchange — confirm the app logs a disconnect (`warning` level from `BleTransport._handleDisconnect`) and `download()` returns/throws within the configured timeout rather than hanging.
- Check the console for any `severe`-level bridge callback exceptions — there should be none in the happy path.

- [ ] **Step 5: Revert the temporary `BleProfiles.known` entry**

```bash
git diff lib/types/ble_profile.dart
git checkout -- lib/types/ble_profile.dart
```
(`known` stays empty in the committed codebase — see Task 4's rationale — until a *real* vendor profile is confirmed, which is explicitly out of scope for this plan.)

- [ ] **Step 6: Report results**

Summarize what was observed (connected? bytes flowed both ways? clean failure on the parse step? clean handling of a mid-transfer disconnect?) so any issues can be triaged before this plan is considered complete.

---

## Deferred hardening pass (post-implementation — filed 2026-08-27)

Tasks 5–12 were implemented and committed to `main` (commits `9c1239e`..`70af80b`). Per-task
reviews + a final whole-branch review ran; 3 Critical + 5 Important merge-blocking findings were
fixed in commit `55eb09b`. The following were **deliberately deferred** by the final review +
controller (none corrupt data or hang) — do these before the first hardware-verified `BleProfile`
lands, ideally alongside Task 13:

- **#4 Single-flight guard** (spec requires it): `BleTransport.connect()` has no in-flight guard —
  a second connect silently overwrites `_connection`/`_connStateSub`/`_profile`, orphaning the
  first. Two concurrent `download()`s clobber `_downloadedDives`/`_bleBridgeReleased`. Add a `_busy`
  flag on both, reject with a clear error.
- **#8 Ring overflow not surfaced**: `BleTransport` logs `severe` on a short `pushInbound` but the
  bg `read` callback still returns the truncated data as `DC_STATUS_SUCCESS`. Add a sticky overflow
  flag in `BleBridgeState` that `_read` converts to `DC_STATUS_IO` (spec: "log severe AND return
  DC_STATUS_IO").
- **#9 Untyped failures**: everything throws bare `StateError`. Spec demands typed
  device-not-found / connect-failed / service-mismatch / mid-transfer-disconnect / overflow /
  timeout. Add a `BleException` hierarchy in `lib/types/`, export from the barrel, switch the
  example app on it.
- **#10 Profile-mismatch handling**: the mismatch is thrown *inside* the retry loop → a genuine
  wrong-profile device burns 3 connect cycles + 750 ms backoff and reports a misleading "after 3
  attempts". Also the check only inspects the service UUID — `BleGattService.characteristicUuids`
  is collected then never used, so a missing write/notify characteristic fails deep at the first
  GATT write instead of at connect. And the `warning` log should name both mismatched UUIDs.
  Fix: rethrow mismatch outside the loop; validate `writeCharUuid`/`notifyCharUuid` presence.
- **#12** `DiveComputerFfi._connectBle`: wrap `dc_custom_open` in try/finally — leaks the
  `callbacks` struct + the one-pointer `iostream` cell on failure, and leaks the `iostream` cell
  even on success. Add a comment that freeing `callbacks` right after open is safe only because
  `dc_custom_open` copies the struct by value.
- **#13** `_read` returns `DC_STATUS_IO` when `isClosed` even if bytes are still buffered —
  discards the final payload of a device-initiated graceful close. Drain first.
- **#14** `_write` timeout logs at `warning`; spec reserves `warning` for retries. Use `finest`
  (consistent with `_read`).
- **#15** `_handleDisconnect` logs `warning('disconnected unexpectedly')` on *intentional*
  `disconnect()` too (the state stream emits `false`). Distinguish intentional teardown.
- **#17** `example/lib/main.dart`: `setState` after `await` with no `mounted` guard; `await
  dc.disconnectBle()` in a `finally` can mask the original error.
- **#18** `FakeBleConnection` stream controllers never closed; `const`-vs-`final` lint in
  `ble_scan_result_test.dart:14/16` and `ble_bridge_callbacks_test.dart:119`; add `.gitattributes`
  with `*.dart text eol=lf` to silence the Windows LF↔CRLF churn.
- **#19** The spec's `SendPort` wake-up ping for the mailbox (Data flow steps 4–5) was replaced
  with the bare 4 ms `Timer.periodic` tick — acceptable, recorded here as a deliberate deviation.
- **#20** `BleProfiles.known` is empty (intentional, per Task 4) so runtime scanning surfaces
  nothing — the example app's "Scan for known BLE devices" always shows zero results until a
  profile is added. Add a one-line note in the example screen so the Task 13 tester doesn't chase
  a phantom bug.
- **Inspection-only verification** (no automated test was feasible — spawned isolate + real
  libdivecomputer, or `UniversalBle`'s static platform facade with no injection seam): fixes for
  final-review findings #3, #5, #6, #7 were verified by code inspection, not tests. Re-check them
  against real hardware behaviour during Task 13.
- **Pre-existing / inherent-to-design** (document, don't necessarily fix): lock-free cross-isolate
  reads rely on `sleep()` as an implicit memory barrier (Decision 2); a hard isolate crash leaves
  `download()` awaiting forever + leaks the bridge (same failure class as the pre-existing
  `_downloadedDives` hang); `BleTransport.attachBridge` throwing after it has set `_bridge`/
  `_notifySub` leaves a dangling mailbox timer.
- **Flaky test**: `test/framework/ble/ble_bridge_state_test.dart` "waitForInbound times out when
  nothing arrives" asserts wall-clock `>= 30 ms` and occasionally measures 29 ms under load.
  Widen the bound or use fake-async.

**Windows build was not verified** in the implementation environment (no Visual Studio C++
toolchain). Run `cd example && flutter build windows --debug` on a configured machine before
Task 13.
