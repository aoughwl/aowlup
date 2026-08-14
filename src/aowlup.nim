## aowlup — the toolchain manager for the aoughwl stack.
##
## Two tools, modelled on `rustup` : `cargo`:
##   aowlup   MANAGES the toolchain — installs, versions, and selects components,
##            writing its choice to a registry at ~/.aowl.
##   aowlmony COMPILES your code — it reads that registry and runs what was
##            selected. It never installs anything.
##
## The seam is one-directional: aowlup writes the registry, the driver reads it.
##
## Three axes:
##   VARIANTS  each pipeline slot has interchangeable implementations
##   PROFILES  a named whole-stack selection (aowl / nimony / hybrid)
##   VERSIONS  every component is a git checkout or a published release
##
## Resolution per slot, highest first:
##   AOWL_<SLOT> env → slot override → active profile's variant → dev probe → error.

import std/[syncio, strutils, envvars, cmdline, os]
import aowlkit/[subprocess, tty]
import aowlup/[catalog, registry, resolve, gh]

const Prog = "aowlup"

var exitCode = 0

proc die(msg: string) =
  ## Errors go to stderr, so a script capturing stdout gets data or nothing —
  ## never a diagnostic it will try to parse. The glyph degrades to ASCII when
  ## colour is off, because a bare ✗ in a log file is worse than an `x`.
  let mark = if colorEnabled(): red(GCross) else: "x"
  stderr.writeLine "  " & mark & " " & red(msg)
  quit 1

proc note(msg: string) =
  stdout.writeLine "  " & gray(msg)

# --------------------------------------------------------------------------
# JSON emission (machine-consumed; matches JSON.stringify(x, null, 2))
# --------------------------------------------------------------------------

proc jesc(s: string): string =
  result = ""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add c

proc jq(s: string): string = "\"" & jesc(s) & "\""
proc jnullable(s: string): string = (if s.len == 0: "null" else: jq(s))

# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# backend manifests — derived from the registry, rewritten on every write
# --------------------------------------------------------------------------

proc writeManifests(slots: seq[Slot], r: Registry) =
  ## ~/.aowl/backends/<slot>/backend.json, regenerated on EVERY registry write.
  ##
  ## The previous manager wrote these once, at install time, and never again —
  ## so a machine ended up with a manifest naming an interpreter two weeks older
  ## than the one the registry resolved, and two tools reading different doors
  ## ran different binaries. A derived file that is not rebuilt with its source
  ## is a second source of truth; regenerating here keeps it derived.
  for s in slots:
    let res = resolveSlot(slots, s.slot, r)
    let dir = aowlHome() & "/backends/" & s.slot
    discard execShellCmd("mkdir -p " & quoteShell(dir))
    var modes = "["
    var i = 0
    while i < s.modes.len:
      modes.add jq(s.modes[i])
      if i + 1 < s.modes.len: modes.add ", "
      inc i
    modes.add "]"
    var flags = "["
    i = 0
    while i < s.flags.len:
      flags.add jq(s.flags[i])
      if i + 1 < s.flags.len: flags.add ", "
      inc i
    flags.add "]"
    let body = "{\n" &
      "  " & jq("slot") & ": " & jq(s.slot) & ",\n" &
      "  " & jq("kind") & ": " & jq(s.kind) & ",\n" &
      "  " & jq("variant") & ": " & jnullable(res.variantId) & ",\n" &
      "  " & jq("origin") & ": " & jnullable(res.origin) & ",\n" &
      "  " & jq("target") & ": " & jnullable(s.target) & ",\n" &
      "  " & jq("consumes") & ": " & jnullable(s.consumes) & ",\n" &
      "  " & jq("produces") & ": " & jnullable(s.produces) & ",\n" &
      "  " & jq("runner") & ": " & jnullable(s.runner) & ",\n" &
      "  " & jq("exe") & ": " & jnullable(res.bin) & ",\n" &
      "  " & jq("modes") & ": " & modes & ",\n" &
      "  " & jq("flags") & ": " & flags & ",\n" &
      "  " & jq("cfgKey") & ": " & jnullable(s.cfgKey) & ",\n" &
      "  " & jq("note") & ": " & jq(s.note) & "\n}\n"
    try:
      writeFile(dir & "/backend.json", body)
    except:
      discard

proc persist(slots: seq[Slot], r: Registry): bool =
  ## The one write path: registry first, then every derived manifest.
  if not saveRegistry(r): return false
  writeManifests(slots, r)
  true

proc srcColor(source: string, s: string): string =
  case source
  of "link": green(s)
  of "dev-fallback": amber(s)
  of "env": violet(s)
  of "missing": red(s)
  else: gray(s)

proc cmdDoctor(slots: seq[Slot], r: Registry) =
  stdout.write banner(Prog, "resolved toolchain")

  var head = kv("profile", pill(activeProfileName(r)))
  if profileIsEphemeral():
    head.add dim("  (+ephemeral)")
  else:
    var ovr: seq[string] = @[]
    for k, v in pairs(r.overrides): ovr.add amber(k & "=" & v)
    if ovr.len > 0: head.add "  " & gray("overrides: ") & joinStr(ovr, dim(", "))
  stdout.writeLine head

  var homeLine = kv("home", cyan(tildeAbbrev(aowlHome())))
  if not registry.fileExists(regPath()):
    homeLine.add red("  (run `" & Prog & " init`)")
  stdout.writeLine homeLine
  stdout.writeLine ""

  var rows: seq[seq[string]] = @[]
  var targets: seq[string] = @[]
  for s in slots:
    let res = resolveSlot(slots, s.slot, r)
    var variantCell = ""
    if s.variants.len > 1:
      var parts: seq[string] = @[]
      for v in s.variants:
        parts.add(if v.id == res.variantId: bold(teal(v.id)) else: dim(v.id))
      variantCell = joinStr(parts, dim("/"))
    else:
      variantCell = (if res.bin.len > 0: teal(res.variantId) else: dim(res.variantId))
    let binCell = if res.bin.len > 0: cyan(tildeAbbrev(res.bin))
                  else: red(GCross & " not built")
    let kindCell = case s.kind
                   of "backend": violet(s.kind)
                   of "tool": amber(s.kind)
                   else: gray(s.kind)
    rows.add @[bold(white(s.slot)), kindCell, variantCell,
               srcColor(res.source, res.source), binCell]
    if s.kind == "backend" and res.bin.len > 0: targets.add green(s.target)

  stdout.writeLine renderTable(@[column("slot"), column("kind"), column("variant"),
                                 column("source"), column("resolved")], rows)
  stdout.writeLine ""
  stdout.writeLine "  " & gray("targets ") & GArrow & " " & joinStr(targets, dim(" · "))
  stdout.writeLine ""

