#!/usr/bin/env bash
# Build aowlup with the Nimony compiler (self-hosted).
#
# The output is bin/aowlup-ng, NOT bin/aowlup: the Node implementation stays the
# installed entry point until the differential harness (test/diff.sh) reports
# parity on every command. Two implementations, one oracle, no flag day.
#
# Overrides: NIMONY=/path/to/nimony  AOWLKIT=/path/to/aowlkit/src
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
AOWLKIT="${AOWLKIT:-$HOME/aowlkit/src}"
NIMLOCK="${NIMLOCK:-$HOME/.aowl/bin/nimlock}"
OUT="$ROOT/bin/aowlup-ng"
cd "$ROOT"

if [ ! -x "$NIMONY" ]; then
  echo "BUILD-FAIL: no nimony at $NIMONY (set NIMONY=)" >&2
  exit 1
fi
if [ ! -d "$AOWLKIT" ]; then
  echo "BUILD-FAIL: no aowlkit at $AOWLKIT (git clone https://github.com/aoughwl/aowlkit)" >&2
  exit 1
fi

# `nimony c` regenerates a shared static object regardless of --nimcache:, so two
# compiles anywhere on the machine race and the loser dies with a bogus link
# error. Take the machine-wide lock when one is available.
# TWO WAYS THIS BUILD SILENTLY DID NOTHING, both fixed here, both worth keeping
# written down because each one exits 0 and leaves the PREVIOUS binary in place:
#
# 1. `bash -c` inherits neither unexported variables nor functions, so the lock
#    wrapper below needs an EXPLICIT environment. Without the exports the compile
#    ran with an empty $NIMONY and produced nothing.
# 2. `nimony c --base:src src/aowlup.nim` from the repo root resolves nimcache
#    from the CWD but nifmake from --base:, so it builds NOTHING, prints nothing
#    and exits 0. The compiler must be run FROM the source directory with a bare
#    relative filename.
#
# The freshness assertion at the bottom is what turned both of these from a
# "successful" build into an error.
export NIMONY AOWLKIT ROOT
build() {
  cd "$ROOT/src" && "$NIMONY" c -p:"$AOWLKIT" aowlup.nim 2>&1
}
export -f build
if [ -x "$NIMLOCK" ]; then
  log="$("$NIMLOCK" bash -c 'build')"
else
  log="$(build)"
fi
rc=$?

# nimony can exit 0 on a failed build, so the exit status alone is not evidence.
# Ask for the artifact, and require it to be NEWER than every source we compiled.
BIN="$(ls -t "$ROOT"/src/nimcache/*/aowlup 2>/dev/null | head -1)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "$log"
  echo "BUILD-FAIL: no binary produced (rc=$rc)" >&2
  exit 1
fi
newest_src="$(ls -t src/aowlup.nim src/aowlup/*.nim | head -1)"
if [ "$newest_src" -nt "$BIN" ]; then
  echo "$log"
  echo "BUILD-FAIL: $newest_src is newer than the artifact — this run did not relink" >&2
  exit 1
fi

mkdir -p "$ROOT/bin"
cp "$BIN" "$OUT"
echo "BUILD-OK: $OUT"
