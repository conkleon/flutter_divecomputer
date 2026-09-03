#!/usr/bin/env bash
# Cross-compile libdivecomputer-0.dll for Windows x64 with MinGW against the
# staged 0.9.0 release, linking against the EXISTING vendored
# native/lib/windows_x64/libusb-1.0.dll / libhidapi-0.dll via gendef+dlltool
# import libs (those two DLLs are never rebuilt, so their ABI cannot drift),
# then strip + sanity-check into native/lib/windows_x64/libdivecomputer-0.dll.
#
# Run from WSL Ubuntu:
#   cd native/build && bash build-windows.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/libdivecomputer.env"
need_cmd x86_64-w64-mingw32-gcc; need_cmd gendef
need_cmd x86_64-w64-mingw32-dlltool; need_cmd x86_64-w64-mingw32-strip
need_cmd x86_64-w64-mingw32-nm; need_cmd objdump; need_cmd strings
need_cmd make; need_cmd tar

WORK="$HERE/.work"
SRC="$WORK/src/libdivecomputer-$LDC_VERSION"
[ -x "$SRC/configure" ] || die "run fetch.sh first"
REPO="$(cd "$HERE/../.." && pwd)"
WINLIB="$REPO/native/lib/windows_x64"
[ -f "$WINLIB/libusb-1.0.dll" ]   || die "missing vendored $WINLIB/libusb-1.0.dll"
[ -f "$WINLIB/libhidapi-0.dll" ]  || die "missing vendored $WINLIB/libhidapi-0.dll"

BD="$WORK/build-windows"
rm -rf "$BD"; mkdir -p "$BD/hdr/libusb" "$BD/hdr/hidapi"; cd "$BD"

# --- headers for libusb + hidapi -------------------------------------------
# libdivecomputer's sources do  #include <libusb.h>  and  #include <hidapi.h>
# (src/usb.c:34, src/usbhid.c:50,52), so the headers must sit directly on an
# include path -> extract them flat into hdr/libusb and hdr/hidapi.
fetch_and_verify "$LIBUSB_TARBALL_URL" "$LIBUSB_TARBALL_SHA256" "$WORK/libusb-headers.tar.bz2"
fetch_and_verify "$HIDAPI_TARBALL_URL" "$HIDAPI_TARBALL_SHA256" "$WORK/hidapi-headers.tar.gz"
tar -xjf "$WORK/libusb-headers.tar.bz2" --strip-components=2 -C hdr/libusb --wildcards '*/libusb/libusb.h'
tar -xzf "$WORK/hidapi-headers.tar.gz"  --strip-components=2 -C hdr/hidapi --wildcards '*/hidapi/hidapi.h'
[ -f hdr/libusb/libusb.h ] && [ -f hdr/hidapi/hidapi.h ] || die "header extraction failed"
log "headers: $(ls hdr/libusb/libusb.h hdr/hidapi/hidapi.h)"

# --- import libs synthesised from the DLLs we are NOT rebuilding -----------
# Name them libNAME.dll.a so libtool resolves a plain -lNAME to a *shared*
# import library (a -l:exact.name.a form makes libtool drop the dependency
# and fall back to a static-only build on Windows). -D burns the real DLL
# name into the import lib so the DLL references the vendored file verbatim.
#   libusb-1.0.dll   -> libusb-1.0.dll.a   -> -lusb-1.0
#   libhidapi-0.dll  -> libhidapi-0.dll.a  -> -lhidapi-0
for d in libusb-1.0 libhidapi-0; do
  gendef - "$WINLIB/$d.dll" > "$d.def"
  x86_64-w64-mingw32-dlltool -d "$d.def" -D "$d.dll" -l "$d.dll.a"
  [ -f "$d.dll.a" ] || die "dlltool did not produce $d.dll.a"
done