proc cmdConfig(slots: seq[Slot], r: Registry, lsp: bool) =
  ## The payload the editor and the driver both read. Raw JSON on stdout — no
  ## banner, no colour, nothing a parser has to skip.
  var opts: seq[string] = @[]
  for s in slots:
    if s.cfgKey.len == 0: continue
    let res = resolveSlot(slots, s.slot, r)
    if res.bin.len > 0: opts.add "  " & jq(s.cfgKey) & ": " & jq(res.bin)
  for slot in ["parser", "sem", "hexer"]:
    let res = resolveSlot(slots, slot, r)
    if res.bin.len > 0: opts.add "  " & jq(slot & "Exe") & ": " & jq(res.bin)
  opts.add "  " & jq("profile") & ": " & jq(activeProfileName(r))

  if lsp:
    var inner: seq[string] = @[]
    for o in opts: inner.add "  " & o
    stdout.writeLine "{\n  " & jq("initializationOptions") & ": {\n" &
      joinStr(inner, ",\n") & "\n  }\n}"
    return

  var slotEntries: seq[string] = @[]
  for s in slots:
    let res = resolveSlot(slots, s.slot, r)
    slotEntries.add "    " & jq(s.slot) & ": {\n" &
      "      " & jq("variant") & ": " & jnullable(res.variantId) & ",\n" &
      "      " & jq("origin") & ": " & jnullable(res.origin) & ",\n" &
      "      " & jq("exe") & ": " & jnullable(res.bin) & "\n" &
      "    }"
  stdout.writeLine "{\n" & joinStr(opts, ",\n") & ",\n  " & jq("slots") & ": {\n" &
    joinStr(slotEntries, ",\n") & "\n  }\n}"

proc cmdWhich(slots: seq[Slot], r: Registry, slot: string) =
  if slot.len == 0: die("usage: " & Prog & " which <slot>")
  if findSlot(slots, slot) < 0:
    die("unknown slot '" & slot & "'. Slots: " & joinStr(slotNames(slots), ", "))
  let res = resolveSlot(slots, slot, r)
  if res.bin.len == 0:
    die(missingHint(res, Prog))
  stdout.writeLine res.bin   # raw: consumed by scripts

proc cmdProfileList(r: Registry) =
  stdout.write banner(Prog, "stack profiles")
  let ps = profilesOf()
  let active = withProfile(r, DefaultProfile)
  let ours = ps[findProfile(ps, "aowl")]
  for p in ps:
    let on = p.name == active
    let mark = if on: teal(GDot) else: dim(GRing)
    let nameC = if on: bold(violet(p.name)) else: gray(p.name)
    var trip: seq[string] = @[]
    for k in ["parser", "sem", "hexer"]:
      let v = variantFor(p, k)
      let isOurs = v == variantFor(ours, k)
      trip.add gray(k & "=") & (if isOurs: teal(v) else: amber(v))
    stdout.writeLine "  " & mark & " " & padRight(nameC, 8) & "  " & joinStr(trip, dim("  "))
  stdout.writeLine ""
  stdout.writeLine "  " & dim("switch: ") & teal(Prog & " profile use <name>") &
    dim("   ·   one slot: ") & teal(Prog & " use <slot> <variant>")
  stdout.writeLine ""

proc cmdProfileUse(slots: seq[Slot], r: var Registry, name: string) =
  let ps = profilesOf()
  if findProfile(ps, name) < 0:
    var names: seq[string] = @[]
    for p in ps: names.add p.name
    die("unknown profile '" & name & "'. Known: " & joinStr(names, ", "))
  r.profile = name
  if not persist(slots, r): quit 1
  stdout.writeLine "  " & green(GOk) & " profile " & GArrow & " " & bold(violet(name))
  cmdDoctor(slots, r)

proc cmdUse(slots: seq[Slot], r: var Registry, slot, variant: string) =
  let si = findSlot(slots, slot)
  if si < 0:
    die("unknown slot '" & slot & "'. Slots: " & joinStr(slotNames(slots), ", "))
  let s = slots[si]
  if variant.len == 0:
    die("usage: " & Prog & " use <slot> <variant>   variants: " &
        joinStr(variantIds(s), ", "))
  if findVariant(s, variant) < 0:
    die("slot '" & slot & "' has no variant '" & variant & "'. Have: " &
        joinStr(variantIds(s), ", "))
  r.overrides[slot] = variant
  if not persist(slots, r): quit 1
  let res = resolveSlot(slots, slot, r)
  var line = "  " & green(GOk) & " " & bold(slot) & " " & GArrow & " " & teal(variant)
  if res.bin.len > 0: line.add dim("  " & tildeAbbrev(res.bin))
  else: line.add red("  " & GCross & " not built")
  stdout.writeLine line

proc cmdUnset(slots: seq[Slot], r: var Registry, slot: string) =
  if getOrDefault(r.overrides, slot, "").len == 0:
    note("no override on '" & slot & "'")
    return
  del(r.overrides, slot)
  if not persist(slots, r): quit 1
  stdout.writeLine "  " & green(GOk) & " " & bold(slot) & " " & GArrow &
    " profile default " & dim("(" & activeVariantId(slots, slot, r) & ")")

proc cmdList(r: Registry) =
  var keys: seq[string] = @[]
  for k, _ in pairs(r.links): keys.add k
  if keys.len == 0:
    note("nothing registered — run `" & Prog & " init`")
    return
  # sort for stable output
  var i = 0
  while i < keys.len:
    var j = i + 1
    while j < keys.len:
      if keys[j] < keys[i]: swap(keys[i], keys[j])
      inc j
    inc i
  stdout.write banner(Prog, "registered variants")
  var rows: seq[seq[string]] = @[]
  for k in keys:
    let l = getOrDefault(r.links, k, Link(prefix: "", version: "", source: ""))
    rows.add @[bold(k), cyan(tildeAbbrev(l.prefix)),
               (if l.version.len > 0: dim(l.version) else: dim("-"))]
  stdout.writeLine renderTable(@[column("slot/variant"), column("repo"),
                                 column("version")], rows)
  stdout.writeLine ""

proc gitShortRev(dir: string): string =
  ## A REAL version for a source checkout. The previous manager wrote the string
  ## "0.1.0" for every component forever, which made `version` a decoration.
  let r = runCaptured("git", @["-C", dir, "rev-parse", "--short", "HEAD"], "", false)
  if r.ok and r.exitCode == 0: strip(r.output) else: ""

proc cmdLink(slots: seq[Slot], r: var Registry, slot, repo: string) =
  let si = findSlot(slots, slot)
  if si < 0:
    die("unknown slot '" & slot & "'. Slots: " & joinStr(slotNames(slots), ", "))
  if repo.len == 0: die("usage: " & Prog & " backend link <slot> <repo-dir>")
  let s = slots[si]
  var abs = repo
  try:
    abs = expandFilename(repo)
  except:
    die("no such repo dir: " & repo)
  var linkedId = ""
  var linkedBin = ""
  for v in s.variants:
    let b = binUnder(v, abs)
    if b.len > 0:
      linkedId = v.id
      linkedBin = b
      break
  if linkedId.len == 0:
    die("no known variant bin under " & abs & " — build it first")
  r.links[slot & "/" & linkedId] = Link(prefix: abs, version: gitShortRev(abs), source: "")
  if getOrDefault(r.overrides, slot, "").len == 0 and
     activeVariantId(slots, slot, r) != linkedId:
    r.overrides[slot] = linkedId
  if not persist(slots, r): quit 1
  stdout.writeLine "  " & green(GOk) & " linked " & bold(slot & "/" & linkedId) &
    " " & GArrow & " " & cyan(tildeAbbrev(abs))

