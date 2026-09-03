# Mares Sirius support via libdivecomputer 0.9.0 — design

**Date:** 2026-09-03
**Status:** Design approved, pending spec review
**Author:** Claude (with conkleon@gmail.com)
**Builds on:**
`docs/superpowers/specs/2026-08-26-ble-transport-design.md` (the BLE transport
and its shared-memory isolate bridge, reused unchanged) and
`docs/superpowers/specs/2026-08-28-mares-cressi-ble-example-design.md` (the
`BleProfile` registry and the example app's descriptor picker, both touched
here).

## Goal

Make the **Mares Sirius** downloadable over BLE on **Android and Windows**.

Today the plugin recognises a Sirius in a BLE scan (the `maresBluelink`
`BleProfile` already lists `'Sirius'`) but cannot download from it: the vendored
native `libdivecomputer` is a pre-release **`0.9.0-devel`** snapshot that has no
Sirius descriptor, so `dc_device_open` cannot resolve a backend. A Sirius owner
can only pick the `Mares Genius` descriptor by hand and hope the `mares_iconhd`
backend copes — it will not, because the Sirius uses a different BLE packet mode
(see Background).

Primary validation target: the **user's own Mares Sirius** on **Android** (the
Pixel 6a), reached either as a BLE-native peripheral or through a Mares BlueLink
Pro dongle.

Secondary, free-of-charge outcome: every other device added between the vendored
snapshot and the `0.9.0` release also becomes selectable — Mares Puck Air 2 /
Quad Ci / Puck 4 / Puck Lite, Shearwater Tern / Peregrine TX, Aqualung i330R /
Apeks DSX, Halcyon Symbios, Scubapro G3, and more. They will appear in
`supportedComputers`; wiring BLE **scan-routing** profiles for them is out of
scope (Non-goals).

## Background

### Why a native-library bump is the only real fix

`mares_iconhd.c` in libdivecomputer `0.9.0` adds the Sirius as model `0x2F`,
family `DC_FAMILY_MARES_ICONHD`, `DC_TRANSPORT_BLE`. The Sirius is not just a new
row in the descriptor table:

- `device->ble = ISSIRIUS(model) ? VARIABLE : FIXED;` — the Sirius runs the
  backend in `VARIABLE` packet mode.
- In `VARIABLE` mode the backend **does not** wrap the iostream in
  `dc_packet_open(&iostream, ctx, iostream, 244, 20)`. It writes command
  payloads straight to the iostream in chunks of `MAXPACKET - 3` bytes and
  expects the transport to handle BLE MTU fragmentation itself.
- `FIXED` mode (Genius, Quad, Smart Air …) uses the 244/20 packet wrapper.

So opening a real Sirius with the `Genius` descriptor drives it through the wrong
(`FIXED`) path. Correct support requires the `0x2F` descriptor and the backend
code that ships with it.

`mares_iconhd.c` issues **no `dc_iostream_ioctl` calls** for the Sirius — there
is no PIN / passkey / access-code handshake at the libdivecomputer layer. Mares
BlueLink pairing is handled by the OS Bluetooth bonding layer, as today.

### What the `0.9.0` release gives us

`libdivecomputer-0.9.0.tar.gz` — released **2025-06-30**,
sha256 `a7b80b9083a2113a43280ee7b51d48d66ea5a779fc3fee57df7c451da0251c65`,
from <https://libdivecomputer.org/releases/>.

- Ships a **pre-generated `configure`** script — no autoconf / automake /
  libtool bootstrap needed, only a C compiler + `make`.
- Descriptor table (`src/descriptor.c`) contains
  `{"Mares", "Sirius", DC_FAMILY_MARES_ICONHD, 0x2F, DC_TRANSPORT_BLE, dc_filter_mares}`.

### API delta: vendored `0.9.0-devel` snapshot → `0.9.0` release

The vendored snapshot is **late** in the `0.9.0` cycle. The scary
"not backwards compatible" items in the release NEWS (sample time in
milliseconds, sample struct by reference, `dc_parser_new` signature changes,
separate USB / USB-HID structs) were **already absorbed** by the snapshot — a
whitespace-insensitive diff of every vendored header against the `0.9.0` headers
shows only:

| Header | Change | Impact on this plugin |
|---|---|---|
| `parser.h` | `DC_FIELD_LOCATION` **appended** to `dc_field_type_t`; new `dc_location_t` struct | None. Enum value is appended (no renumbering); the parser wrapper ignores fields it does not handle. |
| `descriptor.h` | `dc_descriptor_iterator(it)` **replaced** by `dc_descriptor_iterator_new(it, context)`; old name kept as a function-like `#define` macro. `const` added to getter params. | **One call-site fix** (see §3). ffigen does not emit function-like macros, so the `dc_descriptor_iterator` binding disappears on regen. |
| `ble.h` | New ioctls: `DC_IOCTL_BLE_GET_PINCODE`, `..._GET/SET_ACCESSCODE`, `..._CHARACTERISTIC_READ/WRITE`; `dc_ble_uuid_t`, `dc_ble_uuid2str`, `DC_BLE_UUID_SIZE` | Additive. Not needed for the Sirius; regenerated into the bindings and left unused. |
| `common.h` | Two new `dc_family_t` values (`DC_FAMILY_PELAGIC_I330R`, `DC_FAMILY_HALCYON_SYMBIOS = (24 << 16)`) | Additive. Regenerated as constants. |
| `version.h` | `"0.9.0-devel"` → `"0.9.0"` | Cosmetic. |

`device.h`, `iostream.h`, `custom.h`, `iterator.h`, `bluetooth.h`, `context.h` —
**byte-identical** after line-ending normalisation.

### Current native binaries

| File | Deps (confirmed by `readelf` / `objdump`) | Rebuild? |
|---|---|---|
| `native/lib/windows_x64/libdivecomputer-0.dll` | `libhidapi-0.dll`, `libusb-1.0.dll`, `msvcrt`, `WS2_32`, `ADVAPI32`, `KERNEL32` — a **MinGW** build (msvcrt, not vcruntime) | **Yes** |
| `native/lib/windows_x64/libusb-1.0.dll` | — | No — kept byte-for-byte |
| `native/lib/windows_x64/libhidapi-0.dll` | — | No — kept byte-for-byte |
| `native/lib/android/<abi>/libdivecomputer.so` × 4 | `libc`, `libm`, `libstdc++`, `libdl` only — USB/HID already disabled | **Yes** |
| `native/lib/macos/*.dylib` × 3 | — | **No** — out of scope; Sirius will not resolve on macOS (same status as Perdix 3 today) |

## Approaches considered

**Toolchain — chosen: build both targets in WSL.**

Windows has no C compiler (Visual Studio is Installer-only). WSL Ubuntu 22.04 has
`gcc` + `make` but `sudo` needs a password.

- **A — WSL + one `sudo` install (chosen).** The user runs
  `wsl sudo apt-get install -y mingw-w64 mingw-w64-tools patchelf` once
  (`gcc`, `make`, `sed`, `tar` are already present). Then: Windows via
  `x86_64-w64-mingw32-gcc` cross-compile, Android via a Linux NDK unpacked into
  `~` (no sudo). Most reliable libtool behaviour; one manual step.
- **B — all Windows-side, no admin.** Download a standalone winlibs MinGW-w64,
  drive `./configure && make` from Git Bash. Rejected: autotools + libtool under
  the cut-down Git-for-Windows MSYS is fragile.
- **C — spike first.** Rejected: the user chose to commit to a path.

**Sirius `BleProfile` — chosen: keep one `maresBluelink` profile, change its
`productHint`.** A dedicated `maresSirius` profile was considered and rejected:
the Sirius shares the Mares GATT service (`544e326b-…`) and the `mares_iconhd`
family with the rest, and a BlueLink dongle advertises the identical
`'Mares bluelink pro'` name whether it fronts a Sirius or a Puck Pro — a separate
profile could not be selected any more precisely. `productHint` is only the
example app's default pick and is user-overridable.

## Components

### 1. Reproducible build recipe — new `native/build/`

The current binaries were vendored wholesale in the "Initial release" commit with
no build tooling; reproducing them is archaeology. This directory fixes that.

```
native/build/
  README.md            # prerequisites, how to run, how to verify, how to bump
  libdivecomputer.env  # single source of truth: TARBALL_URL, TARBALL_SHA256,
                       # NDK_VERSION, ANDROID_API, the descriptor sanity string
  build-android.sh     # 4 ABIs -> native/lib/android/<abi>/libdivecomputer.so
  build-windows.sh     # cross -> native/lib/windows_x64/libdivecomputer-0.dll
  fetch.sh             # download + sha256-verify + extract the tarball to a
                       # gitignored work dir
```

