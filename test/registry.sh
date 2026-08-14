#!/usr/bin/env bash
# The WRITE path, exercised against a sandboxed AOWL_HOME so a developer's real
# registry is never touched.
#
# What this asserts, and why each one is here:
#   1. init writes a registry both implementations can read
#   2. use / unset / profile use round-trip through the file
#   3. the Node implementation can still read what the Nimony one writes
#      (the driver and the editor read this file; a format change that only the
#      writer understands would split the machine in two)
#   4. versions recorded are REAL — a git short-sha, not the literal "0.1.0"
#   5. the write lock is exclusive, and a held lock fails loudly
#   6. backend.json manifests are regenerated on every write, so a derived file
#      cannot go stale against the registry that derives it
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NG="${NG_BIN:-$ROOT/bin/aowlup-ng}"
NODE_BIN="$ROOT/bin/aowlup"
SANDBOX="$(mktemp -d)"
export AOWL_HOME="$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

[ -x "$NG" ] || { echo "no $NG — run ./build.sh first" >&2; exit 2; }

echo "sandbox: $AOWL_HOME"

# 1 ------------------------------------------------------------------- init
"$NG" init >/dev/null 2>&1
REG="$AOWL_HOME/registry.json"
[ -f "$REG" ] && ok "init writes registry.json" || bad "init writes registry.json"
python3 -c "import json,sys; json.load(open('$REG'))" 2>/dev/null \
  && ok "registry.json is valid JSON" \
  || bad "registry.json is valid JSON" "$(head -5 "$REG")"

# 2 -------------------------------------------------------------- round-trip
"$NG" use sem nimsem >/dev/null 2>&1
got="$("$NG" config 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['slots']['sem']['variant'])" 2>/dev/null)"
[ "$got" = "nimsem" ] && ok "use sem nimsem round-trips" || bad "use sem nimsem round-trips" "got '$got'"

"$NG" unset sem >/dev/null 2>&1
grep -q '"sem"' "$REG" && bad "unset removes the override" "still present" || ok "unset removes the override"

"$NG" profile use nimony >/dev/null 2>&1
got="$("$NG" config 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['profile'])" 2>/dev/null)"
[ "$got" = "nimony" ] && ok "profile use round-trips" || bad "profile use round-trips" "got '$got'"

# 3 ------------------------------------------ the other implementation reads it
a="$(NO_COLOR=1 node "$NODE_BIN" config 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['profile'], d['slots']['sem']['variant'])" 2>/dev/null)"
[ "$a" = "nimony nimsem" ] \
  && ok "the Node build reads a Nimony-written registry" \
  || bad "the Node build reads a Nimony-written registry" "got '$a'"

# 4 ---------------------------------------------------------- real versions
fake="$(python3 - "$REG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for v in d.get("links",{}).values() if v.get("version")=="0.1.0"))
PY
)"
[ "$fake" = "0" ] \
  && ok "no placeholder \"0.1.0\" versions recorded" \
  || bad "no placeholder \"0.1.0\" versions recorded" "$fake links still carry it"

real="$(python3 - "$REG" <<'PY'
import json,sys,re
d=json.load(open(sys.argv[1]))
vs=[v.get("version","") for v in d.get("links",{}).values()]
print(sum(1 for v in vs if re.fullmatch(r"[0-9a-f]{7,40}", v or "")))
PY
)"
[ "${real:-0}" -gt 0 ] \
  && ok "versions are real git revisions ($real recorded)" \
  || bad "versions are real git revisions" "none looked like a sha"

# 5 --------------------------------------------------------------- the lock
mkdir -p "$AOWL_HOME/.registry.lock"
out="$("$NG" use sem nimsem 2>&1)"; rc=$?
rmdir "$AOWL_HOME/.registry.lock"
if [ "$rc" != "0" ] && echo "$out" | grep -q "locked"; then
  ok "a held lock refuses the write, loudly"
else
  bad "a held lock refuses the write, loudly" "rc=$rc out=$out"
fi
# and the refused write must not have landed
grep -q '"sem"' "$REG" && bad "a refused write changes nothing" || ok "a refused write changes nothing"

# 6 ------------------------------------------------------------- manifests
"$NG" profile use hybrid >/dev/null 2>&1
M="$AOWL_HOME/backends/sem/backend.json"
if [ -f "$M" ]; then
  mv="$(python3 -c "import json;print(json.load(open('$M'))['variant'])" 2>/dev/null)"
  cv="$("$NG" config 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['slots']['sem']['variant'])" 2>/dev/null)"
  [ "$mv" = "$cv" ] \
    && ok "backend.json agrees with the registry after a profile switch" \
    || bad "backend.json agrees with the registry after a profile switch" "manifest=$mv registry=$cv"
else
  bad "backend.json is written" "no $M"
fi

# 7 --------------------------------------------------------------- the shims
"$NG" shim >/dev/null 2>&1
SH="$AOWL_HOME/bin/aowli-interp"
if [ -x "$SH" ]; then
  # A shim must resolve at RUN time, not bake in today's answer — that is the
  # difference between a shim and a fourth copy of the resolution result.
  if grep -q "which interp" "$SH"; then
    ok "shims resolve through the registry at run time"
  else
    bad "shims resolve through the registry at run time" "$(head -5 "$SH")"
  fi
else
  bad "shim writes an executable per slot" "no $SH"
fi

# 8 ------------------------------------------------- rollback between versions
mkdir -p "$AOWL_HOME/toolchains/aowli-interp/v0.1.0/bin"
printf '#!/bin/sh\necho old\n' > "$AOWL_HOME/toolchains/aowli-interp/v0.1.0/bin/aowli-interp"
chmod 755 "$AOWL_HOME/toolchains/aowli-interp/v0.1.0/bin/aowli-interp"
sleep 1
mkdir -p "$AOWL_HOME/toolchains/aowli-interp/v0.2.0/bin"
printf '#!/bin/sh\necho new\n' > "$AOWL_HOME/toolchains/aowli-interp/v0.2.0/bin/aowli-interp"
chmod 755 "$AOWL_HOME/toolchains/aowli-interp/v0.2.0/bin/aowli-interp"
python3 - "$REG" <<'PYX'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
d.setdefault("components",{})["interp"]={"source":"release","release":"aoughwl/aowli-release",
  "version":"v0.2.0","bin":"","prefix":""}
json.dump(d,open(p,"w"),indent=2)
PYX
out="$("$NG" rollback aowli 2>&1)"
if echo "$out" | grep -q "v0.1.0"; then
  ok "rollback moves a slot to the previous installed tag"
else
  bad "rollback moves a slot to the previous installed tag" "$(echo "$out" | head -3)"
fi

# 9 --------------------------------------------------------------- uninstall
"$NG" uninstall aowli >/dev/null 2>&1
if [ -d "$AOWL_HOME/toolchains/aowli-interp" ]; then
  bad "uninstall removes the toolchain directory" "still present"
else
  ok "uninstall removes the toolchain directory"
fi

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
