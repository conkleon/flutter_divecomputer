# SP1 — Unified sync API + progress + pump swap for flutter_divecomputer — design

**Date:** 2026-08-30
**Status:** design agreed; ready for implementation plan
**Roadmap context:** `docs/superpowers/specs/2026-08-30-plugin-redesign-roadmap.md` (SP1 of SP1–SP4)

## Goal

Replace the overloaded `download()` entry point with one blessed `sync(SyncRequest)`
call that returns a structured `SyncResult` and drives two broadcast streams
(`syncProgress`, `diveStream`). Wire libdivecomputer's real progress events into
`SyncProgress`. Replace the fragile `Timer.periodic(4ms)` mailbox pump with
event-driven cross-isolate write signalling, extracting the duplicated
BLE/RFCOMM servicing code into a shared `BridgedTransport` base.

The old entry points keep working as `@Deprecated` shims through SP2/SP3; a
migration guide ships with this change.

Out of scope for SP1 (stays in SP2+): resumable full sync / vendor block-level
download, adaptive connection profiles, per-vendor timeout tuning, background
sync.

## Background

### Why this is needed

`download()` has grown to six positional-optional parameters:

```dart
Future<List<Dive>> download(
  Computer computer,
  ComputerTransport transport, [
  String? lastFingerprint,
  String? address,
  void Function(Dive dive)? onDive,
  Iterable<String>? knownFingerprints,
]);
```

Callers must remember the positional order, there is no place to hang sync
status or counts, progress is invisible (the example app fakes it with a
per-dive text update), and BLE requires a separate `connectBle()` first while
serial/Classic pass `address` inline. The singleton juggles four nullable
`Completer` fields and an `_onDive` callback slot to route one download's
results, with ad-hoc guards against concurrent calls.

### What libdivecomputer provides for progress

`dc_device_set_events(device, events, callback, userdata)` registered before
`dc_device_foreach`:

- `DC_EVENT_PROGRESS` → `dc_event_progress_t { unsigned int current, maximum }`.
  Fired frequently (roughly per protocol packet) during the device transfer.
  `maximum` can be `0` early on and can grow as the device reports more.
- `DC_EVENT_DEVINFO` → `dc_event_devinfo_t { unsigned int model, firmware, serial }`.
  Fired once near the start.

The event callback runs **synchronously inside `dc_device_foreach`** on the
background isolate — the same execution context as the existing dive callback
and the bridge's `write` callback. It must not block.

### The isolate-bridge constraint (unchanged from the BLE/BT design)

libdivecomputer runs on a background isolate (blocking FFI). BLE (`universal_ble`)
and Android RFCOMM (method channel) I/O must run on the main isolate. They are
connected by `BleBridge` — shared native memory (a lock-free inbound ring
buffer + a single-slot outbound mailbox) whose `.address` is passed across the
isolate boundary. See `docs/superpowers/specs/2026-08-29-bluetooth-classic-rfcomm-transport-design.md`.

While the background isolate is inside a synchronous libdivecomputer callback it
cannot run its own event loop — but `SendPort.send()` from that context still
delivers to the *receiving* isolate's event loop. The receiver does not depend
on the sender yielding. This is the mechanism SP1 uses to make write signalling
and progress events event-driven instead of polled.

### Current pump (what we are replacing)