proc cmdInit(slots: seq[Slot], r: var Registry) =
  for d in ["bin", "backends", "toolchains", "pkg", "index", "cache"]:
    discard execShellCmd("mkdir -p " & quoteShell(aowlHome() & "/" & d))
  var found = 0
  for s in slots:
    for v in s.variants:
      var tried: seq[string] = @[]
      let bin = probeVariant(v, tried)
      if bin.len == 0: continue
      let repo = binToRepo(bin)
      r.links[s.slot & "/" & v.id] = Link(prefix: repo, version: gitShortRev(repo), source: "")
      inc found
  if r.profile.len == 0: r.profile = DefaultProfile
  if not persist(slots, r): quit 1
  stdout.write banner(Prog, "aoughwl toolchain manager")
  stdout.writeLine kv("home", cyan(tildeAbbrev(aowlHome())))
  stdout.writeLine kv("profile", pill(r.profile))
  stdout.writeLine kv("found", green($found & " variants") &
    dim(" across " & $slots.len & " slots"))
  stdout.writeLine ""
  stdout.writeLine "  " & gray("add to PATH →") & "  " &
    cyan("export PATH=\"" & aowlHome() & "/bin:$PATH\"")
  stdout.writeLine "  " & gray("next →") & "         " & teal(Prog & " doctor") &
    dim("   (see the resolved stack)")
  stdout.writeLine ""


# --------------------------------------------------------------------------
# component repos, builds, releases
# --------------------------------------------------------------------------

type RepoUse = object
  dir: string
  slots: seq[string]

proc componentRepos(slots: seq[Slot], r: Registry): seq[RepoUse] =
  ## Every distinct git checkout behind a resolved slot, with the slots it backs.
  result = @[]
  for s in slots:
    let res = resolveSlot(slots, s.slot, r)
    if res.bin.len == 0 or res.source == "env": continue
    let link = getOrDefault(r.links, s.slot & "/" & res.variantId,
                            Link(prefix: "", version: "", source: ""))
    let dir = if link.prefix.len > 0: link.prefix else: binToRepo(res.bin)
    if dir.len == 0: continue
    if gitOut(dir, @["rev-parse", "HEAD"]).len == 0: continue
    var found = -1
    var i = 0
    while i < result.len:
      if result[i].dir == dir: found = i
      inc i
    if found >= 0: result[found].slots.add s.slot
    else: result.add RepoUse(dir: dir, slots: @[s.slot])

proc baseName(p: string): string =
  let parts = split(p, '/')
  if parts.len == 0: "" else: parts[parts.len - 1]

proc reposForName(slots: seq[Slot], r: Registry, name: string): seq[RepoUse] =
  let all = componentRepos(slots, r)
  if name.len == 0 or name == "all": return all
  result = @[]
  for rp in all:
    var hit = false
    for s in rp.slots:
      if s == name: hit = true
    let b = baseName(rp.dir)
    if b == name: hit = true
    # a pre-rename checkout (~/aifparser) still answers to its aowl* name
    for p in ["aif", "nif"]:
      if b.startsWith(p) and "aowl" & b[p.len ..< b.len] == name: hit = true
    if hit: result.add rp

proc findNim(): string =
  ## A classic Nim to bootstrap nimony's hastur. Prefer a clean devel Nim —
  ## ~/Nim carries patches that miscompile nimony's runtime.
  let home = homeDir()
  for c in [home & "/.choosenim/toolchains/nim-#devel/bin/nim",
            home & "/.nimble/bin/nim", home & "/Nim/bin/nim"]:
    if registry.fileExists(c): return c
  "nim"

type Recipe = object
  cmd: string
  args: seq[string]
  cwd: string
  hint: string
  found: bool

proc buildRecipe(dir: string): Recipe =
  result = Recipe(cmd: "", args: @[], cwd: dir, hint: "", found: false)
  let base = baseName(dir)
  if contains(base, "nimony"):
    let hastur = dir & "/bin/hastur"
    if registry.fileExists(hastur):
      return Recipe(cmd: hastur, args: @["build", "all"], cwd: dir,
                    hint: "hastur build all", found: true)
    return Recipe(cmd: findNim(), args: @["c", "-r", "src/hastur", "build", "all"],
                  cwd: dir, hint: "nim c -r src/hastur build all", found: true)
  if registry.fileExists(dir & "/build.sh"):
    return Recipe(cmd: "bash", args: @["build.sh"], cwd: dir, hint: "./build.sh", found: true)
  if registry.fileExists(dir & "/Makefile"):
    return Recipe(cmd: "make", args: @[], cwd: dir, hint: "make", found: true)
  # node-based components ship bin/ — no build step

proc runInherit(cmd: string, args: seq[string], cwd = ""): int =
  ## Child keeps our stdio: these are long, interesting builds and the user wants
  ## to watch them, not receive a transcript afterwards.
  var line = ""
  if cwd.len > 0: line.add "cd " & quoteShell(cwd) & " && "
  line.add quoteShell(cmd)
  for a in args: line.add " " & quoteShell(a)
  execShellCmd(line)

type RelTarget = object
  slot: string
  variantId: string
  releaseRepo: string
  releaseAsset: string

proc releaseTargets(slots: seq[Slot], name: string): seq[RelTarget] =
  ## Every (slot, variant) installable from a public release, optionally filtered
  ## by a variant id, a slot, or the family stem ("aowli" → interp + dbg).
  result = @[]
  for s in slots:
    for v in s.variants:
      if v.releaseRepo.len == 0 or v.releaseAsset.len == 0: continue
      if name.len > 0 and name != "all":
        let famHit = name == "aowli" and v.repoStem == "i"
        if name != v.id and name != s.slot and not famHit: continue
      result.add RelTarget(slot: s.slot, variantId: v.id,
                           releaseRepo: v.releaseRepo, releaseAsset: v.releaseAsset)

