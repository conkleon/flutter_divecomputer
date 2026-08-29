# flutter_divecomputer — redesign roadmap (SP1–SP4)

**Date:** 2026-08-30
**Status:** roadmap agreed; SP1 not yet brainstormed

**Next major effort for `flutter_divecomputer`** (agreed 2026-08-29). The Bluetooth Classic transport is shipped (`docs/superpowers/specs/2026-08-29-bluetooth-classic-rfcomm-transport-design.md`); per-dive streaming + skip-fingerprints landed 2026-08-30 (see below). This is the plan for the rest.

## Git state (2026-08-30)
- Local `main` @ `387f695` — baseline (BT Classic transport + Shearwater BLE profiles + serial picker + Gradle modernisation + on-device RFCOMM fixes) PLUS the per-dive-stream work (merged 2026-08-30): `download()` `onDive` callback (per-dive streaming across the isolate), `toJson()` on all `Dive` types, `download()` `knownFingerprints` arg (skip re-parse), example JSONL save + dedupe-append + share, example drops `enableDebugLogging()`. All verified on the user's Petrel (600+ dives).
- `origin/main` @ `714651a` — the user pushed the BT-Classic baseline; local `main` is 2 commits ahead (the per-dive-stream work), UNPUSHED. Ask before `git push`.
- `feat/incremental-dive-stream` branch deleted (merged).

## User's scoping answers (drive the design)
- Audience: **a general, publishable pub.dev-quality plugin** (not nautilus-only).
- Transports: **all three first-class** — serial/USB + BLE + Bluetooth Classic. Windows + Android.
- Sync robustness: **both** incremental (only dives newer than a known fingerprint) **and** resumable full sync.
- Background: **Android foreground service + wakelock + POST_NOTIFICATIONS** so a long sync survives screen-off.

## Decomposition — 4 sub-projects, each its own brainstorm → spec → plan → implement, in order:

**SP1 — Unified device & session API (foundation).** One `DiveComputerDevice` handle (vendor, product, transport, address/id, display name). `DiveComputer.discover({transports})` → `Stream<DiveComputerDevice>` merging libdivecomputer's supported-model list + live serial-port / BLE-scan / bonded-Classic enumeration. `connect(device)` → `DiveComputerSession` with `Stream<SyncProgress>` + `sync({since})`. Deprecate (keep working) the current entry points: `supportedComputers` / `serialPorts` / `scanForBleDevices` / `connectBle` / `bluetoothDevices` / `download`. **Motivation is now concrete:** `download()` is up to 6 positional-optional args (`lastFingerprint, address, onDive, knownFingerprints`) — unwieldy. Migration guide required.

**SP2 — Robust sync engine.** Builds on the `onDive` stream + `knownFingerprints` already in `feat/incremental-dive-stream`.
- **Progress:** wire libdivecomputer's `dc_device_set_events` progress callback → `SyncProgress(done, total, phase)`. Do NOT log per-sample.
- **Incremental (forward):** `download(..., lastFingerprint)` already stops at the first known dive — works today, expose cleanly.
- **Resumable full sync — the hard constraint (learned 2026-08-30):** libdivecomputer's `dc_device_foreach` reads *every dive's full data block off the device* even when the callback skips it. So `knownFingerprints` saves parse CPU + the isolate hop but NOT the wire re-transmit (a Petrel with 98 saved dives still re-sends ~20 MB over BT 2.0 ≈ 25 min before reaching new data). `dc_device_set_fingerprint` only does "stop at the newest known dive" (wrong direction for backfill resume). Truly skipping the re-transmit needs **vendor-specific block-level download** (read the Shearwater dive index, fetch only missing blocks) — decide in SP2's design whether that's in scope or whether "resume = re-run, re-pay the re-send, keep the file" is acceptable.
- **Adaptive connection:** the insecure→secure→reflection RFCOMM chain + early-byte buffer are in the Kotlin already; generalise (BLE reconnect, per-vendor timeout profiles).
- **Replace the `Timer.periodic(4ms)` mailbox pump** — fragile, and stalls when the app backgrounds. Also each `Dive` (~2000 `Sample` objects) is copied across the isolate per dive — a perf cost to design around.

**SP3 — Background sync (Android), hardest.** Foreground service + `WAKE_LOCK` + `POST_NOTIFICATIONS`. Core difficulty: Flutter pauses the UI isolate when backgrounded → the shared-memory bridge stalls (confirmed on-device 2026-08-30: screen-off kills a sync). The sync must run where it isn't paused — a dedicated background isolate the foreground service keeps alive, or move the pump off the UI isolate. Needs its own deep design.

**SP4 — Docs, example, pub.dev readiness.** dartdoc on every public member; **repo-wide `dart format`** (resolves the version-skew debt); README/CHANGELOG rewrite; `pubspec` metadata; migration guide. The example's current Bluetooth flow (discover → pick serial-or-bluetooth → bonded-device picker → sync with a status dialog → JSONL save + dedupe-append + share sheet, no per-sample logging) is a decent reference to build the reworked example from. Also: native `.so` files need 16 KB page alignment for Android 15+ (PageSizeMismatch dialog today).

## How to resume
Brainstorm **SP1** first (`superpowers:brainstorming`). The BT Classic spec (`docs/superpowers/specs/2026-08-29-bluetooth-classic-rfcomm-transport-design.md`) shows the house spec style; its plan is under `docs/superpowers/plans/`. Prior SDD ledger with all rulings: `.superpowers/sdd/2026-08-29-bluetooth-classic-rfcomm-transport/progress.md` (gitignored).
