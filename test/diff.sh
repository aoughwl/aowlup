#!/usr/bin/env bash
# The port's acceptance gate: run the Node implementation and the Nimony one over
# the same command surface and require byte-identical stdout+stderr and the same
# exit code.
#
# The Node build is the ORACLE. A command counts as ported only when it is
# byte-identical here, or the difference is listed in EXPECTED_DIFF below with a
# reason — an unexplained difference is a failure, not a note.
#
#   ./test/diff.sh              every case
#   ./test/diff.sh doctor       cases whose name matches a substring
#
# Read-only: every case below is a query. Mutating commands (use/unset/link/init)
# are exercised in test/registry.sh against a sandboxed AOWL_HOME, because they
# rewrite the real registry and must never be run against a developer's machine.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="$ROOT/bin/aowlup"
NG_BIN="${NG_BIN:-$ROOT/bin/aowlup-ng}"
FILTER="${1:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$NG_BIN" ]; then
  echo "no $NG_BIN — run ./build.sh first" >&2
  exit 2
fi

# Commands that are DELIBERATELY different, with the reason. Anything not listed
# here must match exactly.
#   backend list      : the Nimony build adds a VERSION column, because the
#                       manager now records a real git short-sha instead of the
#                       string "0.1.0" the Node build wrote for every component.
#   which fmt         : an unresolvable slot now NAMES every path it probed. The
#                       Node build printed only "could not resolve", which turned
#                       "you have not built this" into a guessing game.
#   which nosuchslot  : an unknown slot is now told apart from an unresolved one
#                       and lists the slots that exist. The Node build reported a
#                       typo as a missing build.
EXPECTED_DIFF=("backend list" "which fmt" "which nosuchslot")

CASES=(
  "help"
  "doctor"
  "profile"
  "profile list"
  "config"
  "config --lsp"
  "which parser"
  "which sem"
  "which hexer"
  "which native"
  "which interp"
  "which fmt"
  "which nosuchslot"
  "backend list"
  "backend which parser"
  "nosuchcommand"
  "+nimony doctor"
  "+nimony config"
  "+aowl config"
  "+nimony which sem"
  # plan-only forms of the mutating commands: they print what they WOULD do and
  # write nothing, so they are safe to compare here.
  "setup"
  "vscode"
  "rebuild aowlmony"
  "rebuild nimony"
)

# Cases that reach GitHub. Skipped by default so the harness stays fast and works
# offline; run with AOWLUP_DIFF_NET=1 to include them.
if [ -n "${AOWLUP_DIFF_NET:-}" ]; then
  CASES+=("status" "update" "update aowlc")
fi

pass=0; fail=0; expected=0
for c in "${CASES[@]}"; do
  [ -n "$FILTER" ] && [[ "$c" != *"$FILTER"* ]] && continue

  # Network cases run ONCE. Each case already costs two live API calls, and
  # running them in both colour modes doubles that into the unauthenticated rate
  # limit — at which point the two implementations disagree only about which of
  # them asked last, which is not a fact about the port.
  modes="NO_COLOR FORCE_COLOR"
  case "$c" in status*|update*) modes="NO_COLOR" ;; esac

  # Both colour paths: plain output is what scripts read, FORCE_COLOR exercises
  # the ANSI-aware padding that a byte count silently gets wrong.
  for mode in $modes; do
    env "$mode=1" node "$NODE_BIN" $c > "$TMP/a.out" 2> "$TMP/a.err"; ea=$?
    env "$mode=1" "$NG_BIN"        $c > "$TMP/b.out" 2> "$TMP/b.err"; eb=$?

    # A rate-limited run says nothing about the port: the two implementations
    # queried a shared quota a second apart. Skip rather than score it.
    if grep -qE "abuse detection|rate limit|API rate" "$TMP/a.out" "$TMP/b.out" 2>/dev/null; then
      echo "-- [$mode] '$c' skipped: GitHub rate-limited this run"
      continue
    fi

    same=1
    cmp -s "$TMP/a.out" "$TMP/b.out" || same=0
    cmp -s "$TMP/a.err" "$TMP/b.err" || same=0
    [ "$ea" = "$eb" ] || same=0

    is_expected=0
    for e in "${EXPECTED_DIFF[@]}"; do [ "$c" = "$e" ] && is_expected=1; done

    if [ "$same" = 1 ]; then
      if [ "$is_expected" = 1 ]; then
        echo "?? [$mode] '$c' is listed as an expected difference but MATCHES — drop it from EXPECTED_DIFF"
        fail=$((fail+1))
      else
        pass=$((pass+1))
      fi
    elif [ "$is_expected" = 1 ]; then
      expected=$((expected+1))
    else
      fail=$((fail+1))
      echo "FAIL [$mode] aowlup $c   (node exit $ea, nimony exit $eb)"
      diff -u "$TMP/a.out" "$TMP/b.out" | head -20 | sed 's/^/    /'
      diff -u "$TMP/a.err" "$TMP/b.err" | head -10 | sed 's/^/    /'
    fi
  done
done

total=$((pass+fail+expected))
echo ""
echo "$pass/$total identical · $expected expected-different · $fail FAILED"
[ "$fail" = 0 ] || exit 1
