## The slot catalog: every stage of the pipeline, and the interchangeable
## implementations registered for it.
##
## Three axes, as in the manager's front page:
##   VARIANTS  — a slot's interchangeable implementations (parser = aowlparser |
##               nifler, sem = aowlsem | nimsem, hexer = aowlhexer | hexer).
##   PROFILES  — a named whole-stack selection over the PASS slots only.
##   VERSIONS  — handled in registry.nim / the status command, not here.
##
## This module is pure data plus lookups: no filesystem, no environment. That is
## deliberate — resolve.nim is the only place that decides where a binary lives,
## so there is exactly one answer to "which exe is this slot".

import std/strutils

type
  Variant* = object
    id*: string          ## the name a user types: `aowlup use sem nimsem`
    origin*: string      ## "aoughwl" (family-probed) | "nimony" (one repo dir)
    repoStem*: string    ## aoughwl: stem, probed across the aowl/aif/nif family
    binStem*: string     ## aoughwl: binary stem, same family probe
    binSuffix*: string   ## aoughwl: e.g. "-interp" for aowli-interp
    repoDir*: string     ## nimony: directory under $HOME holding bin/
    bin*: string         ## nimony: exact binary name
    releaseRepo*: string ## set => installable from a public GitHub release
    releaseAsset*: string

  Slot* = object
    slot*: string
    kind*: string        ## "pass" | "backend" | "tool"
    consumes*: string
    produces*: string
    target*: string      ## backends only: the target name (native/interp/js/…)
    runner*: string      ## backends only: how the exe is invoked ("node"/"")
    modes*: seq[string]
    defaultMode*: string
    flags*: seq[string]
    needs*: seq[string]  ## external programs the slot needs (e.g. gcc)
    cfgKey*: string      ## editor initializationOptions key, if any
    note*: string
    variants*: seq[Variant]

  Profile* = object
    name*: string
    parser*: string
    sem*: string
    hexer*: string

const
  DefaultProfile* = "hybrid"
  ## The rename family. A dev checkout may still be spelled aif*/nif* from
  ## before the rename, so every probe walks all three.
  Prefixes* = ["aowl", "aif", "nif"]

proc ours(id, repoStem, binStem: string, binSuffix = "",
          releaseRepo = "", releaseAsset = ""): Variant =
  Variant(id: id, origin: "aoughwl", repoStem: repoStem, binStem: binStem,
          binSuffix: binSuffix, repoDir: "", bin: "",
          releaseRepo: releaseRepo, releaseAsset: releaseAsset)

proc theirs(id, repoDir, bin: string): Variant =
  Variant(id: id, origin: "nimony", repoStem: "", binStem: "", binSuffix: "",
          repoDir: repoDir, bin: bin, releaseRepo: "", releaseAsset: "")

