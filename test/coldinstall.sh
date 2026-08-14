#!/usr/bin/env bash
# THE COLD-MACHINE GATE: install from the PUBLISHED RELEASE into a sandbox HOME,
# with no source checkout involved, and require the installed binary to run.
#
# This is the one that says "a stranger can install this". Everything else in
# test/ measures the code; this measures the distribution.
#
# It needs the network and a published release. Skips (exit 0, loudly) when
# either is missing, because a machine with no network must not fail a gate
# about a property it cannot observe — but it never SILENTLY passes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

if ! curl -fsSL -m 10 https://api.github.com >/dev/null 2>&1; then
  echo "  — skipped: no network. This gate asserts nothing today."
  exit 0
fi

echo "sandbox HOME: $SB"
out="$(HOME="$SB" AOWL_HOME="$SB/.aowl" sh "$ROOT/install.sh" 2>&1)"
rc=$?
echo "$out" | sed 's/^/    /'

if [ "$rc" != "0" ]; then
  bad "install.sh completes against the published release" "exit $rc"
else
  ok "install.sh completes against the published release"
fi

# Each of these is a step that has actually been broken:
echo "$out" | grep -q "checksum ok" \
  && ok "the download was checksum-verified" \
  || bad "the download was checksum-verified" "no 'checksum ok' in the output"

echo "$out" | grep -q "glibc .* >= " \
  && ok "the glibc floor was checked before installing" \
  || bad "the glibc floor was checked before installing"

BIN="$SB/.aowl/bin/aowlup"
if [ -x "$BIN" ]; then
  ok "the binary landed in ~/.aowl/bin and is executable"
else
  bad "the binary landed in ~/.aowl/bin and is executable" "no $BIN"
fi

# The point of the whole exercise: it RUNS on a machine that has nothing else.
if [ -x "$BIN" ] && HOME="$SB" AOWL_HOME="$SB/.aowl" NO_COLOR=1 "$BIN" doctor >/dev/null 2>&1; then
  ok "the installed binary runs with no toolchain and no source checkout"
else
  bad "the installed binary runs with no toolchain and no source checkout"
fi

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
