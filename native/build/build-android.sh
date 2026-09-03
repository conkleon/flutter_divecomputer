#!/usr/bin/env bash
# Cross-compile libdivecomputer.so for all four Android ABIs against the
# staged 0.9.0 release + NDK r27c, then install over the vendored copies in
# native/lib/android/<abi>/libdivecomputer.so.
#
# Run from WSL Ubuntu:
#   cd native/build && bash build-android.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/libdivecomputer.env"
need_cmd unzip; need_cmd patchelf; need_cmd readelf; need_cmd make

WORK="$HERE/.work"
SRC="$WORK/src/libdivecomputer-$LDC_VERSION"
[ -x "$SRC/configure" ] || die "run fetch.sh first"
REPO="$(cd "$HERE/../.." && pwd)"

# --- NDK ---
NDK="$WORK/$NDK_DIR"
TOOL="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [ ! -x "$TOOL/aarch64-linux-android${ANDROID_API}-clang" ]; then
  [ -f "$WORK/ndk.zip" ] || fetch_and_verify "$NDK_URL" "$NDK_SHA256" "$WORK/ndk.zip"
  [ "$(sha256sum "$WORK/ndk.zip" | cut -d' ' -f1)" = "$NDK_SHA256" ] || die "ndk.zip sha256 mismatch"
  log "unzipping NDK (this takes a few minutes)"
  rm -rf "$NDK"
  unzip -q -o "$WORK/ndk.zip" -d "$WORK"
fi
[ -d "$TOOL" ] || die "NDK toolchain not at $TOOL"

# Definitive 16 KB alignment checker shipped with the NDK, if present.
ALIGN_SH=""
for c in "$NDK/build/tools/check_elf_alignment.sh" "$NDK/build/tools/check-elf-alignment.sh"; do
  [ -f "$c" ] && ALIGN_SH="$c" && break
done
[ -n "$ALIGN_SH" ] && log "using NDK alignment checker: $ALIGN_SH" || log "NDK alignment checker absent; using readelf fallback"

# Every PT_LOAD segment's alignment must be >= 0x4000 (16384).
check_alignment() {
  local so="$1" abi="$2" bad=0 a v
  if [ -n "$ALIGN_SH" ]; then
    local res
    res="$(bash "$ALIGN_SH" "$so" 2>&1 || true)"
    sed 's/^/    /' <<<"$res" >&2
    grep -qiE "UNALIGNED" <<<"$res" && bad=1
  fi
  # readelf cross-check (authoritative regardless of the helper)
  while read -r a; do
    v=$((a))
    if [ "$v" -lt 16384 ]; then echo "    PT_LOAD align $a (< 0x4000)" >&2; bad=1; fi
  done < <(readelf -lW "$so" | awk '/^[[:space:]]*LOAD[[:space:]]/{print $NF}')
  [ "$bad" -eq 0 ] || die "$abi: found a LOAD segment aligned < 16 KB"
}

# abi | configure --host | clang triple prefix
TARGETS="
arm64-v8a|aarch64-linux-android|aarch64-linux-android
armeabi-v7a|armv7a-linux-androideabi|armv7a-linux-androideabi
x86|i686-linux-android|i686-linux-android
x86_64|x86_64-linux-android|x86_64-linux-android
"

echo "$TARGETS" | while IFS='|' read -r ABI HOST CLANG; do
  [ -n "$ABI" ] || continue
  log "=== building $ABI ==="
  BD="$WORK/build-android-$ABI"
  rm -rf "$BD"; mkdir -p "$BD"; cd "$BD"

  export CC="$TOOL/${CLANG}${ANDROID_API}-clang"
  export AR="$TOOL/llvm-ar" RANLIB="$TOOL/llvm-ranlib" STRIP="$TOOL/llvm-strip"
  export NM="$TOOL/llvm-nm"
  [ -x "$CC" ] || die "no clang at $CC"

  "$SRC/configure" --host="$HOST" \
    --disable-static --enable-shared --disable-dependency-tracking \
    --without-libusb --without-hidapi \
    CFLAGS="-Os -fPIC -DNDEBUG" \
    LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    > "$BD/configure.log" 2>&1 || { tail -40 "$BD/configure.log" >&2; die "$ABI configure failed"; }
  make -j"$(nproc)" > "$BD/make.log" 2>&1 || { tail -40 "$BD/make.log" >&2; die "$ABI make failed"; }

  OUT="$REPO/native/lib/android/$ABI/libdivecomputer.so"
  REAL="$(readlink -f src/.libs/libdivecomputer.so)"
  [ -f "$REAL" ] || die "no built .so for $ABI"
  cp "$REAL" "$OUT"
  patchelf --set-soname libdivecomputer.so "$OUT"
  "$STRIP" --strip-unneeded "$OUT"

  # --- sanity ---
  SONAME="$(readelf -d "$OUT" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
  [ "$SONAME" = "libdivecomputer.so" ] || die "$ABI SONAME is '$SONAME', want libdivecomputer.so"

  NEEDED="$(readelf -d "$OUT" | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p' | sort | tr '\n' ' ')"
  case "$NEEDED" in
    *libusb*|*hidapi*) die "$ABI links a forbidden lib: $NEEDED" ;;
  esac
  for n in $NEEDED; do
    case "$n" in
      libc.so|libm.so|libstdc++.so|libdl.so) ;;
      *) die "$ABI: unexpected NEEDED entry '$n' (full list: $NEEDED)" ;;
    esac
  done
  log "$ABI NEEDED: $NEEDED"
  log "$ABI SONAME: $SONAME"

  # --- Mares Sirius support (libdivecomputer 0.9.0 unified device API) ---
  # 0.9.0 made the per-backend *_device_open functions private: mares_iconhd_device_open
  # is now an internal symbol dispatched by dc_device_open() in src/device.c based on
  # DC_FAMILY_MARES_ICONHD, so it is NOT in the dynamic symbol table. What the plugin
  # (and Task 4) actually links against is the unified API.
  # (here-strings, not pipes: `strings "$OUT" | grep -q` trips `set -o pipefail`
  #  because grep -q closes the pipe early and strings dies of SIGPIPE.)
  DYN="$("$NM" -D "$OUT")"
  grep -qw dc_device_open <<<"$DYN" \
    || die "$ABI: dc_device_open not exported"
  grep -qw dc_descriptor_iterator_new <<<"$DYN" \
    || die "$ABI: dc_descriptor_iterator_new not exported (0.9.0 renamed dc_descriptor_iterator)"
  # The Mares Sirius descriptor row ({"Mares","Sirius",DC_FAMILY_MARES_ICONHD,0x2F,...})
  # and the mares_iconhd backend must be compiled into the .so.
  STR="$(strings "$OUT")"
  grep -qx 'Sirius' <<<"$STR" \
    || die "$ABI: descriptor table has no Mares Sirius entry"
  grep -q 'mares_iconhd' <<<"$STR" \
    || die "$ABI: mares_iconhd backend not linked in"
  log "$ABI exports dc_device_open + dc_descriptor_iterator_new; Mares Sirius descriptor + mares_iconhd backend present"

  check_alignment "$OUT" "$ABI"
  log "$ABI 16 KB aligned"

  ls -l "$OUT" >&2
  log "$ABI OK"
done

log "all four ABIs built + installed"