proc installRelease(slots: seq[Slot], name: string, r: var Registry): int =
  ## Install published binaries into ~/.aowl/toolchains/<variant>/<tag>/bin.
  let targets = releaseTargets(slots, name)
  if targets.len == 0:
    die("no release-installable component matches '" & name & "'. Try `" &
        Prog & " install aowli`.")
  var repos: seq[string] = @[]
  for t in targets:
    var seen = false
    for x in repos:
      if x == t.releaseRepo: seen = true
    if not seen: repos.add t.releaseRepo

  var done = 0
  for slug in repos:
    let rel = ghLatestRelease(slug)
    if rel.error.len > 0:
      stdout.writeLine "  " & red(GCross) & " " & bold(slug) & " " & red(rel.error)
      continue
    let n = rel.assets.len
    stdout.writeLine "  " & teal(GDown) & " " & bold(slug) & " " & gray("release ") &
      cyan(rel.tag) & dim("  (" & $n & " asset" & (if n == 1: "" else: "s") & ")")
    for t in targets:
      if t.releaseRepo != slug: continue
      let picked = pickAsset(rel, t.releaseAsset)
      if picked.url.len == 0:
        stdout.writeLine "    " & gray(GBullet) & " " &
          gray(t.releaseAsset & " — not in this release, skipped")
        continue
      let tcdir = aowlHome() & "/toolchains/" & t.variantId & "/" & rel.tag
      discard execShellCmd("mkdir -p " & quoteShell(tcdir & "/bin"))
      let dest = tcdir & "/bin/" & t.releaseAsset
      stdout.write "    " & violet(GGear) & " " & teal(t.variantId) &
        gray(" ← " & picked.name & " …")
      if not downloadTo(picked.url, dest):
        stdout.writeLine " " & red(GCross & " download failed")
        continue
      # Verify before trusting. A download that silently truncated, or an asset
      # replaced upstream, must not become the compiler this machine runs.
      let expected = fetchExpectedSha(picked.sha)
      if expected.len > 0:
        let got = sha256Of(dest)
        if got != expected:
          discard execShellCmd("rm -f " & quoteShell(dest))
          stdout.writeLine " " & red(GCross & " checksum mismatch — discarded")
          stdout.writeLine "      " & dim("expected " & expected)
          stdout.writeLine "      " & dim("got      " & (if got.len > 0: got else: "(no sha256sum)"))
          continue
      elif picked.sha.len == 0:
        stdout.write gray(" (unverified)")
      discard execShellCmd("chmod 755 " & quoteShell(dest))
      # The tag is stored VERBATIM on both sides. Recording "0.3.0" here while
      # the release is "v0.3.0" is what made the old manager report an available
      # update for ever.
      r.components[t.slot] = Component(source: "release", release: slug,
                                       version: rel.tag, bin: dest, prefix: tcdir)
      r.links[t.slot & "/" & t.variantId] = Link(prefix: tcdir, version: rel.tag,
                                                 source: "release")
      stdout.writeLine " " & green(GOk) & dim("  " & tildeAbbrev(dest))
      inc done
  done

proc cmdInstall(slots: seq[Slot], r: var Registry, name: string) =
  stdout.write banner(Prog, "install from public release")
  let want = if name.len > 0: name else: "aowli"
  let done = installRelease(slots, want, r)
  if not persist(slots, r): quit 1
  stdout.writeLine ""
  if done > 0:
    stdout.writeLine "  " & green(GOk & " installed " & $done & " component" &
      (if done == 1: "" else: "s")) & dim("   ·   ") & gray("check ") &
      teal(Prog & " status") & dim(" for release currency")
  else:
    note("nothing installed")
  stdout.writeLine ""

# --------------------------------------------------------------------------
# status / update / rebuild
# --------------------------------------------------------------------------

proc updateCell(c: Compare): string =
  if c.error == "offline": return gray(GBullet & " offline")
  if c.error == "unpushed": return gray(GBullet & " local-only")
  if c.error.len > 0: return gray(GBullet & " " & c.error)
  if c.status == "identical": return green(GOk & " up to date")
  if c.behind > 0:
    result = amber(GDown & " " & $c.behind & " behind")
    if c.ahead > 0: result.add dim(" / ") & violet($c.ahead & " ahead")
    return result
  if c.ahead > 0: return violet(GUp & " " & $c.ahead & " ahead")
  gray(if c.status.len > 0: c.status else: "?")

proc cmdStatus(slots: seq[Slot], r: Registry) =
  let repos = componentRepos(slots, r)
  stdout.write banner(Prog, "component versions " & dim("(vs GitHub)"))
  var rows: seq[seq[string]] = @[]
  var nimonyBranch = ""
  for rp in repos:
    var branch = gitOut(rp.dir, @["rev-parse", "--abbrev-ref", "HEAD"])
    if branch.len > 18: branch = branch[0 ..< 17] & "…"
    let rev = gitOut(rp.dir, @["rev-parse", "--short", "HEAD"])
    let dirty = isDirty(rp.dir)
    let cmp = ghCompare(rp.dir)
    let revCell = if dirty: amber(rev & "*") else: cyan(if rev.len > 0: rev else: "-")
    rows.add @[bold(white(tildeAbbrev(rp.dir))),
               gray(if branch.len > 0: branch else: "-"),
               revCell,
               dim(if cmp.slug.len > 0: cmp.slug else: "?"),
               updateCell(cmp)]
    if baseName(rp.dir) == "nimony": nimonyBranch = branch
  stdout.writeLine renderTable(@[column("repo"), column("branch"), column("rev"),
                                 column("github"), column("update")], rows)

  # Release-installed (private-source) components: installed tag vs latest.
  let rel = releaseTargets(slots, "all")
  if rel.len > 0:
    var relRows: seq[seq[string]] = @[]
    for t in rel:
      let cur = getOrDefault(r.components, t.slot,
        Component(source: "", release: "", version: "", bin: "", prefix: "")).version
      let latest = ghLatestRelease(t.releaseRepo)
      var cell = ""
      if latest.error.len > 0: cell = gray(GBullet & " " & latest.error)
      elif cur.len == 0: cell = amber(GDown & " not installed → " & latest.tag)
      elif cur == latest.tag: cell = green(GOk & " current")
      else: cell = amber(GDown & " " & cur & " → " & latest.tag)
      relRows.add @[bold(white(t.slot)), dim(t.variantId),
                    cyan(if cur.len > 0: cur else: "-"), dim(t.releaseRepo), cell]
    stdout.writeLine ""
    stdout.write banner(Prog, "release backends " &
      dim("(vs GitHub release · licence-gated)"))
    stdout.writeLine renderTable(@[column("slot"), column("variant"),
                                   column("installed"), column("release repo"),
                                   column("status")], relRows)
    stdout.writeLine "  " & dim("behind → ") & teal(Prog & " install aowli") &
      dim("   (hardened builds expire; re-install to refresh the licence gate)")

  stdout.writeLine ""
  var tail = "  " & gray($repos.len & " repos") & dim("   ·   ") &
    amber(GDown & " behind") & gray(" = ") & teal(Prog & " update <repo>")
  if nimonyBranch.len > 0:
    tail.add dim("   ·   ") & gray("nimony passes track ") & cyan(nimonyBranch)
  stdout.writeLine tail
  stdout.writeLine ""

