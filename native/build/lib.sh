# Shared helpers. Source this; do not execute.
set -euo pipefail

die()  { echo "FATAL: $*" >&2; exit 1; }
log()  { echo ">>> $*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# fetch_and_verify <url> <sha256> <dest-file>
fetch_and_verify() {
  local url="$1" want="$2" dest="$3"
  if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ]; then
    log "cached + verified: $dest"; return 0
  fi
  log "downloading $url"
  curl -fSL -o "$dest" "$url"
  local got; got="$(sha256sum "$dest" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || die "sha256 mismatch for $dest: got $got want $want"
  log "verified: $dest"
}

# assert_sirius_in_source <srcdir>
assert_sirius_in_source() {
  local srcdir="$1"
  grep -qF "$SIRIUS_ROW" "$srcdir/src/descriptor.c" \
    || die "Sirius descriptor row not found in $srcdir/src/descriptor.c"
  log "source contains the Mares Sirius descriptor row"
}
