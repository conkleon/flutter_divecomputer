# flutter_divecomputer

A Flutter plugin that bridges dive computers to Flutter apps. It talks to the
device over USB/serial (and, longer term, Bluetooth Classic/BLE) using
[libdivecomputer](https://www.libdivecomputer.org/), and hands back typed Dart
dive logs — depth/temperature profiles, gas mixes, tank pressures, samples,
and events.

This plugin was built to power dive-log syncing in [Petousis Dive
Log](../nautilus_diving_log) (the "nautilus" app): plug in or pair a dive
computer, pull its stored dives, and hand them to the app to store and sync.
It started as a fork of [DiveNote/dive_computer](https://divenote.app) and is
now maintained standalone for that purpose.

## Purpose

Most dive computers store logged dives on-device and only expose them through
a manufacturer-specific USB cable or, on newer models, Bluetooth. This plugin
exists to hide that mess behind one Dart API:

1. Enumerate the dive computers `libdivecomputer` knows how to talk to.
2. Open a connection to one over whichever transport it supports.
3. Download and parse its dive log into plain Dart objects
   (`Computer`, `Dive`, `Sample`, `Gasmix`, `Tank`, ...).

The rest of the app (Nautilus Dive Log or otherwise) never has to know about
vendor protocols, serial ports, or native memory — it just gets a
`Future<List<Dive>>`.

## Platform support

| Platform | Status | Notes |
|---|---|---|
| Windows | ✅ Supported | Native `libdivecomputer` DLL bundled (`native/lib/windows_x64`). Primary desktop target. Rebuilt from source by `native/build/build-windows.sh` (libdivecomputer 0.9.0). |
| Android | ✅ Supported | Native `.so` bundled for `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`. USB access requires USB-OTG/host mode; BLE is the practical path for most phones (see [Roadmap](#roadmap)). Primary mobile target. Rebuilt by `native/build/build-android.sh` (libdivecomputer 0.9.0, 16 KB-page aligned). |
| macOS | ⚠️ Builds, untested as a target | Native `.dylib` bundled (universal + per-arch), but **not** rebuilt by `native/build/` yet — still the `0.9.0-devel` snapshot, so devices added in the 0.9.0 release (Mares Sirius included) will not resolve on macOS. Not an actively targeted platform. |
| iOS | ⚠️ Declared, not functional | `pubspec.yaml` registers it as an FFI plugin, but no iOS native binary is built/bundled yet. |
| Web | ❌ Not supported | `libdivecomputer` is a native C library invoked via `dart:ffi` in a background `Isolate`. Browsers can't load native code or spawn OS isolates, so the web build compiles against a stub (`dive_computer_unsupported.dart`) whose methods all throw `UnimplementedError`. Bringing dive-computer sync to the web build would mean a separate implementation on top of the [Web Bluetooth](https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API)/[Web Serial](https://developer.mozilla.org/en-US/docs/Web/API/Web_Serial_API) APIs, not this plugin's FFI path. |

## Roadmap

- **USB/serial transport — done.** `ComputerTransport.serial` is implemented
  end-to-end (`DiveComputerFfi.download` → `_connectSerial`) and can already
  enumerate ports and download/parse dives.
- **BLE transport — done.** `ComputerTransport.ble` works on Windows and
  Android via `universal_ble` + a shared-memory isolate bridge into
  libdivecomputer's `dc_custom_open`. Scanning surfaces only devices matching
  a known `BleProfile` (`lib/types/ble_profile.dart`) — Mares (Sirius default), Cressi and
  Shearwater profiles ship, derived from Subsurface and not yet all
  hardware-verified.
- **Bluetooth Classic (RFCOMM/SPP) transport — done for Windows + Android.**
  `ComputerTransport.bluetooth` uses libdivecomputer's `dc_bluetooth_open` on
  Windows and a Kotlin `BluetoothSocket` RFCOMM channel on Android (feeding
  the same isolate bridge). Bonded/paired devices only — no in-app pairing.
  Enables the Bluetooth-Classic-only Shearwaters (Predator, Petrel, Petrel 2,
  NERD, Perdix). Not implemented for iOS/macOS. The Android Kotlin side is
  code-review-verified but not yet built on-device in this repo.
- iOS native binaries (build/bundle `libdivecomputer` for iOS) — not started,
  not currently prioritized.
- Web — out of scope for this plugin; would need a Web Bluetooth/Web Serial
  implementation behind the same `DiveComputerInterface`.

## How it works

- `DiveComputerFfi` (`lib/framework/dive_computer_ffi.dart`) wraps the native
  `libdivecomputer` C API via `dart:ffi`. Bindings are generated with
  [`ffigen`](https://pub.dev/packages/ffigen) from the vendored headers in
  `native/include/libdivecomputer/` — regenerate with:
  ```
  flutter pub run ffigen --config ffigen.yaml
  ```
- Because `libdivecomputer` calls are blocking, `DiveComputer`
  (`lib/framework/dive_computer_isolate.dart`) spawns a background `Isolate`
  and proxies `openConnection` / `closeConnection` / `supportedComputers` /
  `download` calls to it, so the UI thread never blocks on device I/O.
- On web, `dive_computer.dart` conditionally exports
  `dive_computer_unsupported.dart` instead (see [Platform
  support](#platform-support)).
- Downloaded dives are parsed field-by-field and sample-by-sample from
  libdivecomputer's callback-based parser API into the plain Dart types in
  `lib/types/dive.dart`.

## Usage

`download()` is deprecated — see [`doc/migration/1.x-to-2.0.md`](doc/migration/1.x-to-2.0.md) for the new `sync()` API.

```dart
import 'package:dive_computer/dive_computer.dart';

final dc = DiveComputer.instance;
dc.openConnection();

final computers = await dc.supportedComputers;
final sub = dc.diveStream.listen((dive) {
  // persist each dive as it arrives
});
final result = await dc.sync(SyncRequest(
  computer: computers.first,
  transport: computers.first.transports.first,
  lastFingerprint: lastKnownFingerprint,
));
await sub.cancel();

dc.closeConnection();
```

See `example/lib/main.dart` for a minimal runnable app that lists supported
computers and downloads dives from one on tap.

## Installation

From the plugin directory:

```
flutter pub get
```

To run the example app:

```
cd example
flutter run -d windows   # or -d android, -d macos
```

---

### Acknowledgements

This project is a fork of the Flutter plugin
[DiveNote/dive_computer](https://divenote.app) by Sebastian Schneider,
repurposed to sync dive logs into the Petousis/Nautilus Dive Log app.

Parts of this project use the library
[libdivecomputer](https://www.libdivecomputer.org/).

> libdivecomputer Copyright (c) 2008 Jef Driesen

<sup>The library is licensed under the GNU Lesser General Public License version 2.1.</sup>
