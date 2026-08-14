#!/bin/sh
# aowlup installer — the one piece of this toolchain that is NOT written in the
# language, and cannot be: it runs on a machine that has none of it yet.
#
#   curl -fsSL https://raw.githubusercontent.com/aoughwl/aowlup/main/install.sh | sh
#
# It downloads a prebuilt `aowlup` for this platform, verifies its checksum, and
# puts it in ~/.aowl/bin. Everything after that — the compiler, the driver, the
# backends — `aowlup setup` installs, because by then there is a manager to do it.
#
# POSIX sh on purpose. No bashisms, no jq, no python: curl, sha256sum (or
# shasum), uname, mkdir, mv.
set -eu

REPO="${AOWLUP_REPO:-aoughwl/aowlup}"
CHANNEL="${AOWLUP_CHANNEL:-latest}"
AOWL_HOME="${AOWL_HOME:-$HOME/.aowl}"
BIN_DIR="$AOWL_HOME/bin"

say()  { printf '  %s\n' "$*"; }
die()  { printf '  x %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "need '$1' on PATH"; }
need curl
need uname
need mkdir

# --- platform ---------------------------------------------------------------
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$os" in
  linux)  os=linux ;;
  darwin) os=macos ;;
  *) die "unsupported OS '$os' — build from source: https://github.com/$REPO" ;;
esac
case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "unsupported architecture '$arch'" ;;
esac
TRIPLE="$os-$arch"
ASSET="aowlup-$TRIPLE"

# --- the digest tool differs between Linux and macOS ------------------------
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo ""
  fi
}

# --- locate the release ------------------------------------------------------
if [ "$CHANNEL" = "latest" ]; then
  API="https://api.github.com/repos/$REPO/releases/latest"
else
  API="https://api.github.com/repos/$REPO/releases/tags/$CHANNEL"
fi

say "aowlup installer  ·  $TRIPLE  ·  $REPO ($CHANNEL)"

json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API" 2>/dev/null)" ||
  die "could not reach GitHub (or no such release: $CHANNEL)"

# Pull the download URL for our asset without jq: one URL per line, keep ours.
url="$(printf '%s' "$json" \
  | tr ',' '\n' \
  | grep 'browser_download_url' \
  | sed 's/.*"browser_download_url":[[:space:]]*"//; s/".*//' \
  | grep "/$ASSET$" \
  | head -1)"
[ -n "$url" ] || die "release has no asset named '$ASSET' — this platform is not published yet"

tag="$(printf '%s' "$json" | tr ',' '\n' | grep '"tag_name"' \
  | sed 's/.*"tag_name":[[:space:]]*"//; s/".*//' | head -1)"

# --- download, verify, install ----------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "downloading $ASSET ${tag:+($tag)}"
curl -fsSL -o "$tmp/aowlup" "$url" || die "download failed"

if curl -fsSL -o "$tmp/aowlup.sha256" "$url.sha256" 2>/dev/null; then
  want="$(cut -d' ' -f1 < "$tmp/aowlup.sha256")"
  got="$(sha_of "$tmp/aowlup")"
  if [ -z "$got" ]; then
    say "! no sha256 tool available — installing UNVERIFIED"
  elif [ "$want" != "$got" ]; then
    die "checksum mismatch: expected $want, got $got"
  else
    say "checksum ok"
  fi
else
  say "! the release publishes no .sha256 for this asset — installing unverified"
fi

# Refuse EARLY if this machine's glibc is older than the binary needs. Without
# this the install "succeeds" and the first run dies in the dynamic loader with
# a message that names a symbol version and nothing the user can act on.
if curl -fsSL -o "$tmp/aowlup.glibc" "$url.glibc" 2>/dev/null; then
  need="$(cat "$tmp/aowlup.glibc")"
  have="$(ldd --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+' | tail -1)"
  if [ -n "$need" ] && [ -n "$have" ]; then
    lowest="$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)"
    if [ "$lowest" = "$have" ] && [ "$have" != "$need" ]; then
      die "this build needs glibc >= $need and this system has $have — build from source instead: https://github.com/$REPO"
    fi
    say "glibc $have >= $need"
  fi
fi

mkdir -p "$BIN_DIR"
chmod 755 "$tmp/aowlup"
mv "$tmp/aowlup" "$BIN_DIR/aowlup"

say "installed $BIN_DIR/aowlup"
printf '\n'
say "add to PATH →  export PATH=\"$BIN_DIR:\$PATH\""
say "then       →  aowlup setup --yes    (installs the rest of the toolchain)"
printf '\n'