Design points:

- **Run in WSL**, from the repo root, operating on the Windows-side tree via
  `/mnt/d/...` (or a checkout inside the WSL filesystem — the README states
  which; building in the WSL fs is faster and avoids `\r\n` grief).
- The scripts **write straight into `native/lib/...`**, overwriting the vendored
  binaries. Git diff is the review surface.
- A gitignored work dir (`native/build/.work/`) holds the tarball and
  out-of-tree build trees; `native/build/.gitignore` covers it.
- Each script ends with a **sanity check** and refuses to install a library that
  fails it: the built lib's descriptor list must contain `Mares Sirius`
  (a 30-line `descriptor_dump.c` compiled against the fresh headers + the fresh
  lib, or — where a dump binary cannot run, i.e. the Windows DLL and the
  non-native Android ABIs — a `nm -D` / string check for the `mares_iconhd`
  symbols plus a grep of `src/descriptor.c` in the extracted tree for the exact
  row). The README spells out which check runs where.

**`build-android.sh`** — iterate a table of
`<abi> <configure-host> <clang-prefix>`:

| ABI | `--host` | clang prefix |
|---|---|---|
| `arm64-v8a` | `aarch64-linux-android` | `aarch64-linux-android21` |
| `armeabi-v7a` | `arm-linux-androideabi` | `armv7a-linux-androideabi21` |
| `x86` | `i686-linux-android` | `i686-linux-android21` |
| `x86_64` | `x86_64-linux-android` | `x86_64-linux-android21` |

```
export NDK=$HOME/$NDK_DIR                     # NDK r27+ unpacked by the README's curl step
TOOL=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
export CC=$TOOL/${CLANG_PREFIX}-clang AR=$TOOL/llvm-ar RANLIB=$TOOL/llvm-ranlib STRIP=$TOOL/llvm-strip
./configure --host=$HOST \
  --disable-static --enable-shared --disable-dependency-tracking \
  --without-libusb --without-hidapi \
  CFLAGS="-Os -fPIC -DNDEBUG" \
  LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
make -j
OUT=$REPO/native/lib/android/$ABI/libdivecomputer.so
cp $(readlink -f src/.libs/libdivecomputer.so) $OUT   # the real file behind the .so symlink
patchelf --set-soname libdivecomputer.so $OUT          # see below
$STRIP --strip-unneeded $OUT
```

- `ANDROID_API=21` — matches the plugin's `minSdkVersion 21`.
- `-Wl,-z,max-page-size=16384` is the **16 KB page-alignment fix** for Android
  15+ (was a deferred item). `check-elf-alignment.sh` from the NDK, run in the
  sanity step, must report `ALIGNED`.
- **SONAME.** The vendored `.so` has SONAME `libdivecomputer.so` (no version
  suffix). A stock libtool build emits `libdivecomputer.so.0.0.0` with SONAME
  `libdivecomputer.so.0`, which the Android packager and
  `DynamicLibrary.open('libdivecomputer.so')` do not want. Fix: copy the real
  file to `libdivecomputer.so` and `patchelf --set-soname libdivecomputer.so`
  (Subsurface-mobile does the same). `patchelf` is in the one-time
  `apt-get install` list. The sanity step asserts `readelf -d` shows
  `SONAME libdivecomputer.so`.
- `--without-libserialport` is not needed (not in `0.9.0`); serial is internal
  to libdivecomputer and stays compiled in, matching today's `.so`.

**`build-windows.sh`**:

```
export PATH=/usr/bin  CC=x86_64-w64-mingw32-gcc
# import libs synthesised from the DLLs we are NOT rebuilding:
for d in libusb-1.0 libhidapi-0; do
  gendef $REPO/native/lib/windows_x64/$d.dll         # -> $d.def
  x86_64-w64-mingw32-dlltool -d $d.def -l lib$d.dll.a
done
./configure --host=x86_64-w64-mingw32 \
  --disable-static --enable-shared --disable-dependency-tracking \
  PKG_CONFIG=/bin/false \
  LIBUSB_CFLAGS="-I$WORK/hdr/libusb"  LIBUSB_LIBS="-L$PWD -l:liblibusb-1.0.dll.a" \
  HIDAPI_CFLAGS="-I$WORK/hdr/hidapi"  HIDAPI_LIBS="-L$PWD -l:liblibhidapi-0.dll.a" \
  CFLAGS="-O2 -DNDEBUG"
make -j
cp src/.libs/libdivecomputer-0.dll $REPO/native/lib/windows_x64/libdivecomputer-0.dll
x86_64-w64-mingw32-strip --strip-unneeded $REPO/native/lib/windows_x64/libdivecomputer-0.dll
```