proc cmdUpdate(slots: seq[Slot], r: var Registry, name: string, yes: bool) =
  # Release-based components refresh by re-fetching, not by git pull.
  let rel = releaseTargets(slots, name)
  if rel.len > 0 and reposForName(slots, r, name).len == 0:
    stdout.write banner(Prog, if yes: "updating from public release"
                              else: "release update check")
    if not yes:
      var repos: seq[string] = @[]
      for t in rel:
        var seen = false
        for x in repos:
          if x == t.releaseRepo: seen = true
        if not seen: repos.add t.releaseRepo
      for slug in repos:
        let latest = ghLatestRelease(slug)
        if latest.error.len > 0:
          stdout.writeLine "  " & gray(GBullet) & " " & bold(slug) & " " & gray(latest.error)
          continue
        for t in rel:
          if t.releaseRepo != slug: continue
          let cur = getOrDefault(r.components, t.slot,
            Component(source: "", release: "", version: "", bin: "", prefix: "")).version
          let same = cur == latest.tag
          var line = "  " & (if same: green(GOk) else: amber(GDown)) & " " &
            bold(t.slot) & dim("/" & t.variantId) & " "
          line.add(if cur.len > 0: gray("installed " & cur & " ") else: gray("not installed "))
          if same: line.add green("= latest " & latest.tag)
          else: line.add amber("→ latest " & latest.tag & "  ") &
            dim(Prog & " install " & (if name.len > 0: name else: "aowli") & " --yes")
          stdout.writeLine line
      stdout.writeLine ""
      return
    discard installRelease(slots, if name.len > 0: name else: "aowli", r)
    if not persist(slots, r): quit 1
    stdout.writeLine ""
    return

  let repos = reposForName(slots, r, name)
  if repos.len == 0:
    die("no component repo matches '" & name & "' — see `" & Prog & " status`")
  stdout.write banner(Prog, if yes: "pulling updates" else: "update check")
  for rp in repos:
    let cmp = ghCompare(rp.dir)
    let tag = bold(tildeAbbrev(rp.dir)) & dim(" [" & joinStr(rp.slots, ",") & "]")
    if cmp.error.len > 0 and cmp.error != "unpushed":
      stdout.writeLine "  " & gray(GBullet) & " " & tag & " " & gray(cmp.error)
      continue
    if cmp.behind == 0:
      stdout.writeLine "  " & green(GOk) & " " & tag & " " & green("up to date")
      continue
    if not yes:
      stdout.writeLine "  " & amber(GDown) & " " & tag & " " &
        amber($cmp.behind & " behind ") & dim(cmp.branch) & " " & GArrow & " " &
        teal(Prog & " update " & baseName(rp.dir) & " --yes")
      continue
    if isDirty(rp.dir):
      stdout.writeLine "  " & amber(GWarn) & " " & tag & " " &
        amber("working tree dirty — skipped")
      continue
    stdout.writeLine "  " & amber(GDown) & " " & tag & " " &
      gray("pulling " & $cmp.behind & "…")
    let rc = runInherit("git", @["-C", rp.dir, "pull", "--ff-only"])
    if rc != 0:
      stdout.writeLine "    " & red(GCross & " pull failed (not fast-forward?)")
      continue
    # A pull that is not followed by a build leaves the OLD binary resolving,
    # which reads as "updated" and is not. Build it now.
    let rec = buildRecipe(rp.dir)
    if not rec.found:
      stdout.writeLine "    " & green(GOk & " pulled") & dim("  (no build recipe)")
      continue
    stdout.writeLine "    " & green(GOk & " pulled") & gray("  building ") & teal(rec.hint) & gray(" …")
    let brc = runInherit(rec.cmd, rec.args, rec.cwd)
    if brc == 0:
      stdout.writeLine "    " & green(GOk & " built")
    else:
      stdout.writeLine "    " & red(GCross & " build exited " & $brc) &
        dim("  (the previous binary is still what resolves)")
  stdout.writeLine ""

proc cmdBuild(slots: seq[Slot], r: Registry, name: string, yes: bool) =
  let repos = reposForName(slots, r, name)
  if repos.len == 0:
    die("no component repo matches '" & name & "' — see `" & Prog & " status`")
  stdout.write banner(Prog, if yes: "building from source" else: "build plan")
  for rp in repos:
    let rec = buildRecipe(rp.dir)
    let tag = bold(tildeAbbrev(rp.dir))
    if not rec.found:
      stdout.writeLine "  " & gray("? ") & tag &
        gray("  no build recipe (hastur/build.sh/Makefile)")
      continue
    if contains(rec.cmd, "/") and not registry.fileExists(rec.cmd):
      stdout.writeLine "  " & gray("? ") & tag & gray("  " & rec.hint & " not present")
      continue
    if not yes:
      stdout.writeLine "  " & violet(GGear) & " " & tag & " " & gray("would run ") &
        teal(rec.hint) & dim("  (add --yes)")
      continue
    stdout.writeLine "  " & violet(GGear) & " " & tag & " " & teal(rec.hint) & gray(" …")
    let rc = runInherit(rec.cmd, rec.args, rec.cwd)
    if rc == 0: stdout.writeLine "    " & green(GOk & " built")
    else: stdout.writeLine "    " & red(GCross & " exited " & $rc)
  stdout.writeLine ""

# --------------------------------------------------------------------------
# run
# --------------------------------------------------------------------------

proc looksLikePack(file: string): bool =
  ## An exported aoughwl PACK, not source: the first non-blank, non-comment line
  ## is the `aowl-pack` header. Packs are RUN by reduction, not compiled.
  var content = ""
  try:
    content = readFile(file)
  except:
    return false
  for raw in split(content, '\n'):
    let line = strip(raw)
    if line.len == 0: continue
    if line[0] == '#': continue
    return line.startsWith("aowl-pack")
  false

proc isExecutable(p: string): bool =
  registry.fileExists(p) and execShellCmd("test -x " & quoteShell(p)) == 0

proc findOnPath(name: string): string =
  for d in split(getEnv("PATH", ""), ':'):
    if d.len == 0: continue
    let p = d & "/" & name
    if isExecutable(p): return p
  ""

proc cmdRun(file: string, rest: seq[string]) =
  if file.len == 0: die("usage: " & Prog & " run <file> [args...]")
  var abs = file
  try:
    abs = expandFilename(file)
  except:
    die("run: no such file: " & file)

  if looksLikePack(abs):
    # The pack reducer lives beside the pack, or in the canonical checkout so the
    # editor's F6 works on a copy elsewhere.
    var ask = ""
    let parts = split(abs, '/')
    var dir = ""
    var i = 0
    while i + 1 < parts.len:
      if parts[i].len > 0: dir.add "/" & parts[i]
      inc i
    for c in [dir & "/cssask", homeDir() & "/aoughwl/bridges/nifi/cssask"]:
      if isExecutable(c): ask = c
    if ask.len == 0:
      die("run: '" & baseName(abs) & "' is an aowl pack but no `cssask` runner " &
          "was found (looked beside it and in ~/aoughwl/bridges/nifi)")
    var args = @[abs]
    for a in rest: args.add a
    quit runInherit(ask, args)

  # Not a pack: it is source. Hand it to the driver.
  var mony = findOnPath("aowlmony")
  if mony.len == 0: mony = homeDir() & "/aowlmony/bin/aowlmony"
  if not registry.fileExists(mony):
    die("run: not a pack, and no `aowlmony` found to compile source. Use " &
        "`aowlmony run " & baseName(abs) & "`.")
  var args = @["run", abs]
  for a in rest: args.add a
  quit runInherit(mony, args)

# --------------------------------------------------------------------------
# vscode
# --------------------------------------------------------------------------

