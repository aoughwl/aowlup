## Slot → executable. The single place that answers "which binary is this slot",
## so no two tools on a machine can answer it differently.
##
## Precedence, highest first:
##   1. `AOWL_<SLOT>` env, if it exists on disk
##   2. a stored per-slot override   (skipped when +profile is ephemeral)
##   3. the active profile's variant
##   4. the dev-fallback probe (~/<repo>/bin/<bin>)
##   5. missing — and we say so, naming every path we tried
##
## Step 5 is the point. A resolver that returns a plausible-looking path when
## nothing exists turns "you have not built this" into a confusing failure much
## further downstream, which is exactly what the previous implementation did.

import std/[strutils, envvars]
import catalog, registry

type Resolution* = object
  slot*: string
  variantId*: string
  origin*: string
  bin*: string          ## "" when unresolved
  source*: string       ## "env" | "link" | "dev-fallback" | "missing"
  tried*: seq[string]   ## every path probed, for the error message

proc famNames(stem: string): seq[string] =
  result = @[]
  for p in Prefixes: result.add p & stem

proc binUnder*(v: Variant, prefix: string): string =
  ## Look for a variant's binary under an explicit prefix (a registry link).
  ##
  ## `<name>-ng` wins over `<name>` when both are present. That is this project's
  ## convention while a tool is being rewritten in the language it serves: the
  ## Nimony build is `bin/<name>-ng` and the implementation it replaces stays as
  ## `bin/<name>`, kept as the differential oracle. Probing the bare name first
  ## resolves a dev checkout to the OLD build — which is how `driver` resolved to
  ## the JavaScript aowlmony on a machine that had already cut over.
  if v.origin == "nimony":
    let p = prefix & "/bin/" & v.bin
    return (if fileExists(p): p else: "")
  let names = famNames(v.binStem)
  for b in names:
    let ng = prefix & "/bin/" & b & v.binSuffix & "-ng"
    if fileExists(ng): return ng
    let p = prefix & "/bin/" & b & v.binSuffix
    if fileExists(p): return p
  ""

proc probeVariant*(v: Variant, tried: var seq[string]): string =
  ## The dev fallback: a working checkout at ~/<repo>. Walks the rename family
  ## (aowl/aif/nif) in both the repo name and the binary name, because a dev box
  ## can still be carrying pre-rename directories.
  let home = homeDir()
  if v.origin == "nimony":
    let p = home & "/" & v.repoDir & "/bin/" & v.bin
    tried.add p
    return (if fileExists(p): p else: "")

  let repos = famNames(v.repoStem)
  let bins = famNames(v.binStem)
  for repo in repos:
    for b in bins:
      let ng = home & "/" & repo & "/bin/" & b & v.binSuffix & "-ng"
      tried.add ng
      if fileExists(ng): return ng
      let p = home & "/" & repo & "/bin/" & b & v.binSuffix
      tried.add p
      if fileExists(p): return p
  ""

proc profileIsEphemeral*(): bool =
  ## A leading `+profile` sets AOWL_PROFILE for one invocation. It deliberately
  ## ignores stored per-slot overrides, so `+nimony` really is the whole stack.
  let e = getEnv("AOWL_PROFILE", "")
  if e.len == 0: return false
  findProfile(profilesOf(), e) >= 0

proc activeProfileName*(r: Registry): string =
  let e = getEnv("AOWL_PROFILE", "")
  if e.len > 0 and findProfile(profilesOf(), e) >= 0: return e
  withProfile(r, DefaultProfile)

proc activeVariantId*(slots: seq[Slot], slot: string, r: Registry): string =
  if getEnv(envKey(slot), "").len > 0: return "(env)"
  if not profileIsEphemeral():
    let ovr = getOrDefault(r.overrides, slot, "")
    if ovr.len > 0: return ovr
  let ps = profilesOf()
  var pi = findProfile(ps, activeProfileName(r))
  if pi < 0: pi = findProfile(ps, DefaultProfile)
  let want = if pi >= 0: variantFor(ps[pi], slot) else: ""
  if want.len > 0: return want
  let si = findSlot(slots, slot)
  if si >= 0 and slots[si].variants.len > 0: slots[si].variants[0].id else: ""

proc resolveSlot*(slots: seq[Slot], slot: string, r: Registry): Resolution =
  result = Resolution(slot: slot, variantId: "", origin: "", bin: "",
                      source: "missing", tried: @[])
  let si = findSlot(slots, slot)
  if si < 0: return
  let s = slots[si]

  let env = getEnv(envKey(slot), "")
  if env.len > 0:
    result.tried.add env
    if fileExists(env):
      result.variantId = "(env)"
      result.origin = "env"
      result.bin = env
      result.source = "env"
      return

  let id = activeVariantId(slots, slot, r)
  result.variantId = id
  let vi = findVariant(s, id)
  if vi < 0: return
  let v = s.variants[vi]
  result.origin = v.origin

  let link = getOrDefault(r.links, slot & "/" & id, Link(prefix: "", version: "", source: ""))
  if link.prefix.len > 0:
    let b = binUnder(v, link.prefix)
    result.tried.add link.prefix & "/bin/"
    if b.len > 0:
      result.bin = b
      result.source = "link"
      return

  let b = probeVariant(v, result.tried)
  if b.len > 0:
    result.bin = b
    result.source = "dev-fallback"

proc binToRepo*(bin: string): string =
  ## The repo dir a resolved binary belongs to: <repo>/bin/<exe>, or
  ## <repo>/nimcache/<hash>/<exe> for a not-yet-installed build.
  var parts: seq[string] = @[]
  for p in split(bin, '/'):
    if p.len > 0: parts.add p
  if parts.len < 2: return ""
  # drop the executable
  var upto = parts.len - 1
  if upto >= 1 and parts[upto - 1] == "bin":
    upto = upto - 1
  elif upto >= 2 and parts[upto - 2] == "nimcache":
    upto = upto - 2
  else:
    upto = upto - 1
  var res = ""
  var i = 0
  while i < upto:
    res.add "/" & parts[i]
    inc i
  res

proc missingHint*(res: Resolution, prog: string): string =
  ## Name what we tried. "not found" without the search path is the unhelpful
  ## half of an error message.
  var s = "could not resolve '" & res.slot & "'"
  if res.variantId.len > 0: s.add " (variant " & res.variantId & ")"
  if res.tried.len > 0:
    s.add "\n  tried:"
    for t in res.tried: s.add "\n    " & tildeAbbrev(t)
  s.add "\n  fix: build it, or `" & prog & " backend link " & res.slot & " <repo-dir>`"
  s