- `libusb.h` / `hidapi.h` headers come from the matching upstream release
  tarballs (URLs + hashes in `libdivecomputer.env`), extracted to
  `$WORK/hdr/...`. We link against the **existing vendored DLLs**, so the ABI
  cannot drift.
- Acceptance: `objdump -p` on the new DLL lists exactly
  `libhidapi-0.dll`, `libusb-1.0.dll`, plus system DLLs
  (`msvcrt`, `WS2_32`, `ADVAPI32`, `KERNEL32`, and whatever else the current one
  imports — the README records the current baseline for comparison).
- libtool names the DLL `libdivecomputer-0.dll` on `mingw32` from the library's
  `-version-info` (interface 0) — matches the vendored filename. If a future
  bump changes the interface number, the script renames and the CMake bundle
  list (`windows/CMakeLists.txt`) is updated in lock-step.

### 2. Vendored headers — `native/include/libdivecomputer/`

Replace all `*.h` with the `0.9.0` release headers (from the same extracted
tarball). The vendored headers are **CRLF**; the tarball ships **LF** — convert
the new headers to CRLF on copy (`sed 's/$/\r/'` or `unix2dos`) so the git diff
is semantic-only. The build recipe's header-copy step does this.

### 3. FFI bindings + the one call-site fix

- **`ffigen.yaml`** — unchanged unless the regen fails to surface
  `dc_descriptor_iterator_new` (it is reached transitively today via `device.h`
  → `descriptor.h`; if not, add `native/include/libdivecomputer/descriptor.h` to
  `entry-points`).
- **Regenerate:** `flutter pub run ffigen --config ffigen.yaml`
  → `lib/framework/dive_computer_ffi_bindings_generated.dart`.
- **Review the regen diff** for any removed/renamed symbol the Dart layer calls.
  Expected removals: `dc_descriptor_iterator` (now a macro). Expected additions:
  `dc_descriptor_iterator_new`, the `ble.h` ioctl constants + `dc_ble_uuid2str`,
  `DC_FIELD_LOCATION`, `dc_location_t`, two `DC_FAMILY_*` constants. Anything
  else is a surprise and must be understood before proceeding.
- **`lib/framework/dive_computer_ffi.dart`**, `supportedComputers` getter
  (currently line ~164):

  ```dart
  //  _bindings.dc_descriptor_iterator(iterator),
      _bindings.dc_descriptor_iterator_new(iterator, ffi.nullptr),
  ```

  `ffi.nullptr` preserves today's exact semantics (the old macro expanded to
  `dc_descriptor_iterator_new(it, NULL)`, and `supportedComputers` can be called
  before `openConnection()` creates the context). A short comment notes that
  `0.9.0` accepts a NULL context here.

### 4. Dart wiring — `lib/types/ble_profile.dart`

- `maresBluelink.productHint`: `'Genius'` → `'Sirius'`.
- `namePatterns` unchanged (`'Mares bluelink pro'`, `'Mares Genius'`, `'Genius'`,
  `'Sirius'`).
- Rewrite the dartdoc paragraph that says *"there is no `Sirius` descriptor in
  this build"* — it is now the default hint. Note `Genius` remains selectable via
  the example's descriptor override for a Genius owner.
- `shearwaterPerdix3` dartdoc says *"The vendored libdivecomputer build
  (0.9.0-devel) has no Perdix 3 descriptor"*. `0.9.0`'s `descriptor.c` still has
  **no Perdix 3** (the family tops out at Peregrine TX, model 13) — keep the
  comment but update the version string to `0.9.0` and the "until the native
  library is updated" framing.

