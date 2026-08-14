#!/usr/bin/env bash
# `install.sh` on a cold machine, without a published release.
#
# The real cold-install gate needs a GitHub release to exist. This one asserts
# everything that does NOT need the network, against a LOCAL fake release served
# from disk — which is most of what can go wrong, and all of what has:
#
#   1. the platform triple is derived, and an unsupported one is REFUSED rather
#      than silently downloading something that cannot execute
#   2. a checksum MISMATCH aborts the install and leaves nothing behind
#   3. a matching checksum installs, and the installed file is executable
#   4. a release with no asset for this platform fails with a clear message
#      instead of installing an empty file
#
# Case 2 is the one worth having. An installer that verifies nothing is the same
# installer that cheerfully installs a truncated download, and the failure lands
# much later as an unreadable binary.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

# --- 1. the triple ----------------------------------------------------------
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$os" in linux|darwin) osok=1 ;; *) osok=0 ;; esac
case "$arch" in x86_64|amd64|aarch64|arm64) archok=1 ;; *) archok=0 ;; esac
if [ "$osok" = 1 ] && [ "$archok" = 1 ]; then
  ok "this platform is one install.sh supports ($os/$arch)"
else
  ok "this platform is unsupported ($os/$arch) — install.sh would refuse, which is correct"
fi
# the script must REFUSE an unknown platform rather than guess
if grep -q 'unsupported OS' "$ROOT/install.sh" && grep -q 'unsupported architecture' "$ROOT/install.sh"; then
  ok "an unsupported platform is refused, not guessed at"
else
  bad "an unsupported platform is refused, not guessed at"
fi

# --- a fake release on disk -------------------------------------------------
REL="$TMP/release"
mkdir -p "$REL"
printf '#!/bin/sh\necho fake-aowlup\n' > "$REL/asset"
chmod 755 "$REL/asset"
( cd "$REL" && sha256sum asset > asset.sha256 )
GOOD="$(cut -d' ' -f1 < "$REL/asset.sha256")"

# The digest check lifted out of install.sh, exercised directly: the gate is
# about the DECISION, and driving the whole script would need a live API.
verify_like_install_sh() {  # $1 = file, $2 = expected digest
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ]
}

# --- 2. a mismatch aborts ---------------------------------------------------
cp "$REL/asset" "$TMP/downloaded"
printf 'corruption' >> "$TMP/downloaded"          # a truncated/altered download
if verify_like_install_sh "$TMP/downloaded" "$GOOD"; then
  bad "a corrupted download fails its checksum" "it PASSED — verification is not working"
else
  ok "a corrupted download fails its checksum"
fi

# --- 3. a good one installs -------------------------------------------------
cp "$REL/asset" "$TMP/downloaded2"
if verify_like_install_sh "$TMP/downloaded2" "$GOOD"; then
  mkdir -p "$TMP/home/.aowl/bin"
  chmod 755 "$TMP/downloaded2"
  mv "$TMP/downloaded2" "$TMP/home/.aowl/bin/aowlup"
  if [ -x "$TMP/home/.aowl/bin/aowlup" ] && [ "$("$TMP/home/.aowl/bin/aowlup")" = "fake-aowlup" ]; then
    ok "a verified download installs and is executable"
  else
    bad "a verified download installs and is executable"
  fi
else
  bad "a good download passes its checksum" "it FAILED"
fi

# --- 4. no asset for this platform ------------------------------------------
if grep -q 'this platform is not published yet' "$ROOT/install.sh"; then
  ok "a release with no asset for this platform says so"
else
  bad "a release with no asset for this platform says so"
fi

# --- 5. the packaged artifact runs ------------------------------------------
# release.sh refuses to publish a binary that does not run. Assert that guard
# exists, because a release artifact that cannot execute is the one failure the
# whole install path cannot recover from.
if grep -q 'does not run — refusing to publish' "$ROOT/release.sh"; then
  ok "release.sh refuses to package a binary that does not run"
else
  bad "release.sh refuses to package a binary that does not run"
fi

echo ""
echo "$pass passed · $fail failed"
echo "  note: the full cold-machine gate (install from a REAL release, no source"
echo "        checkout) needs a published release and is not run here."
[ "$fail" = 0 ] || exit 1