proc cmdVscode(slots: seq[Slot], r: Registry, dir: string, yes: bool) =
  let lspRes = resolveSlot(slots, "lsp", r)
  let nimonyBin = homeDir() & "/nimony/bin/nimony"
  let hasNimony = registry.fileExists(nimonyBin)
  stdout.write banner(Prog, "editor / LSP wiring  " &
    dim("(nimony extension · profile " & activeProfileName(r) & ")"))
  stdout.writeLine kv("server", if lspRes.bin.len > 0: cyan(tildeAbbrev(lspRes.bin))
                                else: red(GCross & " aowllsp not built — run `" & Prog & " setup`"))
  stdout.writeLine kv("nimony", if hasNimony: cyan(tildeAbbrev(nimonyBin))
                                else: red(GCross & " nimony not built"))
  stdout.writeLine kv("ext", gray("nimony.nimony") & dim("  (~/nimony-lsp/client)"))

  var target = dir
  if target.len == 0:
    target = getEnv("PWD", ".")
  let sp = target & "/.vscode/settings.json"
  let serverPath = if lspRes.bin.len > 0: lspRes.bin else: ""
  let nimonyPath = if hasNimony: nimonyBin else: ""

  if not yes:
    stdout.writeLine ""
    stdout.writeLine "  " & gray("would merge into ") & cyan(tildeAbbrev(sp)) &
      dim("   (add --yes)")
    stdout.writeLine "    " & teal("nimony.serverPath") & dim(": ") &
      gray(if serverPath.len > 0: serverPath else: "(unset)")
    stdout.writeLine "    " & teal("nimony.nimonyPath") & dim(": ") &
      gray(if nimonyPath.len > 0: nimonyPath else: "(unset)")
    stdout.writeLine ""
    return

  # Never clobber a settings.json we cannot parse — it may hold comments or the
  # user's own config. Merging into clean JSON only, else print the keys.
  var existing = ""
  if registry.fileExists(sp):
    try:
      existing = readFile(sp)
    except:
      existing = ""
    if existing.len > 0 and strip(existing)[0] != '{':
      stdout.writeLine "  " & amber(GWarn) & " " &
        gray(tildeAbbrev(sp) & " isn't plain JSON — add these keys yourself:")
      stdout.writeLine "    " & teal("\"nimony.serverPath\"") & dim(": ") & cyan(jq(serverPath))
      stdout.writeLine "    " & teal("\"nimony.nimonyPath\"") & dim(": ") & cyan(jq(nimonyPath))
      stdout.writeLine ""
      return
  discard execShellCmd("mkdir -p " & quoteShell(target & "/.vscode"))
  try:
    writeFile(sp, "{\n  " & jq("nimony.serverPath") & ": " & jq(serverPath) &
                  ",\n  " & jq("nimony.nimonyPath") & ": " & jq(nimonyPath) & "\n}\n")
    stdout.writeLine "  " & green(GOk) & " wrote " & cyan(tildeAbbrev(sp)) &
      dim("   (nimony extension now uses the " & activeProfileName(r) & " LSP)")
  except:
    stdout.writeLine "  " & red(GCross) & " could not write " & tildeAbbrev(sp)
  stdout.writeLine ""

# --------------------------------------------------------------------------
# setup — bootstrap the whole toolchain on a fresh machine
# --------------------------------------------------------------------------

proc isDir(p: string): bool =
  execShellCmd("test -d " & quoteShell(p)) == 0

proc hasBuiltBin(dir: string): bool =
  ## "Ready" means a real artifact exists in bin/ — a dot-file does not count.
  let r = runCaptured("ls", @["-A", dir & "/bin"], "", false)
  if not r.ok or r.exitCode != 0: return false
  for line in splitLines(r.output):
    let f = strip(line)
    if f.len > 0 and f[0] != '.': return true
  false

type SetupComp = object
  name: string
  slug: string
  dir: string
  stem: string
  first: bool   ## the bootstrap compiler: must be built before everything else
  lib: bool     ## a source-only shared lib: cloned, never built

proc isReleaseStem(slots: seq[Slot], stem: string): bool =
  ## A stem is release-installable when any variant carries release metadata.
  ## `setup` must NOT try to clone those: the source repo is private and the
  ## clone fails, which used to look like a broken setup.
  for s in slots:
    for v in s.variants:
      if v.repoStem == stem and v.releaseRepo.len > 0: return true
  false

proc setupComponents(slots: seq[Slot]): seq[SetupComp] =
  result = @[]
  var seen: seq[string] = @[]
  let home = homeDir()
  for s in slots:
    for v in s.variants:
      if v.origin != "aoughwl": continue
      var already = false
      for x in seen:
        if x == v.repoStem: already = true
      if already or isReleaseStem(slots, v.repoStem): continue
      seen.add v.repoStem
      result.add SetupComp(name: "aowl" & v.repoStem, slug: "aoughwl/aowl" & v.repoStem,
                           dir: home & "/aowl" & v.repoStem, stem: v.repoStem,
                           first: false, lib: false)

proc readyDir(c: SetupComp): string =
  let home = homeDir()
  if c.stem.len == 0:
    return (if hasBuiltBin(c.dir): c.dir else: "")
  for p in Prefixes:
    let d = home & "/" & p & c.stem
    if hasBuiltBin(d): return d
  ""

