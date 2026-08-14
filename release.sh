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
echo "  upload both files as release assets on aoughwl/aowlup"
