# Bluetooth Classic (RFCOMM) transport for flutter_divecomputer — design

**Date:** 2026-08-29
**Status:** Design approved, pending spec review
**Author:** Claude (with conkleon@gmail.com)
**Builds on:** `docs/superpowers/specs/2026-08-26-ble-transport-design.md` (the BLE
transport and its shared-memory isolate bridge, which this design reuses) and
`docs/superpowers/specs/2026-08-28-mares-cressi-ble-example-design.md` (the
example app's device-picker pattern).

## Goal

Implement `ComputerTransport.bluetooth` (Bluetooth Classic / RFCOMM / SPP) for
**Windows and Android**, so that dive computers that sync only over Bluetooth
Classic — the original Shearwater **Predator**, **Petrel**, **Petrel 2**,
**NERD**, and **Perdix** — can have their dive logs downloaded by this plugin.
Today `ComputerTransport.bluetooth` falls through to `UnimplementedError`.

Primary validation target: a **Shearwater Petrel (1)** on an **Android** phone
(the user's Pixel 6a). The Petrel 1 uses a ~2012 Bluetooth 2.0 + EDR module and
does not have a BLE radio, so the existing BLE transport can never see it.

## Background

### Why this is needed

The plugin's BLE transport (2026-08-26 design) covers current-generation dive
computers. It does **not** cover Bluetooth-Classic-only models. On Windows,
those pair as a virtual COM port and libdivecomputer's serial backend can
sometimes talk to them — but in practice that path is fragile: Windows
enumerates COM ports non-deterministically (fixed this session — see
`lib/framework/utils/serial_ports.dart`), and even with the right port a modern
Windows BT stack frequently cannot establish the RFCOMM link to a legacy device
(observed: `BTHUSB` event-log `mutual authentication ... failed`, `CreateFile`
→ `ERROR_ACCESS_DENIED`). On Android there is no serial path at all for a
Bluetooth device.

### What libdivecomputer provides for Bluetooth Classic

Confirmed against the **vendored 0.9.0-devel binaries** (symbol inspection):

- **Windows DLL** (`native/lib/windows_x64/libdivecomputer-0.dll`) exports
  `dc_bluetooth_open`, `dc_bluetooth_iterator_new`, `dc_bluetooth_iterator_next`,
  `dc_bluetooth_device_get_address`, `dc_bluetooth_device_get_name`,
  `dc_bluetooth_device_free`, `dc_bluetooth_address_t`. libdivecomputer's own
  Windows Bluetooth backend (Winsock `AF_BTH` / `BTHPROTO_RFCOMM`) is compiled
  in. So on Windows we can call libdivecomputer directly, exactly as the serial
  path does — enumerate paired devices, open by address, hand the resulting
  `dc_iostream_t*` to `dc_device_open`.
- **Android `.so`** exports the same symbols (libdivecomputer's Linux/BlueZ
  backend, `AF_BLUETOOTH` / `sockaddr_rc`). **But an unprivileged Android app
  cannot create `AF_BLUETOOTH` sockets** (SELinux `untrusted_app` domain). So
  `dc_bluetooth_open` will fail at `socket()` on Android. The app must own the
  RFCOMM connection through `android.bluetooth.BluetoothSocket` (Java) and feed
  libdivecomputer a byte stream via `dc_custom_open` — the same approach
  Subsurface-mobile takes on Android.
- `custom.h`'s `dc_custom_open(iostream, context, transport, callbacks,
  userdata)` accepts any `dc_transport_t`. Passing `DC_TRANSPORT_BLUETOOTH`
  (already bound: `dive_computer_ffi_bindings_generated.dart` has
  `DC_TRANSPORT_BLUETOOTH = 16`) tells the Shearwater backend to use plain
  stream framing (not the BLE packet framing keyed off `DC_TRANSPORT_BLE`).

### The isolate-bridge constraint (unchanged from the BLE design)

libdivecomputer's calls block the background isolate's thread; platform
Bluetooth I/O on Android is async and must run where Flutter's plugin
machinery lives (the main isolate). Bytes cross between them through a
malloc'd shared-memory region (ring buffer inbound + mailbox outbound +
`closed` flag), spin-polled by the background isolate's synchronous
`dc_custom_cbs_t` callbacks. This machinery already exists for BLE
(`lib/framework/ble/ble_bridge_state.dart`,
`lib/framework/ble/ble_bridge_callbacks.dart`) and is transport-neutral — a
byte pipe. RFCOMM is a plain stream (simpler than BLE's packetised
notifications) and reuses it unchanged.

## Architecture: two platform paths

`ComputerTransport.bluetooth` resolves to **different implementations per
platform**, dispatched in the `DiveComputer` main-isolate facade. This mirrors
the asymmetry the BLE transport already has (BLE scanning runs on the main
isolate via `BleTransport`, not in the FFI isolate).

| Step | Windows | Android |
|---|---|---|
| Enumerate paired devices | FFI isolate → `dc_bluetooth_iterator_new` | main isolate → Kotlin `BluetoothAdapter.bondedDevices` |
| Open connection | FFI isolate → `dc_bluetooth_open(addr)` | main isolate → Kotlin `BluetoothSocket` (SPP UUID) |
| Feed libdivecomputer | native `dc_iostream_t*` straight into `dc_device_open` | `dc_custom_open(…, DC_TRANSPORT_BLUETOOTH, …)` over the reused bridge |
| Bridge needed? | No — blocking socket on the FFI thread, like serial | Yes — reused BLE bridge |

### Approaches considered

- **Windows — libdivecomputer-native (chosen)** vs. a hand-written WinRT/Winsock
  RFCOMM layer + bridge. The DLL already ships the backend; reimplementing it
  is pure duplication. Accepted trade-off: `dc_bluetooth_open` uses the same
  stored Windows link key that is currently failing `mutual authentication` for
  the user's Petrel, via a different (`AF_BTH`) code path than the virtual COM
  port — it may or may not get through on that specific device, but it is the
  correct API and works for other devices / a re-paired device / a fixed BT
  stack.
- **Android — hand-rolled Kotlin platform channel (chosen)** vs. a third-party
  RFCOMM package (`bluetooth_serial_android`, `flutter_classic_bluetooth`, …).
  RFCOMM SPP is ~180 lines of well-trodden Kotlin; the available packages have
  far lower adoption / proven-ness than `universal_ble` and would add an
  unowned dependency for a simple protocol. `universal_ble` stays for BLE.
- **Bonded-devices-only (chosen)** vs. in-app Classic discovery + pairing. The
  user pairs once in the OS settings; the app lists already-bonded devices.
  Avoids `BLUETOOTH_SCAN`, location permission, and OS-driven pairing dialogs.

## Components

### Shared types

**`lib/types/bt_device.dart`** (new)

```dart
class BtDevice {
  const BtDevice(this.name, this.address);
  final String name;     // advertised / bonded name, e.g. "Petrel"
  final String address;  // "00:13:43:0A:A0:6F"
}
```

Sendable across isolates (plain final fields, like `Computer`).

**`lib/types/classic_bt_profile.dart`** (new)

```dart
class ClassicBtProfile {
  const ClassicBtProfile({
    required this.namePatterns,
    this.vendorHint,
    this.productHint,
  });
  final List<String> namePatterns;   // case-insensitive substring match
  final String? vendorHint, productHint;
  bool matchesName(String name) { /* same logic as BleProfile.matchesName, patterns only */ }
}

class ClassicBtProfiles {
  static const shearwater = ClassicBtProfile(
    namePatterns: ['Predator', 'Petrel', 'Perdix', 'NERD', 'Nerd'],
    vendorHint: 'Shearwater',
    productHint: 'Petrel',
  );
  static const known = [shearwater];
  static ClassicBtProfile? match(String name) { /* first known hit, else null */ }
}
```

Deliberately **separate from and smaller than** `BleProfiles.shearwater`: only
the Classic-BT Shearwaters belong here. Teric / Peregrine / Petrel 3 / Perdix 2
/ Tern are BLE-only and must not appear (picking a Classic descriptor for them
would be wrong). `productHint` `Petrel` is the safest descriptor present in the
vendored build for an unknown Classic Shearwater; the example's picker lets the
user switch.

### Bridge rename (mechanical)

The bridge now has two consumers, so its name should stop saying "Ble":

| From | To |
|---|---|
| `lib/framework/ble/ble_bridge_state.dart` | `lib/framework/io_bridge/io_bridge_state.dart` |
| `lib/framework/ble/ble_bridge_callbacks.dart` | `lib/framework/io_bridge/io_bridge_callbacks.dart` |
| class `BleBridge` | `IoBridge` |
| class `BleBridgeState` | `IoBridgeState` |
| class `BleBridgeCallbacks` | `IoBridgeCallbacks` |
| logger `bleBridgeLog` | `ioBridgeLog` |
| `dive_computer_isolate.dart` `_BleBridgeReleased` | `_BridgeReleased` |
| `dive_computer_ffi.dart` / isolate param `bleBridgeAddress` | `bridgeAddress` |

`ble_transport.dart`, `ble_central.dart`, `fake_ble_central.dart` stay in
`lib/framework/ble/` (they are BLE-specific). Their bridge tests
(`test/framework/ble/ble_bridge_state_test.dart`,
`ble_bridge_callbacks_test.dart`) move to `test/framework/io_bridge/` and get
the renamed symbols. Pure find-and-replace; the suite proves it.

Note: `ble_bridge_state_test.dart` has a pre-existing timing-flaky test
("closed unblocks a wait immediately", asserts sub-30ms wall-clock). It stays
flaky after the move; not this design's problem to fix.

### `BridgedTransport` base (extraction)

`BleTransport` (`lib/framework/ble/ble_transport.dart`) contains logic that is
transport-neutral:

- feeding inbound bytes into `IoBridgeState`'s ring buffer,
- servicing the outbound mailbox (`Timer.periodic` ~5ms + early wake via a
  `SendPort` ping from the background isolate),
- bounded teardown (set `closed`, cancel timer, release),
- watching a disconnect signal and setting `closed`.

Extract these into **`lib/framework/io_bridge/bridged_transport.dart`**, an
abstract base with hooks the concrete transports implement:

```dart
abstract class BridgedTransport {
  Future<void> connectTransport();          // GATT connect / RFCOMM socket
  Future<void> writeOutbound(List<int> b);  // characteristic write / socket write
  Stream<Uint8List> get inboundBytes;       // notifications / socket reads
  Stream<void> get disconnected;            // connection-lost signal
  Future<void> disconnectTransport();
  // base provides: attachBridge, the mailbox pump, ring feed, teardown, isConnected
}
```

`BleTransport extends BridgedTransport` (keeps its `BleProfile` /
characteristic-discovery specifics); `RfcommTransport extends BridgedTransport`.
`test/framework/ble/ble_transport_test.dart` must stay green through the
extraction — do it incrementally under TDD.

### `lib/framework/rfcomm/rfcomm_channel.dart` (new)

Thin wrapper over the Kotlin platform channels. Abstract for testability:

```dart
abstract class RfcommChannel {
  Future<bool> requestPermissions();
  Future<List<BtDevice>> bondedDevices();
  Future<void> connect(String address);
  Stream<Uint8List> get inbound;
  Future<void> write(List<int> bytes);
  Future<void> disconnect();
}
```

- `MethodChannelRfcommChannel` — real impl over `MethodChannel`
  `app.divenote.dive_computer/rfcomm` + `EventChannel`
  `app.divenote.dive_computer/rfcomm/inbound`.
- `FakeRfcommChannel` — in-memory, for `RfcommTransport` tests (mirrors
  `fake_ble_central.dart`).

### `lib/framework/rfcomm/rfcomm_transport.dart` (new)

`RfcommTransport extends BridgedTransport`. Owns an `RfcommChannel`.
`connectTransport()` → `channel.connect(address)`; `inboundBytes` →
`channel.inbound`; `writeOutbound` → `channel.write`; `disconnected` derived
from the inbound stream closing / an error; `disconnectTransport()` →
`channel.disconnect()`. No service/characteristic discovery — RFCOMM is a
single stream.

### `android/src/main/kotlin/app/divenote/dive_computer/DiveComputerPlugin.kt` (new)

`FlutterPlugin`, `ActivityAware`, `PluginRegistry.RequestPermissionsResultListener`.
~180 lines.

- **`MethodChannel` `…/rfcomm` handlers:**
  - `requestPermissions` → on API ≥ 31 request `BLUETOOTH_CONNECT` via the
    bound activity, complete the result from `onRequestPermissionsResult`;
    below 31 return `true` (manifest `BLUETOOTH` is install-time).
  - `bondedDevices` → `bluetoothManager.adapter.bondedDevices` →
    `[{"name": …, "address": …}]`. Requires `BLUETOOTH_CONNECT` on 31+.
  - `connect` (arg `address`) → `adapter.getRemoteDevice(address)
    .createRfcommSocketToServiceRecord(UUID 00001101-0000-1000-8000-00805F9B34FB)`;
    `adapter.cancelDiscovery()`; `socket.connect()` on a single-thread executor
    (blocks ~12s, throws `IOException` on failure → `result.error("connect_failed", …)`).
    On success, start the reader thread.
  - `write` (arg `Uint8List`) → `socket.outputStream.write(bytes)` on the same
    executor, `synchronized(socket)`.
  - `disconnect` → `socket.close()`, stop reader, shut executor.
- **`EventChannel` `…/rfcomm/inbound`:** reader thread loops
  `socket.inputStream.read(buf)` (blocking); each chunk →
  `Handler(Looper.getMainLooper()).post { sink.success(bytes) }`. `read()`
  returns −1 / throws on disconnect → `sink.endOfStream()` (or
  `sink.error("disconnected", …)`). One active connection at a time.
- **Threading:** all socket ops on one `Executors.newSingleThreadExecutor()`
  except the dedicated blocking reader thread. `EventChannel` sink touched only
  on the main thread.

### Manifest changes

`android/src/main/AndroidManifest.xml` **and**
`example/android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
```

No `BLUETOOTH_SCAN`, no `ACCESS_FINE_LOCATION` — bonded devices only.
`minSdkVersion` stays 19 (the API-31 calls are guarded; `BluetoothManager` is
API 18, `createRfcommSocketToServiceRecord` is API 1).

### `pubspec.yaml`

```yaml
plugin:
  platforms:
    android:
      ffiPlugin: true
      pluginClass: DiveComputerPlugin   # NEW — hybrid FFI + method-channel plugin
```

### FFI layer — `lib/framework/dive_computer_ffi.dart`

- **`bluetoothDevices(Computer) → List<BtDevice>`** (Windows path): mirror
  `_enumerateSerialPorts` — `dc_bluetooth_iterator_new(iter, context,
  descriptor)`, loop `dc_iterator_next`, read
  `dc_bluetooth_device_get_name` / `_get_address`, format the address
  `XX:XX:XX:XX:XX:XX` from the `dc_bluetooth_address_t` (uint64). Dedupe.
- **`_connectBluetooth(descriptor, String address) → Pointer<dc_iostream_t>`**
  (Windows path): parse `address` back to `dc_bluetooth_address_t`,
  `dc_bluetooth_open(iostream, context, addr)`. Structurally identical to
  `_connectSerial`. On `DC_STATUS_NOACCESS` the error message points at the
  pairing (`mutual authentication` note).
- **`_connectBridged(int bridgeAddress, int transport)`** — the current
  `_connectBle` generalised: `dc_custom_open(iostream, context, transport,
  callbacks, bridge.pointer)` with `transport` ∈ {`DC_TRANSPORT_BLE`,
  `DC_TRANSPORT_BLUETOOTH`}. Callbacks unchanged (`IoBridgeCallbacks`).
- **`download` switch:**

```dart
case ComputerTransport.serial:
  iostream = _connectSerial(computerDescriptor, address);
case ComputerTransport.ble:
  iostream = _connectBridged(bridgeAddress!, DC_TRANSPORT_BLE);
case ComputerTransport.bluetooth:
  iostream = bridgeAddress != null
    ? _connectBridged(bridgeAddress, DC_TRANSPORT_BLUETOOTH)   // Android
    : _connectBluetooth(computerDescriptor, address);         // Windows
```

`download`'s `serialPortName` parameter (added this session) is renamed
`address` — COM port for serial, BT MAC for Windows bluetooth, ignored for the
bridged paths. No external callers.

### `ffigen.yaml`

Add `native/include/libdivecomputer/bluetooth.h` to `headers.entry-points`.
Regenerate `dive_computer_ffi_bindings_generated.dart`
(`flutter pub run ffigen --config ffigen.yaml`). New symbols:
`dc_bluetooth_open`, `dc_bluetooth_iterator_new`, `dc_bluetooth_device_t` +
accessors, `dc_bluetooth_address_t`.

### Isolate — `lib/framework/dive_computer_isolate.dart`

- `enum DiveComputerMethod { …, bluetoothDevices }`.
- `Completer<List<BtDevice>>? _bluetoothDevices`; handled in the receive-port
  listener with the same double-complete guard as the others; also completed
  with error in the error branch.
- `download` `IsolateMessage` args gain `address` (already carries `computer,
  transport, lastFingerprint, bleBridgeAddress`).
- `_spawnIsolate`: `case DiveComputerMethod.bluetoothDevices:` →
  `sendPort.send(DiveComputerFfi.bluetoothDevices(computer))`. `download` reads
  `address` and passes it through.

### `DiveComputerInterface`

```dart
Future<List<BtDevice>> bluetoothDevices(Computer computer) => throw UnimplementedError();
Future<bool> requestBluetoothPermissions() async => true;   // default: nothing to do
Future<List<Dive>> download(Computer computer, ComputerTransport transport,
    [String? lastFingerprint, String? address]);            // serialPort → address
```

### `DiveComputer` facade dispatch (`dive_computer_isolate.dart`)

- `requestBluetoothPermissions()` → Android: `_rfcommChannel.requestPermissions()`;
  else `true`.
- `bluetoothDevices(computer)` → Android: `_rfcommChannel.bondedDevices()`;
  Windows: isolate `bluetoothDevices` message; else `[]`.
- `download(computer, ComputerTransport.bluetooth, fp, address)`:
  - **Android:** `await _rfcommChannel.connect(address!)`; then the BLE flow
    verbatim — `IoBridge.allocate()`, `_rfcommTransport.attachBridge(bridge)`,
    send `(computer, bluetooth, fp, bridge.address, null)`, `await` the
    `_BridgeReleased` handshake, `bridge.dispose()`, `_rfcommChannel.disconnect()`.
  - **Windows:** send `(computer, bluetooth, fp, null, address)`; FFI isolate
    calls `_connectBluetooth`.
  - The single-flight guard and two-phase teardown are exactly the BLE ones.

### Example app — `example/lib/main.dart`

- Tab 1 label: "Serial computers" → **"Serial / Bluetooth"**.
- `_downloadFrom` (added this session) gains a `bluetooth` branch: if the
  tapped computer's `transports` contains `ComputerTransport.bluetooth`:
  1. `await dc.requestBluetoothPermissions()` — on denial, snackbar and stop.
  2. `await dc.bluetoothDevices(computer)` → `SimpleDialog` of `BtDevice`s
     (filtered by `ClassicBtProfiles.match` when the computer is a Shearwater,
     else all bonded). Empty → snackbar "no paired devices — pair it in system
     Bluetooth settings first".
  3. `dc.download(computer, ComputerTransport.bluetooth, 'exampleFingerprint',
     picked.address)`.
- Serial (COM-port) branch unchanged. `catch` → snackbar, as now.

## Data flow — Android download

1. Main isolate: user picks a bonded `BtDevice`. `DiveComputer.download(…,
   bluetooth, …)` calls `_rfcommChannel.connect(address)` → Kotlin opens the
   `BluetoothSocket` and starts its reader thread.
2. Main isolate: `IoBridge.allocate()`, `_rfcommTransport.attachBridge(bridge)`,
   send the download message with `bridge.address` + `DC_TRANSPORT_BLUETOOTH`.
3. FFI isolate: `_connectBridged(addr, DC_TRANSPORT_BLUETOOTH)` →
   `dc_custom_open`, then `dc_device_open` / `dc_device_foreach` — blocks the
   isolate thread.
4. libdivecomputer calls the `write` callback → bytes into the mailbox,
   `writeSeq++`, `SendPort` ping, spin-poll `writeAckSeq`.
5. Main isolate: `RfcommTransport` (via `BridgedTransport`'s pump) performs
   `_rfcommChannel.write(bytes)` → Kotlin `outputStream.write`; sets `writeAckSeq`.
6. Petrel replies; Kotlin reader thread posts chunks → `EventChannel` →
   `RfcommChannel.inbound` → `BridgedTransport` pushes into the ring buffer.
7. FFI isolate `read`/`poll` callbacks spin-poll the ring, return bytes to
   libdivecomputer; steps 4–7 repeat per protocol exchange.
8. `dc_device_close` → `close` callback sets `closed`; `RfcommTransport`
   observes it (or a disconnect), calls `_rfcommChannel.disconnect()`; FFI
   isolate signals `_BridgeReleased` in its `finally`; main isolate frees
   the bridge.

## Testing

- **`test/types/classic_bt_profile_test.dart`** — `Petrel` / `Perdix` /
  `NERD` / `Predator` match `shearwater`; `Teric` / `Peregrine` /
  `Garmin Descent` don't; `ClassicBtProfiles.match` picks the first hit.
- **`test/framework/rfcomm/rfcomm_transport_test.dart`** — `FakeRfcommChannel`
  + the bridge harness: inbound bytes reach the ring; the outbound mailbox
  drains to `write` with correct sequencing; a mid-flight disconnect sets
  `closed` and interrupts a wait; bounded teardown, no leak. Reuses the shape
  of `ble_transport_test.dart`.
- **`BridgedTransport` extraction** — `test/framework/ble/ble_transport_test.dart`
  and the moved `io_bridge` tests stay green throughout.
- **Isolate source-guards** (repo pattern — the isolate can't run under
  `flutter test`): `bluetoothDevices` round-trips through a guarded
  `Completer<List<BtDevice>>`; `download` forwards `address`; the `bluetooth`
  case picks `DC_TRANSPORT_BLUETOOTH` when bridged.
- **FFI source-guard** — `_connectBluetooth` goes through `dc_bluetooth_open`,
  not a COM-port path.
- **No Kotlin unit tests** (consistent with the repo — no native test setup).
- **Manual, run by the user after it lands** (checklist in the plan):
  1. Android: pair the Petrel in system Bluetooth settings (Petrel on its
     Bluetooth/upload screen, PIN `0000`).
  2. Example → "Serial / Bluetooth" tab → tap **Shearwater Petrel**.
  3. Grant the `BLUETOOTH_CONNECT` prompt.
  4. Pick **Petrel** from the bonded-device dialog.
  5. Full dive log downloads; dives render; verbose console dump is complete.
  6. Walk away mid-download → fails cleanly (typed error, bridge freed, socket
     closed), no hang, no crash on retry.
  7. Windows: same flow via the "Serial / Bluetooth" tab; may fail at
     `dc_bluetooth_open` if the OS pairing is still broken — that's expected
     and separate.

## Non-goals

- iOS / macOS Bluetooth Classic.
- In-app Classic discovery or pairing — bonded devices only; the user pairs in
  OS settings. No `BLUETOOTH_SCAN`.
- A general Classic-BT profile table beyond Shearwater — add vendors (older
  Suunto, Uwatec Smart, Mares, Oceanic BT models …) as each is confirmed
  against hardware.
- Fixing the user's specific broken Windows pairing (`mutual authentication
  failed`) — outside this plugin. The Windows path is built correctly; whether
  that device authenticates is an OS/hardware matter.
- Bluetooth Classic on the BLE "scan" screen — Classic devices don't advertise
  as BLE and never will appear there.

## Risks / open questions

- **Windows `dc_bluetooth_open` may hit the same `mutual authentication
  failed`** as the virtual-COM-port path (same stored link key, different
  `AF_BTH` code path). Cannot be verified without a working pairing. The code
  is still correct and useful for other devices.
- **libdivecomputer's Shearwater backend over a `dc_custom_open(
  DC_TRANSPORT_BLUETOOTH)` custom iostream (Android)** vs. its native
  `AF_BLUETOOTH` backend — stream framing should be identical (neither uses
  BLE packet mode), but this is unverified until the Petrel test.
- **Android 12+ permission timing** — `bondedDevices()` /
  `createRfcommSocketToServiceRecord` throw `SecurityException` without
  `BLUETOOTH_CONNECT`; the example must call `requestBluetoothPermissions()`
  first and the plugin must surface the denial as a typed error, not a crash.
- **`BridgedTransport` extraction touches working BLE code** — mitigated by the
  existing `ble_transport_test.dart` suite; do it incrementally.
- **Reader-thread → bridge latency under the bridge's bounded waits** — RFCOMM
  data rates from a dive computer are low and the ring is a few KB; revisit the
  spin-poll interval / ring size only if the Petrel test shows stalls.
- **`dc_bluetooth_iterator_new` scoping on Windows** — whether it filters to
  the passed descriptor's known device names or returns all paired BT devices.
  If it returns all, `bluetoothDevices()` output is filtered by
  `ClassicBtProfiles`/name in the example, same as the serial-port picker.

## Files touched

| File | Change |
|---|---|
| `lib/types/bt_device.dart` | new — `BtDevice` |
| `lib/types/classic_bt_profile.dart` | new — `ClassicBtProfile` + `ClassicBtProfiles.known` (Shearwater) |
| `lib/framework/io_bridge/io_bridge_state.dart` | moved+renamed from `ble/ble_bridge_state.dart` |
| `lib/framework/io_bridge/io_bridge_callbacks.dart` | moved+renamed from `ble/ble_bridge_callbacks.dart` |
| `lib/framework/io_bridge/bridged_transport.dart` | new — extracted transport-neutral base |
| `lib/framework/ble/ble_transport.dart` | `extends BridgedTransport`; BLE-specific hooks only |
| `lib/framework/rfcomm/rfcomm_channel.dart` | new — `RfcommChannel` (abstract, real, fake) |
| `lib/framework/rfcomm/rfcomm_transport.dart` | new — `RfcommTransport extends BridgedTransport` |
| `lib/framework/dive_computer_ffi.dart` | `bluetoothDevices`, `_connectBluetooth`, `_connectBridged`, `download` switch, `serialPortName`→`address` |
| `lib/framework/dive_computer_isolate.dart` | `bluetoothDevices` method + guarded completer; facade platform dispatch; `RfcommChannel`/`RfcommTransport` wiring; `address` in the download message |
| `lib/framework/dive_computer_interface.dart` | `bluetoothDevices`, `requestBluetoothPermissions`, `download` `address` param |
| `lib/framework/dive_computer_unsupported.dart` | inherits the new throwing defaults (no change needed) |
| `ffigen.yaml` | add `bluetooth.h` entry-point |
| `lib/framework/dive_computer_ffi_bindings_generated.dart` | regenerated |
| `android/src/main/kotlin/app/divenote/dive_computer/DiveComputerPlugin.kt` | new — RFCOMM method/event channels + permissions |
| `android/src/main/AndroidManifest.xml` | BT permissions |
| `pubspec.yaml` | `pluginClass: DiveComputerPlugin` for android |
| `example/lib/main.dart` | "Serial / Bluetooth" tab; `bluetooth` branch in `_downloadFrom` |
| `example/android/app/src/main/AndroidManifest.xml` | BT permissions |
| `test/types/classic_bt_profile_test.dart` | new |
| `test/framework/rfcomm/rfcomm_transport_test.dart` | new |
| `test/framework/io_bridge/*` | moved from `test/framework/ble/ble_bridge_*` |
| `test/framework/ble/ble_transport_test.dart` | updated for `BridgedTransport` |
| `test/framework/dive_computer_isolate_test.dart` | source-guards for `bluetoothDevices` + `address` |
| `test/framework/dive_computer_ffi_cap_test.dart` | source-guard for `_connectBluetooth` |
| `CHANGELOG.md` | note the new transport + the Windows-pairing caveat |
| `README.md` | Roadmap: Bluetooth Classic now partially done (Windows + Android) |