`BleTransport` and `RfcommTransport` each run `Timer.periodic(4ms)` on the main
isolate. Every 4 ms it reads `bridge.pendingWriteSeq` from shared memory; if it
changed, it performs the real device write and `ackOutbound`s via shared memory.
The two implementations are ~80% identical (`_serviceMailbox`, `_writeInFlight`
guard, `_teardown` ordering, the "read the field not the captured param"
dangling-bridge guard). Problems: a 4 ms poll is wasteful and adds latency; the
timer silently stops making progress when the UI isolate is backgrounded
(SP3's concern, but the polling design makes it worse); and the duplication is
a maintenance hazard the BT Classic plan already flagged for extraction.

## Architecture

Three layers change:

1. **Public API** (`DiveComputerInterface` + `DiveComputer` singleton in
   `dive_computer_isolate.dart`): add `sync()`, `syncProgress`, `diveStream`;
   the new value types; `@Deprecated` shims for `download()` / `connectBle()` /
   `disconnectBle()`. One private `_runSync(SyncRequest)` backs both `sync()`
   and the `download()` shim.

2. **Cross-isolate messaging** (`dive_computer_isolate.dart` ↔ `_spawnIsolate`):
   new message types `_WriteReady(seq)`, `_Progress(current, maximum)`,
   `_DeviceInfo(model, firmware, serial)` from background → main; the main
   isolate's port listener builds `SyncProgress` and feeds the streams,
   coalescing progress to ≤ 1 per 100 ms.

3. **Transport internals** (`lib/framework/transport/`): new `BridgedTransport`
   base owns `attachBridge`, the inbound pump, message-driven write servicing,
   the 250 ms safety-net timer, and teardown ordering. `BleTransport` and
   `RfcommTransport` subclass it and implement only `connect` +
   `writeToDevice` + `inboundBytes` + `closeDevice`.

### Approaches considered

**API shape — chosen: keep the singleton, add streams.** A `DiveComputerSession`
object returned from `connect()` was the roadmap's sketch. Rejected for SP1:
more new surface, and the singleton already *is* the long-lived object
background sync (SP3) can hang off. A static `sync()` function with callbacks
was rejected — nowhere to put connection reuse later.

**Pump swap — chosen: port message + shared-memory ack.** Background isolate
`sendPort.send(_WriteReady(seq))` from inside the sync `write` callback, then
busy-waits on the shared-memory ack as today. Full-duplex-over-ports (inbound
bytes as messages too) was rejected — the `read` callback still can't await a
message from sync code, so the ring buffer stays. Moving transport I/O onto the
background isolate via `BackgroundIsolateBinaryMessenger` is SP3's job.

**Progress detail — chosen: `phase + raw counts + divesParsed`.** A single
`fraction` was too lossy (can't tell connecting from transferring). A sealed
`SyncEvent` hierarchy replacing both streams was more than SP1 needs; revisit if
SP2 wants it.

**SyncResult — chosen: stream-only, counts in the result.** Each `Dive` carries
~2000 `Sample` objects and is already copied across the isolate once when
streamed. Putting the full `List<Dive>` in `SyncResult` too doubles the retained
memory on a 600-dive Petrel. Callers that want the list accumulate from
`diveStream` (the `download()` shim does exactly this).

## Components

### New value types — `lib/types/sync.dart` (new)

```dart
class SyncRequest {
  SyncRequest({
    required this.computer,
    required this.transport,
    this.endpoint,
    this.lastFingerprint,
    this.knownFingerprints,
  });

  final Computer computer;
  final ComputerTransport transport;

  /// COM port (serial), BT MAC (Classic), or BLE device id. May be null only
  /// for the single-serial-port auto-pick case libdivecomputer already
  /// supports. For `ComputerTransport.ble`, null falls back to a device set by
  /// a prior (deprecated) `connectBle()`.
  final String? endpoint;

  /// Sync ONLY dives newer than the dive with this fingerprint hash. The device
  /// stops transmitting once it reaches it (libdivecomputer
  /// `dc_device_set_fingerprint` — forward incremental, a real early stop).
  /// Use for "top up my log with new dives".
  final String? lastFingerprint;

  /// Dive fingerprint hashes the caller already holds. The device still
  /// transfers every dive's bytes, but parse + `diveStream` emit are skipped
  /// for these. Poor-man's resume for an interrupted full backfill. Combinable
  /// with `lastFingerprint`.
  final Set<String>? knownFingerprints;
}

enum SyncPhase { connecting, reading, parsing, done }

class SyncProgress {
  const SyncProgress({
    required this.phase,
    required this.current,
    required this.maximum,
    required this.divesParsed,
  });

  final SyncPhase phase;

  /// Raw byte counts from libdivecomputer `DC_EVENT_PROGRESS`. `maximum` may be
  /// 0 before the device reports a total, and may grow. Guard before dividing.
  final int current, maximum;

  /// Running count of dives emitted on `diveStream` this run.
  final int divesParsed;

  double? get fraction => maximum > 0 ? current / maximum : null;
}

enum SyncStatus { completed, stoppedAtKnownDive, failed }

class SyncResult {
  const SyncResult({
    required this.status,
    required this.divesParsed,
    required this.divesSkipped,
    required this.fingerprints,
    this.error,
  });

  final SyncStatus status;

  /// Dives emitted on `diveStream` this run (excludes `knownFingerprints` hits).
  final int divesParsed;

  /// Dives whose fingerprint matched `knownFingerprints` — bytes transferred,
  /// parse skipped.
  final int divesSkipped;

  /// Every dive fingerprint hash seen this run (parsed + skipped), newest
  /// first. Persist this as the next run's `knownFingerprints`.
  final List<String> fingerprints;

  /// Set only when `status == SyncStatus.failed`.
  final Object? error;
}
```

Exported from `lib/dive_computer.dart`.

### `DiveComputerInterface` — `lib/framework/dive_computer_interface.dart`

Add:

```dart
Future<SyncResult> sync(SyncRequest request) => throw UnimplementedError();
Stream<SyncProgress> get syncProgress => throw UnimplementedError();
Stream<Dive> get diveStream => throw UnimplementedError();
```

Annotate the existing `download` with
`@Deprecated('Use sync(SyncRequest). download() will be removed in a future major version.')`.
`connectBle` / `disconnectBle` get the same annotation pointing at `sync()`.

### `DiveComputer` singleton — `lib/framework/dive_computer_isolate.dart`

**Streams.** Two `StreamController<T>.broadcast()` created in the constructor,
closed in... never (singleton lives for the app). Events are scoped to the
current run by the port listener; there is no per-run controller.

**Concurrency guard.** One `bool _syncInFlight`. `sync()` sets it synchronously
at entry (throws `StateError` if already set), clears it in a `finally`.
Replaces `_downloadedDives` / `_onDive` juggling. The enumeration completers
(`_supportedComputers`, `_serialPorts`, `_bluetoothDevices`) stay as they are.

**`sync()` flow:**

1. Guard `_syncInFlight`. Emit `SyncProgress(phase: connecting, 0, 0, 0)`.
2. For `ble` / Android `bluetooth`: allocate `BleBridge`, `connect()` +
   `attachBridge()` the transport (BLE connect is now folded in — resolve the
   `endpoint` to a `BleScanResult`, or use the device from a deprecated
   `connectBle()`). Existing pre-send failure handling (dispose bridge, no
   `_BleBridgeReleased` wait) is preserved.
3. `_send((DiveComputerMethod.sync, [request fields, bridge?.address]))`.
4. `await` a `Completer<SyncResult>`. The port listener completes it.
5. `finally`: `_BleBridgeReleased` handshake (60 s bounded), transport
   disconnect-before-dispose ordering, clear `_syncInFlight`. Unchanged from
   today's `download()` teardown.

**Port listener additions:**

- `_Progress(current, maximum)` → coalesced (see below) into
  `SyncProgress(phase: reading, ...)`.
- `Dive` → `_diveController.add(dive)`; `divesParsed++`; emit
  `SyncProgress(phase: parsing, divesParsed: n)` (also coalesced, but a dive
  always flushes any pending progress).
- `_DeviceInfo(...)` → logged; retained on a private field for a possible
  future `SyncResult.deviceInfo` (not surfaced in SP1).
- `SyncResult` → emit terminal `SyncProgress(phase: done, ...)`, then complete
  the run's `Completer<SyncResult>`.
- Errors from `_errorPort` / an `Error|Exception` message while a sync is in
  flight → complete the run's completer with
  `SyncResult(status: failed, error: ...)`. **The streams do not emit an
  error** (an unhandled broadcast-stream error with no listener crashes the
  zone).

**Progress coalescing.** A `SyncProgress` is emitted at most once per 100 ms
during `reading`/`parsing`. Implementation: keep `_lastProgressEmit` (a
`DateTime`) and `_pendingProgress`; a `Timer` (single, 100 ms, rearmed) flushes
the pending value. Phase changes and the terminal `done` bypass the throttle.

**`download()` shim:**

```dart
@Deprecated(...)
@override
Future<List<Dive>> download(computer, transport,
    [lastFingerprint, address, onDive, knownFingerprints]) async {
  final collected = <Dive>[];
  final sub = diveStream.listen((d) { collected.add(d); onDive?.call(d); });
  try {
    await sync(SyncRequest(
      computer: computer,
      transport: transport,
      endpoint: address,
      lastFingerprint: lastFingerprint,
      knownFingerprints: knownFingerprints?.toSet(),
    ));
    return collected;
  } finally {
    await sub.cancel();
  }
}
```

Note: today's `download()` returns dives even on a mid-transfer throw (the
`onDive` side effect already persisted them). The shim preserves that — `onDive`
fires from the stream during the transfer; on a `failed` result the shim
rethrows `result.error` *after* the caller has already received every dive via
`onDive`. Document this in the migration guide as the one behavioural nuance.

### `_spawnIsolate` — `lib/framework/dive_computer_isolate.dart`

`DiveComputerMethod.download` → `DiveComputerMethod.sync` (or keep the name and
add args — decided in the plan). The handler:

- unpacks the `SyncRequest` fields,
- sets `DiveComputerFfi.diveCallback = (d) => sendPort.send(d)` (unchanged),
- sets `DiveComputerFfi.progressCallback = (c, m) => sendPort.send(_Progress(c, m))`,
- sets `DiveComputerFfi.deviceInfoCallback = (mo, fw, sn) => sendPort.send(_DeviceInfo(mo, fw, sn))`,
- sets `DiveComputerFfi.skipFingerprints` (unchanged),
- calls `DiveComputerFfi.sync(...)` which returns a `SyncResult` (or the data to
  build one on the main side), `sendPort.send(result)`,
- `finally` clears the callbacks + `skipFingerprints`, sends `_BleBridgeReleased`
  if a bridge was used (unchanged).

### FFI layer — `lib/framework/dive_computer_ffi.dart`

- Rename `download()` → `sync()` internally (thin; keeps the same body plus the
  event registration). Add `progressCallback` / `deviceInfoCallback` static
  slots next to `diveCallback`.
- Before `dc_device_foreach`: `dc_device_set_events(device, DC_EVENT_PROGRESS |
  DC_EVENT_DEVINFO, <handler>, <userdata>)`. The handler is a top-level
  `Pointer.fromFunction` like `_dive_callback`; it switches on the event type,
  reads `dc_event_progress_t` / `dc_event_devinfo_t` from the `void*`, and
  calls the matching static callback slot (which does the `sendPort.send`).
  No allocation, no parsing, no logging above `finest` in the handler.
- Track `status`: `DC_STATUS_SUCCESS` from `dc_device_foreach` →
  `SyncStatus.completed`; the `lastFingerprint`-reached early return already
  happens in `_dive_callback` (returns 0) → the whole foreach ends
  `DC_STATUS_SUCCESS`, so distinguish `stoppedAtKnownDive` by "the
  `lastFingerprint` was non-null and we saw a dive whose hash matched it".
  Count `divesParsed` / `divesSkipped` / collect `fingerprints` in the
  callbacks. Build `SyncResult` (or send the tuple and build it on the main
  isolate — plan decides; building on the background isolate and sending the
  finished object is simpler).
- `ffigen.yaml`: ensure `dc_device_set_events`, `dc_event_progress_t`,
  `dc_event_devinfo_t`, `dc_event_type_t` are in the generated bindings (they
  likely already are — verify).

### Transport refactor — `lib/framework/transport/` (new dir)

Move `lib/framework/ble/ble_transport.dart` → `lib/framework/transport/ble_transport.dart`
and `lib/framework/rfcomm/rfcomm_transport.dart` →
`lib/framework/transport/rfcomm_transport.dart`. New
`lib/framework/transport/bridged_transport.dart`:

```dart
abstract class BridgedTransport {
  BleBridge? _bridge;
  StreamSubscription<Uint8List>? _inboundSub;
  Timer? _safetyNetTimer;
  int _lastServicedWriteSeq = 0;
  bool _writeInFlight = false;

  // --- subclass responsibilities ---
  Future<void> writeToDevice(Uint8List bytes);
  Stream<Uint8List> get inboundBytes;
  Future<void> closeDevice();
  bool get isDeviceConnected;

  // --- base owns ---
  void attachBridge(BleBridge bridge) { /* wire _inboundSub, arm safety net */ }
  Future<void> serviceMailbox() { /* the current _serviceMailbox body, minus
                                    the "did seq change" poll — the caller
                                    (message OR safety net) is the trigger */ }
  void handleDisconnect() { _bridge?.markClosed(); teardown(); }
  Future<void> teardown() { /* cancel timer + sub, closeDevice ordering,
                              null _bridge — the existing UAF-safe order */ }
}
```

- `attachBridge` subscribes `inboundBytes` → `bridge.pushInbound` (with the
  overflow log and the read-the-field dangling guard), and arms
  `Timer.periodic(const Duration(milliseconds: 250), (_) => serviceMailbox())`
  as the safety net only.
- `serviceMailbox()` keeps the `_writeInFlight` guard and the
  "capture seq before the await, ack that seq not the current one" rule.
- `BleTransport`: keeps `connect()` (retry loop + service/characteristic
  resolution), implements `writeToDevice` (GATT write with `_writeWithResponse`),
  `inboundBytes` (`subscribeNotifications`), `closeDevice`, `isDeviceConnected`.
- `RfcommTransport`: keeps `connect(address)`, implements the four members over
  `RfcommChannel`.

### Main-isolate write signalling — `dive_computer_isolate.dart`

The `_WriteReady(int seq)` message from the background isolate is handled in the
port listener: `_activeBridgedTransport?.serviceMailbox()`. The
`DiveComputer` singleton holds a reference to whichever `BridgedTransport` the
current sync attached (it already holds `_bleTransport` and `_rfcommTransport`).

### Background-isolate write callback — `lib/framework/ble/ble_bridge_callbacks.dart`

In the `write` callback (`BleBridgeCallbacks`), after `queueOutbound` bumps
`writeSeq` and before entering the `waitForWriteAck` busy-wait: the callback
needs a `SendPort` to signal on. Options (plan decides):

- Pass the main isolate's `SendPort` into the FFI layer when the sync starts and
  stash it in a static the `write` callback reads (`DiveComputerFfi.hostPort`).
- The `write` callback calls `DiveComputerFfi.hostPort?.send(_WriteReady(seq))`.

The 250 ms safety net covers the window before `hostPort` is set and any lost
message.

### `lib/dive_computer.dart`

Add `export 'types/sync.dart';`. No removals.

### Example app — `example/lib/main.dart`

Migrated in the same PR as the reference consumer:

- The Bluetooth flow: after the bonded-device pick, call
  `dc.sync(SyncRequest(computer: computer, transport: ComputerTransport.bluetooth,
  endpoint: picked.address, knownFingerprints: known))`.
- Replace the manual per-dive status string with a `StreamBuilder<SyncProgress>`
  on `dc.syncProgress` — a real `LinearProgressIndicator` when `fraction != null`,
  the phase name + `divesParsed` otherwise.
- The JSONL append moves to a `dc.diveStream.listen(...)` subscription set up
  before `sync()` and cancelled after.
- `SyncResult` drives the final status text (`status`, `divesParsed`,
  `divesSkipped`).
- The BLE debug screen: `connectBle` + `download` → a single `sync()` with
  `transport: ble`, `endpoint: device.id`. Keep the explicit "Connect &
  download" button (it just calls `sync()` now); drop the separate
  `disconnectBle()` in `finally` (sync owns the lifecycle).

## Data flow — a full Classic sync with progress (Android)

```
main isolate                         background isolate
------------                          -----------------
sync(req)
  guard _syncInFlight
  emit SyncProgress(connecting)
  bridge = BleBridge.allocate()
  rfcommTransport.connect(addr)
  rfcommTransport.attachBridge(bridge)  ── arms 250ms safety net, subs inbound
  _send(sync, [..., bridge.address])  ─────────────►  DiveComputerFfi.sync(...)
                                                        register dc_device_set_events
                                                        dc_device_foreach:
  ◄──────────────── _Progress(c, m) ◄───────────────     PROGRESS event → hostPort.send
  coalesce → emit SyncProgress(reading, c, m, n)
  ◄──────────────── Dive ◄──────────────────────────     dive parsed → sendPort.send
  diveStream.add(dive); n++
  emit SyncProgress(parsing, .., n)
                                                        write callback:
                                                          queueOutbound → writeSeq++
  ◄──────────────── _WriteReady(seq) ◄──────────────       hostPort.send(_WriteReady)
  activeBridgedTransport.serviceMailbox()                  busy-wait on writeAckSeq
    writeToDevice(bridge.pendingOutbound)
    bridge.ackOutbound(seq, SUCCESS)  ──(shared mem)──►  ack seen → callback returns
                                       ... repeat ...
  ◄──────────────── SyncResult ◄────────────────────     foreach done
  emit SyncProgress(done)                                 finally: send _BleBridgeReleased
  ◄──────────────── _BleBridgeReleased ◄────────────
  complete Completer<SyncResult>
  finally: rfcommTransport.disconnect(); bridge.dispose(); _syncInFlight = false
sync() returns SyncResult
```

## Testing

### Unit — value types & singleton logic (no device)

- `SyncProgress.fraction`: `maximum == 0` → null; `maximum` grows across events →
  monotonic-ish, never throws.
- Progress coalescing: 1000 synthetic `_Progress` in 50 ms → ≤ ~3 `SyncProgress`
  emissions; every phase change and the terminal `done` pass through.
- Concurrency guard: second `sync()` while one is in flight → `StateError`, the
  first sync's result is unaffected.
- `download()` shim over a fake `_runSync` that emits N dives then a `completed`
  result → returns `List<Dive>` length N, `onDive` called N times in order.
- `download()` shim over a fake `_runSync` that emits 2 dives then a `failed`
  result → `onDive` called twice, then the shim rethrows `result.error`.
- `SyncStatus` mapping: `lastFingerprint` matched a seen dive →
  `stoppedAtKnownDive`; foreach threw → `failed` with `error` set, **no stream
  error emitted** (attach a listener that fails the test on error).
- `SyncResult.fingerprints` ordering + `divesSkipped` count against a
  `knownFingerprints` set.

### Unit — `BridgedTransport` base (fake transport)

- `serviceMailbox()` invoked by a `_WriteReady` → exactly one `writeToDevice`,
  `ackOutbound` with the captured seq.
- `writeSeq` bumped mid-write (simulated retry) → no second concurrent
  `writeToDevice` (`_writeInFlight`).
- ack uses the seq captured before the await, not the current `pendingWriteSeq`.
- safety-net timer alone services a write when `_WriteReady` is withheld.
- `teardown()` ordering: `closeDevice` before the bridge is considered gone;
  an inbound event delivered after `teardown()` is a no-op (field read, not
  captured param).

### Existing tests

- `ble_bridge_state_test.dart:100` timing flake ([[flaky-ble-bridge-state-test]])
  — leave as-is; the refactor must not paper over it.
- BLE / RFCOMM transport tests retargeted onto `BridgedTransport` where the
  behaviour moved to the base.

### On-device (manual, Tier 2 — user's Shearwater Petrel + Pixel over BT Classic)

1. Full sync from empty: progress bar advances, `divesParsed` climbs, completes
   with `status: completed`.
2. `lastFingerprint` set to the newest dive's hash → `status:
   stoppedAtKnownDive`, only new dives (or none) on `diveStream`.
3. Interrupt a full sync, re-run with `knownFingerprints` = the saved hashes →
   `divesSkipped` > 0, transfer still takes the full wire time (expected — SP2),
   `diveStream` only emits the not-yet-saved dives.

## Non-goals (SP1)

- Resumable full sync that skips the wire re-transmit (vendor block-level
  download) — SP2.
- `SyncProgress.deviceInfo` / exposing model/firmware/serial — captured
  internally, surfaced later.
- Per-vendor timeout / connection-profile tuning, BLE auto-reconnect — SP2.
- Background / screen-off sync survival — SP3.
- `DiveComputerSession` object, multiple concurrent sessions.
- Removing the deprecated shims — a later major, after SP4.
- Repo-wide `dart format`, dartdoc-completeness pass, `pubspec` metadata — SP4.

## Risks / open questions

- **`SendPort` availability in the `write` callback.** The background isolate's
  `write` callback needs the main isolate's `SendPort`. Plan must decide where
  it's stashed (`DiveComputerFfi.hostPort` static, set at sync start) and
  confirm `_WriteReady` delivery latency beats the old 4 ms poll in practice.
  The 250 ms safety net bounds the worst case.
- **`stoppedAtKnownDive` detection.** `dc_device_foreach` returns
  `DC_STATUS_SUCCESS` whether it ran out of dives or the callback stopped it at
  `lastFingerprint`. We infer the status from "was `lastFingerprint` non-null
  and did a dive's hash equal it". If a device with `lastFingerprint` set simply
  has no newer dives and never emits the matching one, that reports `completed`,
  not `stoppedAtKnownDive` — acceptable (both mean "you're up to date").
- **Broadcast stream with zero listeners.** If a caller uses `sync()` and never
  listens to `diveStream`, the emitted `Dive` events are dropped (fine) but we
  must ensure no `.add` throws. `StreamController.broadcast()` `.add` with no
  listener is a silent no-op — verified behaviour, but cover it in a test.
- **`dc_device_set_events` binding coverage.** Confirm ffigen already emits the
  event structs; if not, a `ffigen.yaml` include + regen is part of the plan.
- **Progress `maximum` semantics per vendor.** Shearwater reports bytes; other
  vendors may report dive counts or nothing. `fraction` returning null is the
  designed fallback; the example must render a sane indeterminate state.

## Files touched

**New:**
- `lib/types/sync.dart`
- `lib/framework/transport/bridged_transport.dart`
- `doc/migration/1.x-to-2.0.md`
- `test/sync_types_test.dart`, `test/bridged_transport_test.dart` (names TBD in plan)

**Moved:**
- `lib/framework/ble/ble_transport.dart` → `lib/framework/transport/ble_transport.dart`
- `lib/framework/rfcomm/rfcomm_transport.dart` → `lib/framework/transport/rfcomm_transport.dart`

**Modified:**
- `lib/framework/dive_computer_interface.dart` — new members, `@Deprecated`
- `lib/framework/dive_computer_isolate.dart` — `sync()`, streams, guard, port
  listener, coalescing, shims
- `lib/framework/dive_computer_ffi.dart` — `sync()`, event registration,
  progress/devinfo/status plumbing, `SyncResult` build
- `lib/framework/ble/ble_bridge_callbacks.dart` — `_WriteReady` send in `write`
- `lib/framework/dive_computer_unsupported.dart` — mirror the new interface
- `lib/dive_computer.dart` — export `types/sync.dart`
- `ffigen.yaml` — event bindings if missing
- `example/lib/main.dart`, `example/lib/ble_download_support.dart` — migrate to
  `sync()` + `syncProgress` + `diveStream`
- existing transport tests — retarget onto `BridgedTransport`
