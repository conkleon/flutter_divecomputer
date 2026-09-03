#!/usr/bin/env bash
# Download + verify + extract libdivecomputer into native/build/.work/src/.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/libdivecomputer.env"
need_cmd curl; need_cmd tar; need_cmd sha256sum

WORK="$HERE/.work"
mkdir -p "$WORK/src"
TARBALL="$WORK/libdivecomputer-$LDC_VERSION.tar.gz"

fetch_and_verify "$LDC_TARBALL_URL" "$LDC_TARBALL_SHA256" "$TARBALL"

SRC="$WORK/src/libdivecomputer-$LDC_VERSION"
rm -rf "$SRC"
tar -xzf "$TARBALL" -C "$WORK/src"
[ -x "$SRC/configure" ] || die "expected a pre-generated ./configure in $SRC"
assert_sirius_in_source "$SRC"
log "extracted + validated: $SRC"