proc slotsOf*(): seq[Slot] =
  ## Built fresh rather than held in a const: nimony's const evaluator does not
  ## need to walk this, and the cost is a few dozen allocations once per process.
  result = @[]

  result.add Slot(slot: "parser", kind: "pass", consumes: ".nim", produces: ".p.nif",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "user modules; stdlib always via nifler",
    variants: @[ours("aowlparser", "parser", "parser"), theirs("nifler", "nimony", "nifler")])

  result.add Slot(slot: "sem", kind: "pass", consumes: ".p.nif", produces: ".s.nif",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "aowlsem m <in.p.nif> <out.s.nif>",
    variants: @[ours("aowlsem", "sem", "sem"), theirs("nimsem", "nimony", "nimsem")])

  result.add Slot(slot: "hexer", kind: "pass", consumes: ".s.nif", produces: ".c.nif",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "c=lower, d=cross-module DCE",
    variants: @[ours("aowlhexer", "hexer", "hexer"), theirs("hexer", "nimony", "hexer")])

  result.add Slot(slot: "opt", kind: "pass", consumes: ".s.nif", produces: ".s.nif",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "high-level optimizer, folded into aowlsem",
    variants: @[ours("aowlsem", "sem", "sem")])

  result.add Slot(slot: "native", kind: "backend", consumes: ".c.nif", produces: "",
    target: "native", runner: "node", modes: @["emit", "build", "run", "exec"],
    defaultMode: "run", flags: @[], needs: @["gcc"], cfgKey: "",
    note: "node aowlc {mode} <f.c.nif>",
    variants: @[ours("aowlc", "c", "c")])

  # interp and dbg are PRIVATE-source components: end users cannot build them,
  # they fetch the published hardened binaries. releaseRepo/releaseAsset mark a
  # variant as installable from the public release repo.
  result.add Slot(slot: "interp", kind: "backend", consumes: ".s.nif", produces: "",
    target: "interp", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "aowli-interp <f.s.nif> (tree-walk)",
    variants: @[ours("aowli-interp", "i", "i", "-interp",
                     "aoughwl/aowli-release", "aowli-interp")])

  # vm ships no release asset (unpublished) — link/local-build only.
  result.add Slot(slot: "vm", kind: "backend", consumes: ".s.nif", produces: "",
    target: "vm", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "aowli-vm <f.s.nif> (bytecode)",
    variants: @[ours("aowli-vm", "i", "i", "-vm")])

  result.add Slot(slot: "dbg", kind: "tool", consumes: ".s.nif", produces: "",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "aowli-dbg <f.s.nif> (batch breakpoints / trace)",
    variants: @[ours("aowli-dbg", "i", "i", "-dbg",
                     "aoughwl/aowli-release", "aowli-dbg")])

  result.add Slot(slot: "js", kind: "backend", consumes: ".s.nif", produces: "",
    target: "js", runner: "", modes: @[], defaultMode: "", flags: @["--faithful"],
    needs: @[], cfgKey: "", note: "aowljs [--faithful] <f.s.nif> → stdout",
    variants: @[ours("aowljs", "js", "js")])

  result.add Slot(slot: "ts", kind: "backend", consumes: ".s.nif", produces: "",
    target: "ts", runner: "", modes: @[], defaultMode: "", flags: @["--faithful"],
    needs: @[], cfgKey: "", note: "aowlts [--faithful] <f.s.nif> → stdout",
    variants: @[ours("aowlts", "ts", "ts")])

  result.add Slot(slot: "py", kind: "backend", consumes: ".s.nif", produces: "",
    target: "py", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "aowlpy <f.s.nif> → stdout",
    variants: @[ours("aowlpy", "py", "py")])

  result.add Slot(slot: "lsp", kind: "tool", consumes: ".nim", produces: "",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "language server",
    variants: @[ours("aowllsp", "lsp", "lsp")])

  result.add Slot(slot: "suggest", kind: "tool", consumes: ".nim", produces: "",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "aowlsuggestExe", note: "quick-fix / lint layer (LSP delegates here)",
    variants: @[ours("aowlsuggest", "suggest", "suggest")])

  result.add Slot(slot: "fmt", kind: "tool", consumes: ".nim", produces: "",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "aowlfmtExe", note: "verified layout formatter",
    variants: @[ours("aowlfmt", "fmt", "fmt")])

  result.add Slot(slot: "lens", kind: "tool", consumes: ".s.nif", produces: "",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "aowllensExe", note: "NIF-lens: decls/render/index/outline/query",
    variants: @[ours("aowllens", "lens", "lens")])

  # THE DRIVER ITSELF. It is not a stage of the pipeline, but it is the piece a
  # person actually types, and leaving it out of the catalog meant `aowlup
  # install` could fetch every component of a toolchain and not the thing that
  # drives them: a stranger could install the manager and then have nothing to
  # compile with. It carries a release asset for exactly that reason.
  result.add Slot(slot: "driver", kind: "tool", consumes: ".nim", produces: "",
    target: "", runner: "", modes: @[], defaultMode: "", flags: @[], needs: @[],
    cfgKey: "", note: "aowlmony — compiles code against the selected toolchain",
    variants: @[ours("aowlmony", "mony", "mony", "",
                     "aoughwl/aowlmony", "aowlmony-linux-amd64")])

proc profilesOf*(): seq[Profile] =
  ## Only the PASS slots differ; backends and tooling are ours in every profile.
  ## `hybrid` mirrors what the driver actually runs today.
  @[Profile(name: "aowl", parser: "aowlparser", sem: "aowlsem", hexer: "aowlhexer"),
    Profile(name: "nimony", parser: "nifler", sem: "nimsem", hexer: "hexer"),
    Profile(name: "hybrid", parser: "aowlparser", sem: "nimsem", hexer: "aowlhexer")]

proc findSlot*(slots: seq[Slot], name: string): int =
  ## Index into `slots`, or -1. Callers must handle -1 — an unknown slot is a
  ## user typo, not an internal error.
  var i = 0
  while i < slots.len:
    if slots[i].slot == name: return i
    inc i
  -1

proc findVariant*(s: Slot, id: string): int =
  var i = 0
  while i < s.variants.len:
    if s.variants[i].id == id: return i
    inc i
  -1

proc findProfile*(ps: seq[Profile], name: string): int =
  var i = 0
  while i < ps.len:
    if ps[i].name == name: return i
    inc i
  -1

proc variantFor*(p: Profile, slot: string): string =
  ## The profile's choice for a PASS slot; "" for slots a profile does not pin.
  case slot
  of "parser": p.parser
  of "sem": p.sem
  of "hexer": p.hexer
  else: ""

proc variantIds*(s: Slot): seq[string] =
  result = @[]
  for v in s.variants: result.add v.id

proc slotNames*(slots: seq[Slot]): seq[string] =
  result = @[]
  for s in slots: result.add s.slot

proc envKey*(slot: string): string =
  ## `AOWL_<SLOT>` — the highest-precedence override.
  "AOWL_" & toUpperAscii(slot)