# --- configure + build ----------------------------------------------------
export CC=x86_64-w64-mingw32-gcc
"$SRC/configure" --host=x86_64-w64-mingw32 \
  --disable-static --enable-shared --disable-dependency-tracking \
  PKG_CONFIG=/bin/false \
  LIBUSB_CFLAGS="-I$BD/hdr/libusb" LIBUSB_LIBS="-L$BD -lusb-1.0" \
  HIDAPI_CFLAGS="-I$BD/hdr/hidapi" HIDAPI_LIBS="-L$BD -lhidapi-0" \
  CFLAGS="-O2 -DNDEBUG" \
  > "$BD/configure.log" 2>&1 || { tail -50 "$BD/configure.log" >&2; die "configure failed"; }

# Non-fatal: the authoritative USB/HID-backend proof is the import-table
# assertion below (libusb-1.0.dll / libhidapi-0.dll must be NEEDED).
grep -qE "for (LIBUSB|libusb).*yes" "$BD/configure.log" || log "WARN: libusb not obviously detected — see $BD/configure.log"
grep -qE "for (HIDAPI|hidapi).*yes" "$BD/configure.log" || log "WARN: hidapi not obviously detected — see $BD/configure.log"

make -j"$(nproc)" > "$BD/make.log" 2>&1 || { tail -60 "$BD/make.log" >&2; die "make failed"; }

BUILT="$(readlink -f src/.libs/libdivecomputer-0.dll 2>/dev/null || true)"
if [ ! -f "$BUILT" ]; then
  log "src/.libs/ contents:"; ls -l src/.libs/*.dll >&2 || true
  die "no built libdivecomputer-0.dll (check the name above; a soname bump also needs windows/CMakeLists.txt)"
fi
cp "$BUILT" "$WINLIB/libdivecomputer-0.dll"
x86_64-w64-mingw32-strip --strip-unneeded "$WINLIB/libdivecomputer-0.dll"
DLL="$WINLIB/libdivecomputer-0.dll"

# --- sanity: import table ------------------------------------------------
PDUMP="$(objdump -p "$DLL")"
IMPORTS="$(sed -n 's/.*DLL Name: //p' <<<"$PDUMP" | sort -u | tr '\n' ' ')"
log "DLL imports: $IMPORTS"
for want in libhidapi-0.dll libusb-1.0.dll KERNEL32.dll msvcrt.dll WS2_32.dll ADVAPI32.dll; do
  case " $IMPORTS " in *" $want "*) : ;; *) die "missing expected import: $want" ;; esac
done
case " $IMPORTS " in
  *vcruntime*|*api-ms-win*|*VCRUNTIME*|*MSVCP*|*ucrtbase*)
    die "MSVC-style import present — must be a MinGW/msvcrt build" ;;
esac

# --- sanity: unified device API is exported -----------------------------
# The DLL is stripped, so nm -D reports nothing; PE exports live in the
# export directory -> read objdump -p's [Ordinal/Name Pointer] Table.
EXPORTS="$(sed -n '/\[Ordinal\/Name Pointer\] Table/,/^$/p' <<<"$PDUMP" \
  | sed -n 's/^\s*\[[ 0-9]*\] \([A-Za-z_][A-Za-z0-9_]*\)\s*$/\1/p')"
grep -qx 'dc_device_open' <<<"$EXPORTS" \
  || die "dc_device_open not exported"
grep -qx 'dc_descriptor_iterator_new' <<<"$EXPORTS" \
  || die "dc_descriptor_iterator_new not exported (0.9.0 unified device API)"
log "exports: dc_device_open + dc_descriptor_iterator_new present ($(grep -c . <<<"$EXPORTS") total)"

# --- sanity: Mares Sirius descriptor row + mares_iconhd backend linked --
# mares_iconhd_device_open is PRIVATE in 0.9.0 (dispatched by dc_device_open
# for DC_FAMILY_MARES_ICONHD / model 0x2F) — it is NOT an export. Prove the
# backend is in the binary via strings instead.
STR="$(strings -a "$DLL")"
grep -q 'Sirius'                       <<<"$STR" || die "no 'Sirius' string — descriptor row not linked"
grep -q 'mares_iconhd'                 <<<"$STR" || die "no 'mares_iconhd' string — backend .c not linked"
grep -q 'mares_iconhd_packet_variable' <<<"$STR" || die "no 'mares_iconhd_packet_variable' — Sirius VARIABLE-mode path missing"

ls -l "$DLL" >&2
log "Windows DLL OK"
