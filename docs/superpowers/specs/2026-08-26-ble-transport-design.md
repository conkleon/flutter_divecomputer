# BLE transport for flutter_divecomputer — design

Status: approved (pending final user sign-off on this document)
Author: Claude (with conkleon@gmail.com)
Date: 2026-08-26

## Background

`flutter_divecomputer` wraps [libdivecomputer](https://www.libdivecomputer.org/)
via `dart:ffi` to download dive logs from dive computers. Today only
`ComputerTransport.serial` is implemented (`DiveComputerFfi._connectSerial`).
Most current-generation dive computers sync over Bluetooth (Classic or BLE)
rather than a cable, so BLE support is the main gap blocking real-world use
on Windows and Android, the app's two primary targets.

### What libdivecomputer actually provides for BLE

Read directly from the vendored headers (`native/include/libdivecomputer/`):

- `custom.h` defines `dc_custom_open(iostream, context, transport, callbacks,
  userdata)`, where `callbacks` is a `dc_custom_cbs_t` struct of **synchronous**
  function pointers (`read`, `write`, `poll`, `get_available`, `set_timeout`,
  `close`, plus serial-line no-ops we don't need for BLE). This is the only
  hook point — libdivecomputer has no BLE transport of its own; the vendor
  protocol parsers just consume a byte stream.
- `ble.h` defines exactly one thing: `DC_IOCTL_BLE_GET_NAME`. There is **no**
  GATT service/characteristic UUID table anywhere in the headers. The host
  application owns device scanning, GATT connection, and matching a physical
  peripheral to the right characteristics — the same approach Subsurface's
  `qt-ble.cpp` and libdivecomputer's own `dctool` BLE backend use on
  Linux/Qt.
- `common.h` confirms `DC_TRANSPORT_BLE = (1 << 5)` exists as a transport
  constant to pass into `dc_custom_open`.

### The core technical constraint

libdivecomputer's calls are blocking, so `download()` already runs in a
background `Isolate` (`dive_computer_isolate.dart`) to keep the UI isolate
free. BLE I/O via the chosen plugin (`universal_ble`, see below) is
`Future`-based and needs to run where Flutter's plugin/platform-channel
machinery lives — practically, the main isolate. That means bytes must cross
from the main isolate (where BLE notifications arrive asynchronously) into a
**synchronous** callback running on the background isolate's native thread —
and while that thread is blocked inside a libdivecomputer C call, its own
Dart event loop is frozen too, so it cannot `await` anything or process a
`ReceivePort` message. This constraint drives the entire bridge design below.

## Goals

- Implement `ComputerTransport.ble` for Windows and Android, starting with
  an end-to-end working slice on Windows. (`ComputerTransport.bluetooth`,
  i.e. Bluetooth Classic/RFCOMM, is explicitly out of scope — see
  Non-goals.)
- No hand-written native BLE stack per platform.
- The synchronization bridge between the async BLE layer and libdivecomputer's
  synchronous callbacks must be robust: bounded waits, no leaks, no silent
  data corruption, clear typed errors, and verbose opt-in logging — since
  debugging this will mostly happen through logs, not a debugger attached to
  a blocked native thread.
- Automated test coverage for the highest-risk piece (the bridge protocol)
  without requiring any BLE hardware.

## Non-goals (this round)

- A comprehensive per-vendor GATT UUID table. We have no dive-computer
  hardware to verify against yet; the profile registry starts with one
  well-documented placeholder (Nordic UART Service) explicitly flagged as
  unverified, and grows later as real devices are confirmed.
- iOS/macOS BLE (out of scope; not a primary target per the plugin README).
- Manual "connect to an unrecognized device and let the user pick a profile"
  UX — v1 only surfaces devices matching a known `BleProfile`.
- Bluetooth Classic (RFCOMM) — BLE only. `bluetooth.h` isn't part of this
  design.

## Architecture decisions

### Decision 1 — Use `universal_ble`, not hand-written per-platform BLE code

Verified via research (2026-08-26): [`universal_ble`](https://pub.dev/packages/universal_ble)
(Navideck) gives one Dart API across Android/iOS/macOS/**Windows**/Linux/Web
for BLE central-mode operations — scan (with filters), connect/disconnect,
`discoverServices`, `read`/`write` (with `withResponse` control),
`notifications.subscribe`, and best-effort `requestMtu`. Actively maintained
(published ~30 days prior to this writing, 154 likes, verified publisher).
This covers everything we need for central-mode GATT access on both target
platforms with one dependency instead of two bespoke native subsystems
(WinRT C++ for Windows, `BluetoothGatt`/JNI for Android).

Trade-off accepted: we depend on a third-party plugin's Windows BLE
implementation quality rather than controlling it directly. Mitigated by the
Tier 0 smoke test below, done early, before investing in the bridge.

### Decision 2 — Pure Dart + `dart:ffi` shared-memory bridge, no custom native C/C++ code

The synchronization bridge (Section "The core technical constraint" above)
is implemented as a shared-memory region allocated via `package:ffi`'s
`malloc` (native/OS heap, not the Dart GC heap — visible from both isolates
by sharing its integer `.address`, a well-supported cross-isolate FFI
pattern). The background isolate's callbacks **spin-poll** this memory with
short sleeps and timeout bounds, rather than using any Dart-level
await/event-loop mechanism (which is unavailable to them while blocked
inside a libdivecomputer call) or a hand-written native semaphore helper
(which would add a small C library and per-platform build wiring for no
real benefit here, given the low data rates and latency tolerance of a dive
computer download protocol).

This keeps the entire bridge protocol as plain, unit-testable Dart — no
native toolchain needed to test its correctness.

## Components

### `lib/framework/ble/ble_bridge.dart` (new)

Defines the shared-memory layout as an `ffi.Struct`, `BleBridgeState`:

- Inbound ring buffer (fixed capacity, generously sized against typical BLE
  notification/MTU chunk sizes — exact sizing to be tuned once real traffic
  is observed; starts conservative, e.g. a few KB) + head/tail indices, for
  notification bytes flowing device → host.
- Outbound mailbox: buffer + length + a monotonic `writeSeq` /
  `writeAckSeq` pair, for command bytes flowing host → device.
- `closed` flag (set on either side to unblock all spin-waits immediately
  and signal teardown).
- `timeoutMs`, set by the `set_timeout` callback, read by `read`/`poll`.

API:

- `BleBridge.allocate()` — mallocs the struct; returns a wrapper exposing
  `.address` (an `int`, sendable across isolates via `SendPort`).
- `BleBridge.fromAddress(int address)` — reconstructs the wrapper via
  `Pointer.fromAddress` on the receiving isolate.
- `dispose()` — frees the memory. Only called after the two-phase teardown
  handshake described under Defensive measures.
- Static `Pointer.fromFunction` callbacks matching `dc_custom_cbs_t`:
  `_read`, `_write`, `_poll`, `_getAvailable`, `_close`, `_setTimeout`, and
  no-op `DC_STATUS_SUCCESS` stubs for the serial-only members
  (`set_break`/`set_dtr`/`set_rts`/`get_lines`/`configure`/`flush`/`purge`/
  `sleep`/`ioctl`). These run on the **background isolate** — this mirrors
  the existing `Pointer.fromFunction` pattern already used for the sample
  and log callbacks in `dive_computer_ffi.dart`.

### `lib/framework/ble/ble_transport.dart` (new)

Runs on the **main isolate**. Wraps `universal_ble`:

- Connects to a given device id (with retry/backoff — see Defensive
  measures), discovers the target service/characteristic pair from a
  `BleProfile`, subscribes to notifications.
- On each notification packet, pushes bytes into the bridge's inbound ring
  buffer.
- Services the outbound mailbox: a `Timer.periodic` (~5ms) checks
  `writeSeq` vs `writeAckSeq`, and is also woken early by a `SendPort` ping
  the background isolate sends the moment it queues a write (this is safe
  to call from inside a blocked native callback — `SendPort.send` is a
  fire-and-forget enqueue that doesn't require the sender's own event loop
  to be running). On a new pending write, performs the `universal_ble`
  characteristic write, then bumps `writeAckSeq`.
- Watches `universal_ble`'s connection-state stream; on disconnect (whether
  user-initiated, device-initiated, or radio error), immediately sets
  `closed`, cancels the timer, unsubscribes, and disconnects.

### `lib/types/ble_profile.dart` (new)

```dart
class BleProfile {
  final String namePattern;       // matched against advertised name
  final String serviceUuid, writeCharUuid, notifyCharUuid;
  final bool writeWithResponse;
  final String? vendorHint, productHint; // best-guess Computer match
}
```

`BleProfiles.known` starts with exactly one entry: the Nordic UART Service
(`6e400001-b5a3-f393-e0a9-e50e24dcca9e`, write/RX `6e400002-...`, notify/TX
`6e400003-...`) — a standard, well-documented profile several dive-computer
vendors build on top of. Explicitly commented as **unverified against real
hardware**. Growing this table with confirmed per-vendor entries is
follow-up work, not part of this round.

### Changes to existing files

- `dive_computer_ffi.dart` — `download()`'s transport `switch` gains a
  `ComputerTransport.ble` case calling `dc_custom_open(iostream, context,
  DC_TRANSPORT_BLE, &callbacks, bridgeStatePointer)` instead of
  `_connectSerial`. `ComputerTransport.bluetooth` (Classic/RFCOMM) is not
  touched by this design — see Non-goals — and continues to fall through to
  `UnimplementedError` as it does today.
- `dive_computer_isolate.dart` — the `download` `IsolateMessage` payload
  optionally carries the bridge's shared-memory address (an `int`) when
  `transport` is BLE; the isolate reconstructs `BleBridge.fromAddress(...)`
  before calling into `DiveComputerFfi.download`.
- `dive_computer_interface.dart` — gains `Stream<BleScanResult>
  scanForBleDevices()`, wrapping `universal_ble` scanning but yielding only
  devices matching a known `BleProfile` (unmatched devices are filtered out
  — see Defensive measures). `download()`'s existing signature is
  unchanged; callers pass the already-connected BLE handle through
  alongside `ComputerTransport.ble`.
- `ffigen.yaml` — add `custom.h` and `ble.h` as entry-points so
  `dc_custom_open`/`dc_custom_cbs_t`/`DC_IOCTL_BLE_GET_NAME` get bound into
  `dive_computer_ffi_bindings_generated.dart`.
- `pubspec.yaml` — add `universal_ble` dependency.

## Data flow, end to end

1. Main isolate: user picks a scanned device (already filtered to a known
   `BleProfile`). `BleTransport.connect()` opens the GATT connection,
   discovers services, subscribes to notifications.
2. Main isolate: `BleBridge.allocate()`, then sends `(computer,
   ComputerTransport.ble, bridge.address, lastFingerprint)` to the
   background isolate.
3. Background isolate: reconstructs the bridge, calls `dc_custom_open(...,
   DC_TRANSPORT_BLE, callbacks, bridge.pointer)`, then `dc_device_open` /
   `dc_device_foreach` as today — these block the isolate's thread.
4. Inside that blocking call, libdivecomputer invokes our `write` callback
   to send a protocol command → the callback copies bytes into the mailbox,
   bumps `writeSeq`, pings the main isolate via `SendPort`, then spin-polls
   `writeAckSeq` until it matches (bounded by the current timeout).
5. Main isolate: receives the ping (or the periodic tick fires regardless),
   performs the `universal_ble` write, sets `writeAckSeq`.
6. The device responds asynchronously; the main isolate's notification
   handler pushes bytes into the ring buffer as they arrive.
7. The background isolate's `read`/`poll` callbacks spin-poll the ring
   buffer, return bytes to libdivecomputer, which parses the response and
   continues the protocol — steps 4-7 repeat per exchange — until all dives
   are downloaded.
8. `dc_device_close` → our `close` callback sets `closed`. The main
   isolate's loop observes it, disconnects `universal_ble`, cancels the
   timer. The background isolate signals "done touching the pointer" (in a
   `finally`, so this fires on error too) before returning the downloaded
   dives as it does today; only then does the main isolate free the bridge
   memory.

## Defensive measures & logging

- **Bounded waits everywhere.** Every spin-poll (read/poll/write-ack) is
  bounded by the current `set_timeout` value, with a hard-cap fallback
  (e.g. 30s) if libdivecomputer ever requests an indefinite block — a
  silent BLE drop can never hang the isolate forever. Every loop iteration
  re-checks `closed`, so a detected disconnect interrupts a wait
  immediately instead of waiting out the full timeout.
- **Typed, specific failures**, not one generic `Exception`: device-not-
  found, connect-failed, service/characteristic-mismatch (the most likely
  real-world failure before the `BleProfile` table is battle-tested —
  logged at `warning` with the mismatched UUIDs), mid-transfer disconnect,
  ring-buffer overflow, protocol timeout.
- **Ring-buffer overflow is a logged, surfaced error**, not silent data
  corruption: on overflow, log `severe` with byte counts and return
  `DC_STATUS_IO` rather than overwriting unread data.
- **Connect retry with backoff** (bounded, e.g. 3 attempts) — BLE stacks,
  especially on Windows, are flaky; one failed attempt shouldn't be
  terminal.
- **No leaks, explicit two-phase teardown** for the malloc'd bridge memory
  (background isolate signals done-with-pointer before main isolate frees
  it — see Data flow step 8). `closeConnection()`/dispose paths tear down
  the GATT connection, cancel the timer, and unsubscribe notifications even
  on a failed/cancelled download, not just the happy path.
- **Single-flight guard** — `DiveComputer` is a singleton; a second BLE
  connect attempt while one is in flight is rejected with a clear error
  instead of racing.
- **Verbose logging gated behind the existing `enableDebugLogging()`
  switch**, reusing the `logging` package convention already in
  `dive_computer_ffi.dart`: `finest` for raw hex dumps of every read/write
  chunk (the primary debugging tool before real hardware is available),
  `fine` for connect/discover/subscribe/profile-match events, `warning` for
  retries/timeouts, `severe` for unrecoverable failures. One switch
  controls both the native libdivecomputer log level and this new BLE-layer
  logging.
- **Never write to a device outside the intended profile.** Scanning only
  surfaces devices matching a known `BleProfile`; there is no code path
  that performs a GATT write against an unrecognized/unconfirmed
  characteristic. This also governs the Tier 0 test below.

## Testing strategy

No dive-computer hardware is available yet. A Garmin watch is available as
a generic BLE peripheral, but is not a dive computer and must only be used
read-only (see Tier 0) — never as a target for writes, since we don't
control its firmware or GATT contract.

- **Tier 0 — connectivity smoke test (near-zero cost, do this early,
  before writing the bridge).** Using the Garmin watch purely as "some real
  BLE peripheral," confirm `universal_ble` can scan for it, connect, and
  `discoverServices()` on the target Windows machine. Read-only — no writes
  to any characteristic. This de-risks the biggest unknown (does
  Windows/WinRT BLE via this plugin work at all, here) before investing in
  the bridge design.
- **Tier 1 — automated, no hardware.** Unit tests for `BleBridge`'s
  ring-buffer/mailbox protocol: a fake "main-isolate side" (plain Dart, no
  real BLE) feeds/drains the shared memory, verifying read/write/poll/
  timeout/overflow/close semantics and the absence of races. This is the
  highest-bug-risk code in the whole feature and the only part with full
  automated coverage this round.
- **Tier 2 — manual smoke test, cheap controlled hardware.** Once a
  peripheral we fully control is available (an ESP32 running a Nordic UART
  sketch, or nRF Connect's GATT-server/peripheral simulator on an Android
  phone), validate `BleTransport` + `universal_ble` end-to-end on Windows:
  scan → connect → discover → write → receive notifications through the
  bridge, via a trivial echo test independent of libdivecomputer.
- **Tier 3 — real dive computer validation.** Deferred until hardware is
  available. This is also where the `BleProfile` table gets its first
  real-world confirmed entry.

## Open questions / follow-up work (explicitly out of scope this round)

- Per-vendor `BleProfile` table beyond the one placeholder entry.
- Manual "unrecognized device" override UX.
- Android-side validation (this round targets Windows first, per explicit
  decision at the start of this design), including the Android 12+ runtime
  permission flow (`BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT`, plus location
  permission on older Android versions) that BLE scanning requires there
  and Windows does not — a likely source of silent scan/connect failures if
  not handled explicitly.
- Tuning the ring buffer's exact capacity and the spin-poll interval
  against real protocol traffic once hardware is available.