proc cmdSetup(slots: seq[Slot], r: var Registry, yes: bool) =
  stdout.write banner(Prog, if yes: "installing the toolchain"
                            else: "setup plan  " & dim("(add --yes to execute)"))
  let home = homeDir()
  var comps: seq[SetupComp] = @[]
  # nimony first: it is the compiler that builds all the others.
  comps.add SetupComp(name: "nimony", slug: "nim-lang/nimony", dir: home & "/nimony",
                      stem: "", first: true, lib: false)
  # shared source libs (consumed via -p:, no build) — before the components whose
  # build.sh scripts reference them by env.
  comps.add SetupComp(name: "aowlkit", slug: "aoughwl/aowlkit", dir: home & "/aowlkit",
                      stem: "", first: false, lib: true)
  comps.add SetupComp(name: "aowlhl", slug: "aoughwl/aowlhl", dir: home & "/aowlhl",
                      stem: "", first: false, lib: true)
  for c in setupComponents(slots): comps.add c
  # the driver ("cargo") and the substrate front end
  comps.add SetupComp(name: "aowlmony", slug: "aoughwl/aowlmony", dir: home & "/aowlmony",
                      stem: "", first: false, lib: false)
  comps.add SetupComp(name: "aoughwlup", slug: "aoughwl/aoughwlup", dir: home & "/aoughwlup",
                      stem: "", first: false, lib: false)

  var toClone = 0
  var toBuild = 0
  var ready = 0
  for c in comps:
    var tag = bold(white(c.name)) & dim("  " & c.slug)
    if c.first: tag.add violet("  ← bootstrap compiler")
    elif c.lib: tag.add violet("  ← shared lib")
    let hasDir = isDir(c.dir)
    let rdir = if c.first: (if hasBuiltBin(c.dir): c.dir else: "")
               elif c.lib: (if hasDir: c.dir else: "")
               else: readyDir(c)
    if rdir.len > 0:
      var line = "  " & green(GOk) & " " & tag & " " & green("ready")
      if rdir != c.dir: line.add dim("  " & tildeAbbrev(rdir))
      stdout.writeLine line
      inc ready
      continue
    if not hasDir:
      inc toClone
      if not c.lib: inc toBuild
      stdout.writeLine "  " & amber("↓") & " " & tag &
        gray("  clone → " & tildeAbbrev(c.dir) & (if c.lib: "" else: " + build"))
      if yes:
        let rc = runInherit("git", @["clone", "https://github.com/" & c.slug & ".git", c.dir])
        if rc != 0:
          stdout.writeLine "    " & red(GCross & " clone failed") &
            dim("  (private repo? needs git access)")
          continue
    elif not c.lib:
      inc toBuild
      stdout.writeLine "  " & violet(GGear) & " " & tag & gray("  present, needs build")
    if c.lib:
      if yes: stdout.writeLine "    " & green(GOk & " ready") & dim(" (source lib, no build)")
      inc ready
      continue
    if yes and hasBuiltBin(c.dir):
      stdout.writeLine "    " & green(GOk & " ready") & dim(" (ships bin/, no build)")
      continue
    if yes:
      let rec = buildRecipe(c.dir)
      if not rec.found or (contains(rec.cmd, "/") and not registry.fileExists(rec.cmd)):
        stdout.writeLine "    " & amber(GWarn) &
          gray(" no build recipe — build " & c.name & " manually" &
               (if c.first: " (see nimony README)" else: ""))
        continue
      stdout.writeLine "    " & violet(GGear) & " " & teal(rec.hint) & gray(" …")
      # Component build.sh scripts expect the freshly-built toolchain on PATH and
      # a few env paths. `bash -c` inherits nothing we do not export, so these are
      # set on the command line itself.
      var envPrefix = ""
      if not c.first:
        envPrefix = "PATH=" & quoteShell(home & "/nimony/bin") & ":$PATH " &
          "NIM=" & quoteShell(findNim()) & " " &
          "NIMONY=" & quoteShell(home & "/nimony/bin/nimony") & " " &
          "NIMONY_SRC=" & quoteShell(home & "/nimony/src") & " " &
          "AOWLKIT=" & quoteShell(home & "/aowlkit/src") & " " &
          "AOWLHL=" & quoteShell(home & "/aowlhl/src") & " "
      var line = "cd " & quoteShell(rec.cwd) & " && " & envPrefix & quoteShell(rec.cmd)
      for a in rec.args: line.add " " & quoteShell(a)
      let rc = execShellCmd(line)
      if rc == 0: stdout.writeLine "    " & green(GOk & " built")
      else: stdout.writeLine "    " & red(GCross & " build exited " & $rc)

  # Private, binary-only components: the step a pure source setup cannot do.
  let rels = releaseTargets(slots, "all")
  var relRepos: seq[string] = @[]
  for t in rels:
    var seen = false
    for x in relRepos:
      if x == t.releaseRepo: seen = true
    if not seen: relRepos.add t.releaseRepo
  for slug in relRepos:
    stdout.writeLine "  " & amber("↓") & " " & bold(white("aowli")) & dim("  " & slug) &
      violet("  ← private, binary release") & gray("  download → ~/.aowl/toolchains")
  stdout.writeLine ""

  if not yes:
    # one gray() span, not two — a second span restarts the SGR sequence and the
    # bytes stop matching even though the words are the same.
    var summary = $ready & " ready, " & $toClone & " to clone, " & $toBuild & " to build"
    if relRepos.len > 0: summary.add ", " & $relRepos.len & " release download"
    stdout.writeLine "  " & gray(summary) & dim("   ·   ") &
      teal(Prog & " setup --yes") & dim(" to execute")
  else:
    note("re-registering…")
    cmdInit(slots, r)
    if relRepos.len > 0:
      stdout.writeLine ""
      stdout.write banner(Prog, "private binaries from public release")
      discard installRelease(slots, "aowli", r)
      if not persist(slots, r): quit 1
  stdout.writeLine ""

# --------------------------------------------------------------------------
# shims, uninstall, rollback
# --------------------------------------------------------------------------

proc cmdShim(slots: seq[Slot], r: Registry) =
  ## Put ~/.aowl/bin on PATH once and every tool follows the active profile.
  ##
  ## The shims resolve at RUN time, not at write time: a shim that baked in
  ## today's path would be a third copy of the resolution answer, and would go
  ## stale exactly the way the backend manifests used to.
  let bindir = aowlHome() & "/bin"
  discard execShellCmd("mkdir -p " & quoteShell(bindir))
  var self = homeDir() & "/aowlup/bin/aowlup-ng"
  if not registry.fileExists(self): self = homeDir() & "/aowlup/bin/aowlup"
  var made = 0
  for s in slots:
    let res = resolveSlot(slots, s.slot, r)
    if res.variantId.len == 0: continue
    let name = res.variantId
    if name == "(env)": continue
    let path = bindir & "/" & name
    let body = "#!/bin/sh\n" &
      "# generated by aowlup — resolves through the registry on every run, so a\n" &
      "# profile switch takes effect without rewriting anything.\n" &
      "exe=$(" & quoteShell(self) & " which " & s.slot & " 2>/dev/null) || exit 1\n" &
      "[ -n \"$exe\" ] || { echo \"aowlup: '" & s.slot & "' is not built\" >&2; exit 1; }\n" &
      "exec \"$exe\" \"$@\"\n"
    try:
      writeFile(path, body)
      discard execShellCmd("chmod 755 " & quoteShell(path))
      inc made
    except:
      discard
  stdout.write banner(Prog, "shims")
  stdout.writeLine kv("wrote", green($made & " shims") & dim("  " & tildeAbbrev(bindir)))
  stdout.writeLine "  " & gray("add to PATH →") & "  " &
    cyan("export PATH=\"" & bindir & ":$PATH\"")
  stdout.writeLine ""

proc listTags(variantId: string): seq[string] =
  ## Installed tags for a release-backed variant, newest mtime first.
  result = @[]
  let dir = aowlHome() & "/toolchains/" & variantId
  let r = runCaptured("ls", @["-t", dir], "", false)
  if not r.ok or r.exitCode != 0: return
  for line in splitLines(r.output):
    let t = strip(line)
    if t.len > 0: result.add t

proc cmdUninstall(slots: seq[Slot], r: var Registry, name: string) =
  if name.len == 0: die("usage: " & Prog & " uninstall <component|all>")
  let targets = releaseTargets(slots, name)
  if targets.len == 0:
    die("nothing release-installed matches '" & name & "'")
  stdout.write banner(Prog, "uninstall")
  var removed = 0
  for t in targets:
    let dir = aowlHome() & "/toolchains/" & t.variantId
    if not isDir(dir):
      stdout.writeLine "  " & gray(GBullet) & " " & bold(t.slot) & gray("  not installed")
      continue
    discard execShellCmd("rm -rf " & quoteShell(dir))
    del(r.components, t.slot)
    del(r.links, t.slot & "/" & t.variantId)
    stdout.writeLine "  " & green(GOk) & " removed " & bold(t.slot) &
      dim("  " & tildeAbbrev(dir))
    inc removed
  if removed > 0 and not persist(slots, r): quit 1
  stdout.writeLine ""
  if removed == 0: note("nothing to remove")