No change to `lib/types/computer.dart`, the isolate, `DiveComputerInterface`, or
the transport-bitmask parser: `supportedComputers` iterates every descriptor with
no allowlist, and `parseTransportsBitmask` already maps `DC_TRANSPORT_BLE` →
`ComputerTransport.ble`. `Mares Sirius [ble]` appears automatically once the lib
has it.

### 5. Example app

No structural change. Confirm the existing descriptor picker lists `Mares Sirius`
and that selecting a scanned BlueLink / Sirius device defaults to it via the
updated `productHint`.

### 6. Docs

- **`CHANGELOG.md`** — new entry: bump to libdivecomputer `0.9.0`; Mares Sirius
  (+ the other newly-selectable models, listed); Android `.so` now 16 KB-page
  aligned; `dc_descriptor_iterator_new` migration; new `native/build/` recipe.
- **`README.md`** — the "How it works" / platform table: state libdivecomputer
  `0.9.0`, point at `native/build/`, and note the macOS `.dylib` is not rebuilt
  by that recipe yet (Sirius unresolved on macOS).
- **`native/build/README.md`** — as described in §1.

## Data flow — Android Sirius download (unchanged transport path)

```
example: scan -> BleProfiles.match("… Sirius"|"Mares bluelink pro")
             -> maresBluelink profile, productHint "Sirius"
             -> user confirms "Mares Sirius" descriptor
DiveComputer.sync(SyncRequest(computer: Mares Sirius, transport: ble, endpoint: <id>))
  isolate: dc_descriptor_iterator_new -> match vendor="Mares" product="Sirius"
           dc_custom_open(DC_TRANSPORT_BLE, <BleBridge callbacks>)
           dc_device_open(mares_iconhd)  -> model 0x2F -> device->ble = VARIABLE
           dc_device_foreach -> mares_iconhd_packet_variable():
               write cmd header (2 B) + payload (<= MAXPACKET-3 B) to iostream
               <-- BleTransport must fragment to the negotiated ATT MTU -->
               read ACK, read object blocks
  parser: dc_parser_new_internal -> per-dive fields + samples (ms units already)
```

The **one place this can break** is the `BleTransport` write path: if it assumes
a 20-byte GATT payload (the `FIXED`-mode packet size) rather than fragmenting an
arbitrary-length `write` to `min(payload, mtu-3)`, a Sirius `VARIABLE` write will
be truncated. Verification §Testing checks this directly; the fix, if needed, is
a bounded follow-up task (fragment writes in `ble_transport.dart` /
`ble_bridge_callbacks.dart` to the negotiated MTU, default 20 only until the MTU
exchange completes).

## Testing

**Static / regen (must pass before hardware):**

- `flutter analyze` — clean.
- `flutter test` — the existing suite: source-level regex guards for the FFI /
  isolate files (house pattern) plus the pure units (`ProgressCoalescer`,
  `SyncRun`, `BridgedTransport`). Add one guard asserting
  `dive_computer_ffi.dart` calls `dc_descriptor_iterator_new` and no longer calls
  `dc_descriptor_iterator(`.
- Build-recipe sanity steps (§1) — each built artefact enumerates `Mares Sirius`;
  the four `.so` files report `ALIGNED` at 16 KB; the new DLL's import table
  matches the recorded baseline.
- A throwaway host smoke test (macOS/Linux `dc` or a 20-line FFI harness): open a
  context, iterate descriptors, assert `Mares Sirius [ble]` is present. Labelled
  throwaway, not committed.

**Hardware — acceptance, on the user's Sirius + Pixel 6a:**

1. `flutter run` the example on the phone.
2. Scan → the Sirius (or its BlueLink dongle) appears and resolves to the
   `Mares Sirius` descriptor by default.
3. `sync()` → connect, read, parse. Watch for: the `VARIABLE`-mode write
   fragmentation (above); progress events advancing; dive count and
   sample/profile data landing in the example's JSONL; sample timestamps sane
   (ms units).
4. A second `sync()` with the first run's fingerprints → incremental early-stop
   still works for this backend.

**Windows — limited (no Visual Studio on the build machine):**

- Cannot `flutter run -d windows` (desktop toolchain absent). Verification is:
  the rebuilt DLL loads under a minimal FFI harness and `supportedComputers`
  lists `Mares Sirius`. A live Sirius-over-Windows-BLE download is **not**
  verified by this work — recorded as a known gap.

## Non-goals

