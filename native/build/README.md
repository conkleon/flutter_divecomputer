# `native/build/` — vendoring recipe for libdivecomputer

This directory is a committed, reproducible recipe for rebuilding the vendored
`libdivecomputer` binaries under `native/lib/`. It exists so a version bump is a
handful of edits to `libdivecomputer.env` plus three script runs, instead of an
undocumented hand-build.

Everything here runs in **WSL Ubuntu**. The scripts download into and build
inside the WSL home directory (`~/…`); only the final artefacts are copied back
to `native/lib/…`. Building directly on `/mnt/d` trips libtool on path/case
issues, so don't.

## Prerequisites

- **WSL Ubuntu** (22.04 is what this was built against).
- A one-time toolchain install (needs `sudo`):

  ```sh
  wsl sudo apt-get update && wsl sudo apt-get install -y \
    mingw-w64 mingw-w64-tools patchelf unzip file binutils
  ```

  `gcc`, `make`, `curl`, `sed`, `tar`, `sha256sum` are already on the stock WSL
  image.
- **~6 GB free in the WSL home** for the Android NDK (~630 MB zip, ~4 GB
  unpacked) plus the per-ABI build trees.

## What it produces

The scripts rebuild these binaries and **only** these:

- `native/lib/windows_x64/libdivecomputer-0.dll`
- `native/lib/android/arm64-v8a/libdivecomputer.so`
- `native/lib/android/armeabi-v7a/libdivecomputer.so`
- `native/lib/android/x86/libdivecomputer.so`
- `native/lib/android/x86_64/libdivecomputer.so`

Kept byte-for-byte (never rebuilt here): `native/lib/windows_x64/libusb-1.0.dll`,
`native/lib/windows_x64/libhidapi-0.dll`, and everything under
`native/lib/macos/`. Nothing else in `native/` is touched.

Intermediate downloads and build trees live in `native/build/.work/`, which is
git-ignored.

## How to run

In order, each from a fresh WSL invocation:

```sh
wsl.exe -e bash -lc 'cd /mnt/d/Documents/GitHub/nautilus/flutter_divecomputer/native/build && bash fetch.sh'
wsl.exe -e bash -lc 'cd /mnt/d/Documents/GitHub/nautilus/flutter_divecomputer/native/build && bash build-android.sh'
wsl.exe -e bash -lc 'cd /mnt/d/Documents/GitHub/nautilus/flutter_divecomputer/native/build && bash build-windows.sh'
```

- `fetch.sh` — downloads + sha256-verifies + extracts the release tarball into
  `.work/src/libdivecomputer-<LDC_VERSION>/`, and asserts the Mares Sirius
  descriptor row is present in `src/descriptor.c`. Idempotent (re-uses a cached,
  verified tarball).
- `build-android.sh` — cross-compiles all four ABIs against the NDK, then
  `patchelf` + strip + sanity-check into `native/lib/android/<abi>/`.
  (Added in Task 2.)
- `build-windows.sh` — cross-compiles the DLL with MinGW against the existing
  vendored `libusb`/`hidapi` import libs, then strip + sanity-check into
  `native/lib/windows_x64/`. (Added in Task 3.)

## How to verify a result

- Each script self-checks and **exits non-zero on failure** — a clean exit is
  the first gate.
- The **git diff of `native/lib/`** is the review surface: expect only the five
  binaries above to change, and only by an order-of-magnitude-stable size shift.
- Re-run `flutter test` afterwards (the Dart test suite loads no native library,
  so it should stay green regardless; run it to confirm nothing else moved).
- For a real functional check the rebuilt Android `.so` has to be exercised
  on-device (see the plan's Task 7).

## Windows DLL import baseline (libdivecomputer 0.9.0-devel snapshot)

Captured from the pre-bump `native/lib/windows_x64/libdivecomputer-0.dll` with
`objdump -p … | grep -i "DLL Name" | sort`:

```
DLL Name: ADVAPI32.dll
DLL Name: KERNEL32.dll
DLL Name: WS2_32.dll
DLL Name: libhidapi-0.dll
DLL Name: libusb-1.0.dll
DLL Name: msvcrt.dll
```

A future rebuild must keep this exact set (`msvcrt` = MinGW, never an MSVC
runtime). `build-windows.sh` enforces it. Diff a new build's import list against
this block before committing.

## Bumping the libdivecomputer version

1. Edit the pinned values at the top of `libdivecomputer.env`: `LDC_VERSION`,
   `LDC_TARBALL_URL`, `LDC_TARBALL_SHA256`, and — if the toolchain moves —
   `NDK_URL` / `NDK_SHA256` / `NDK_DIR`.
2. Re-run all three scripts (`fetch.sh`, `build-android.sh`, `build-windows.sh`)
   via `wsl.exe -e bash -lc 'cd …/native/build && bash <script>'`.
3. Regenerate the ffigen bindings: `flutter pub run ffigen --config ffigen.yaml`.
4. Review the binding diff for renamed/removed symbols; update
   `lib/framework/dive_computer_ffi.dart` for any API changes.
5. Run `flutter analyze && flutter test`.
6. If libtool emits a different DLL interface number (e.g. `libdivecomputer-1.dll`),
   update both the `cp` target in `build-windows.sh` and the bundled-library list
   in `windows/CMakeLists.txt`, and note it in `CHANGELOG.md`.

## Known gap: macOS

The macOS `.dylib` files under `native/lib/macos/` are **not** rebuilt by this
recipe (no macOS cross-toolchain in WSL). They remain the older `0.9.0-devel`
snapshot, so any dive computer added in the `0.9.0` release — the Mares Sirius
included — will not resolve on macOS. macOS is not an actively targeted platform;
rebuild the `.dylib` on a Mac if that changes.