proc cmdRollback(slots: seq[Slot], r: var Registry, name: string) =
  ## Point a slot back at an older installed tag. An install that turns out bad
  ## is a normal event; needing to re-download to escape it is not.
  let targets = releaseTargets(slots, if name.len > 0: name else: "all")
  if targets.len == 0: die("nothing release-installed matches '" & name & "'")
  stdout.write banner(Prog, "rollback")
  var changed = 0
  for t in targets:
    let tags = listTags(t.variantId)
    if tags.len < 2:
      stdout.writeLine "  " & gray(GBullet) & " " & bold(t.slot) &
        gray("  only " & $tags.len & " version installed — nothing to roll back to")
      continue
    let cur = getOrDefault(r.components, t.slot,
      Component(source: "", release: "", version: "", bin: "", prefix: "")).version
    var target = ""
    for tag in tags:
      if tag != cur:
        target = tag
        break
    if target.len == 0: continue
    let tcdir = aowlHome() & "/toolchains/" & t.variantId & "/" & target
    r.components[t.slot] = Component(source: "release", release: t.releaseRepo,
      version: target, bin: tcdir & "/bin/" & t.releaseAsset, prefix: tcdir)
    r.links[t.slot & "/" & t.variantId] = Link(prefix: tcdir, version: target,
                                               source: "release")
    stdout.writeLine "  " & green(GOk) & " " & bold(t.slot) & " " & GArrow & " " &
      cyan(target) & dim("  (was " & (if cur.len > 0: cur else: "unset") & ")")
    inc changed
  if changed > 0 and not persist(slots, r): quit 1
  stdout.writeLine ""

proc cmdHelp() =
  stdout.write banner(Prog, "aoughwl toolchain manager")
  let rows = @[
    @[teal("run FILE [args]"), gray("run an aowl pack by reduction, or compile+run source")],
    @[teal("setup [--yes]"), gray("clone + build the whole toolchain (fresh machine)")],
    @[teal("install [NAME]"), gray("fetch a private-source backend from its public release (aowli)")],
    @[teal("doctor"), gray("resolved toolchain for the active profile")],
    @[teal("profile [use N]"), gray("show / switch the whole-stack profile")],
    @[teal("use SLOT VAR"), gray("override one slot (e.g. use sem nimsem)")],
    @[teal("unset SLOT"), gray("drop a slot override")],
    @[teal("status"), gray("git rev + GitHub update check per component")],
    @[teal("update [N] --yes"), gray("pull updates (check-only without --yes)")],
    @[teal("rebuild N --yes"), gray("rebuild a component from source")],
    @[teal("vscode [DIR] --yes"), gray("wire the editor/LSP to the active profile")],
    @[teal("config [--lsp]"), gray("emit editor initializationOptions")],
    @[teal("shim"), gray("write ~/.aowl/bin shims that follow the active profile")],
    @[teal("uninstall NAME"), gray("remove an installed release component")],
    @[teal("rollback [NAME]"), gray("point a slot back at the previous installed tag")],
    @[teal("backend link S R"), gray("register a working repo for slot S")],
    @[teal("which SLOT"), gray("print the resolved exe (raw)")],
  ]
  stdout.writeLine renderTable(@[column("command"), column("")], rows)
  stdout.writeLine ""
  var profs: seq[string] = @[]
  let ps = profilesOf()   # bind first: a proc's returned seq is not borrowable
  for p in ps:
    profs.add(if p.name == DefaultProfile: violet(p.name) & dim("*") else: gray(p.name))
  stdout.writeLine "  " & dim("profiles: ") & joinStr(profs, dim(" · ")) &
    dim("   ·   one-shot: ") & teal(Prog & " +nimony doctor")
  stdout.writeLine "  " & gray("compile code with ") & teal("aowlmony run <file>") &
    dim("   — aowlup manages the toolchain, aowlmony uses it (rustup : cargo)")
  stdout.writeLine ""

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

proc main() =
  let argv = commandLineParams()
  var args: seq[string] = @[]
  var lsp = false
  var yes = false

  var i = 0
  while i < argv.len:
    let a = argv[i]
    if i == 0 and a.len > 1 and a[0] == '+':
      # rustup-style one-shot profile: `aowlup +nimony doctor`
      let p = a[1 ..< a.len]
      let known = profilesOf()
      if findProfile(known, p) < 0:
        var names: seq[string] = @[]
        for x in known: names.add x.name
        die("unknown profile '+" & p & "'. Known: " & joinStr(names, ", "))
      try:
        putEnv("AOWL_PROFILE", p)
      except:
        die("could not set the ephemeral profile from '" & a & "'")
    elif a == "--lsp": lsp = true
    elif a == "--yes": yes = true
    elif a == "--json" or a == "--check": discard
    elif a == "--help" or a == "-h": args.add "help"
    else: args.add a
    inc i

  let slots = slotsOf()
  var r = loadRegistry()
  let cmd = if args.len > 0: args[0] else: "help"
  let a1 = if args.len > 1: args[1] else: ""
  let a2 = if args.len > 2: args[2] else: ""

  case cmd
  of "help": cmdHelp()
  of "init": cmdInit(slots, r)
  of "setup": cmdSetup(slots, r, yes)
  of "install", "i": cmdInstall(slots, r, a1)
  of "doctor", "dr": cmdDoctor(slots, r)
  of "config": cmdConfig(slots, r, lsp)
  of "which": cmdWhich(slots, r, a1)
  of "list": cmdList(r)
  of "use": cmdUse(slots, r, a1, a2)
  of "unset": cmdUnset(slots, r, a1)
  of "status", "st": cmdStatus(slots, r)
  of "update", "up": cmdUpdate(slots, r, a1, yes)
  of "rebuild", "build": cmdBuild(slots, r, a1, yes)
  of "vscode": cmdVscode(slots, r, a1, yes)
  of "shim", "shims": cmdShim(slots, r)
  of "uninstall": cmdUninstall(slots, r, a1)
  of "rollback": cmdRollback(slots, r, a1)
  of "run":
    var rest: seq[string] = @[]
    var k = 2
    while k < args.len:
      rest.add args[k]
      inc k
    cmdRun(a1, rest)
  of "profile", "p":
    if a1.len == 0 or a1 == "list" or a1 == "show": cmdProfileList(r)
    elif a1 == "use": cmdProfileUse(slots, r, a2)
    else: die("profile subcommands: list | use <name>")
  of "backend", "b":
    case a1
    of "list": cmdList(r)
    of "which": cmdWhich(slots, r, a2)
    of "link":
      let a3 = if args.len > 3: args[3] else: ""
      cmdLink(slots, r, a2, a3)
    else: die("backend subcommands: list | link <slot> <repo> | which <slot>")
  else:
    die("unknown command '" & cmd & "'. Try `" & Prog & " help`.")

  quit exitCode

main()