- Rebuilding the macOS `.dylib` (and iOS — still no iOS binaries at all).
- Parsing the new `0.9.0` parser data: `DC_FIELD_LOCATION` (GPS), deco-sample
  TTS, tank/gasmix `usage`, per-ppO2 sensor index. libdivecomputer exposes them;
  `lib/types/dive.dart` does not gain fields here.
- Wiring the new `ble.h` PIN / access-code / characteristic ioctls into the
  transport. The Sirius needs none; some Scubapro / Suunto models do — separate
  effort.
- BLE **scan-routing** `BleProfile` entries for the other devices `0.9.0` makes
  selectable (Aqualung DSX / i330R, Halcyon Symbios, Shearwater Tern, Scubapro
  G3, …). They list in `supportedComputers` but a fresh scan will not
  auto-recognise them until each gets a profile.
- Any change to the isolate mailbox pump, the resumable-sync engine, or the
  redesign roadmap items (SP1–SP4).

## Risks / open questions

1. **`BleTransport` `VARIABLE`-mode framing** (see Data flow). Most likely place
   the hardware test fails; bounded follow-up if so.
2. **MinGW cross-link against raw DLLs.** Mitigated by `gendef` + `dlltool`
   import libs (both ship in `mingw-w64-tools`). If the synthesised import lib
   mis-resolves an ordinal-only export, fall back to linking the `.dll`
   directly (`-l:libusb-1.0.dll`) — MinGW supports it.
3. **libtool DLL naming / SONAME.** Verified today's names come from interface
   version 0; asserted in the sanity step. If a future libdivecomputer bump
   changes `-version-info`, `windows/CMakeLists.txt`'s bundled-library list and
   the Dart `DynamicLibrary.open` name must move together.
4. **ffigen version churn.** The regen may reformat more than the semantic delta
   if the pinned `ffigen` is old. Mitigation: review the full diff; if noise is
   large, pin `ffigen` to the version last used and regen with it.
5. **`--without-libusb --without-hidapi` on Android** — confirm the built `.so`
   still `dlopen`s (no lingering `NEEDED` on a missing lib) and still exports the
   serial + BLE-capable backends. `readelf -d` in the sanity step.
6. **WSL filesystem choice.** Building against `/mnt/d` is slow and can trip
   libtool on path/case issues; the README mandates building inside the WSL fs
   and only copying the final artefacts to `/mnt/d/.../native/lib/`.

## Files touched

| Path | Change |
|---|---|
| `native/build/README.md` | new |
| `native/build/libdivecomputer.env` | new |
| `native/build/fetch.sh` | new |
| `native/build/build-android.sh` | new |
| `native/build/build-windows.sh` | new |
| `native/build/.gitignore` | new (`.work/`) |
| `native/include/libdivecomputer/*.h` | replaced with `0.9.0` release headers |
| `native/lib/windows_x64/libdivecomputer-0.dll` | rebuilt |
| `native/lib/android/arm64-v8a/libdivecomputer.so` | rebuilt (16 KB aligned) |
| `native/lib/android/armeabi-v7a/libdivecomputer.so` | rebuilt (16 KB aligned) |
| `native/lib/android/x86/libdivecomputer.so` | rebuilt (16 KB aligned) |
| `native/lib/android/x86_64/libdivecomputer.so` | rebuilt (16 KB aligned) |
| `lib/framework/dive_computer_ffi_bindings_generated.dart` | regenerated |
| `lib/framework/dive_computer_ffi.dart` | `dc_descriptor_iterator` → `dc_descriptor_iterator_new(it, nullptr)` |
| `lib/types/ble_profile.dart` | `maresBluelink.productHint` → `'Sirius'`; dartdoc updates on `maresBluelink` + `shearwaterPerdix3` |
| `test/` | one regex guard for the new iterator call |
| `ffigen.yaml` | only if regen needs `descriptor.h` added to entry-points |
| `CHANGELOG.md` | new entry |
| `README.md` | libdivecomputer `0.9.0`; `native/build/`; macOS caveat |

Unchanged and explicitly verified so: `windows/CMakeLists.txt` (DLL name stable),
`android/build.gradle` (`jniLibs.srcDirs` unchanged), the isolate, the transport
bridge, `lib/types/computer.dart`, `lib/framework/utils/transports_bitmask.dart`.
