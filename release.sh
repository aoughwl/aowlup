#!/usr/bin/env bash
# Package aowlup for a release: a platform-named binary and its checksum.
#
#   ./release.sh            → dist/aowlup-<os>-<arch> + .sha256
#
# The naming is not cosmetic. `install.sh` and `aowlup install` both select an
# asset by `<name>-<os>-<arch>` and fall back to the bare `<name>`; publishing
# only a bare name means the first non-Linux user downloads a binary that cannot
# run, which is worse than a missing asset because it fails later and stranger.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$os" in darwin) os=macos ;; esac
case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
TRIPLE="$os-$arch"

./build.sh || { echo "release: build failed" >&2; exit 1; }

mkdir -p dist
OUT="dist/aowlup-$TRIPLE"
cp bin/aowlup-ng "$OUT"
chmod 755 "$OUT"

# The GLIBC FLOOR. This binary is dynamically linked, so it runs only on a
# system whose glibc is at least as new as the one it was built against. A
# release that does not record that hands an older-distro user
# "GLIBC_2.34 not found" from the dynamic loader — a failure with no connection
# to anything they did, which is the exact shape release.sh exists to prevent.
FLOOR="$(objdump -T "$OUT" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 | sed 's/GLIBC_//')"
if [ -n "$FLOOR" ]; then
  echo "$FLOOR" > "$OUT.glibc"
  echo "  glibc floor: $FLOOR  (recorded in $(basename "$OUT").glibc)"
else
  echo "  glibc floor: none detected (static?)"
fi

if command -v sha256sum >/dev/null 2>&1; then
  (cd dist && sha256sum "aowlup-$TRIPLE" > "aowlup-$TRIPLE.sha256")
elif command -v shasum >/dev/null 2>&1; then
  (cd dist && shasum -a 256 "aowlup-$TRIPLE" > "aowlup-$TRIPLE.sha256")
else
  echo "release: no sha256 tool — publishing UNVERIFIABLE assets" >&2
fi

# A release artifact that cannot run is the failure mode worth catching here,
# while it is still cheap: exercise it before it is published.
if ! "$OUT" doctor >/dev/null 2>&1; then
  echo "release: the packaged binary does not run — refusing to publish it" >&2
  exit 1
fi

echo "RELEASE-OK: $OUT"
ls -la "$OUT"* | sed 's/^/  /'
echo ""
echo "  upload all three files as release assets on aoughwl/aowlup"
echo "  (install.sh reads the .glibc floor and refuses rather than installing"
echo "   a binary this machine cannot run)"
