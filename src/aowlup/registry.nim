## `~/.aowl/registry.json` — the single source of truth for which implementation
## is selected for each slot, and where it lives.
##
## The seam with the driver is one-directional and deliberate: **aowlup writes
## this file, aowlmony only ever reads it** (through `aowlup config`). Nothing
## else may write it, or the two tools start disagreeing about which binary is
## "the" binary — which has already happened once on a live machine.
##
## Shape:
##   { "profile": "hybrid",
##     "overrides": { "<slot>": "<variantId>" },
##     "links":     { "<slot>/<variantId>": {prefix, version, source} },
##     "components":{ "<slot>": {source, release, version, bin, prefix} } }

import std/[syncio, strutils, envvars, json, tables, os]
import aowlkit/tty

type
  Link* = object
    prefix*: string   ## the repo / toolchain dir holding bin/
    version*: string  ## a REAL version: a git short-sha, or a release tag
    source*: string   ## "" (source checkout) | "release"

  Component* = object
    source*: string   ## "release"
    release*: string  ## owner/repo the asset came from
    version*: string  ## the release tag, verbatim ("v0.3.0", not "0.3.0")
    bin*: string
    prefix*: string

  Registry* = object
    profile*: string
    overrides*: Table[string, string]
    links*: Table[string, Link]
    components*: Table[string, Component]

proc homeDir*(): string =
  let h = getEnv("HOME", "")
  if h.len > 0: h else: "/root"

proc aowlHome*(): string =
  let e = getEnv("AOWL_HOME", "")
  if e.len > 0: e else: homeDir() & "/.aowl"

proc regPath*(): string = aowlHome() & "/registry.json"

proc fileExists*(p: string): bool =
  ## nimony's std/os has no fileExists; opening for read is the idiom.
  var f: File
  if open(f, p, fmRead):
    close(f)
    true
  else:
    false

proc tildeAbbrev*(p: string): string =
  let h = homeDir()
  if h.len > 0 and p.startsWith(h): "~" & p[h.len ..< p.len] else: p

# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------

proc emptyRegistry*(): Registry =
  Registry(profile: "", overrides: initTable[string, string](),
           links: initTable[string, Link](),
           components: initTable[string, Component]())

proc fieldStr(n: JsonNode, key: string): string =
  ## One level of object field access. Returns "" when absent, which is what
  ## every caller here wants — a missing optional field is not an error.
  for k, v in pairs(n):
    if k == key: return getStr(v, "")
  ""

proc loadRegistry*(): Registry =
  ## A missing or unreadable registry is not an error: it means "not initialised
  ## yet", and every command still resolves through the dev-fallback probe.
  result = emptyRegistry()
  let p = regPath()
  if not fileExists(p): return

  var tree: JsonTree
  try:
    tree = parseFile(p)
  except:
    stdout.writeLine "  " & red(GWarn & " registry.json is unreadable — treating it as empty")
    return
  if hasError(tree): return

  let r = root(tree)
  for key, node in pairs(r):
    case key
    of "profile":
      result.profile = getStr(node, "")
    of "overrides":
      for slot, v in pairs(node):
        result.overrides[slot] = getStr(v, "")
    of "links":
      for name, v in pairs(node):
        result.links[name] = Link(prefix: fieldStr(v, "prefix"),
                                  version: fieldStr(v, "version"),
                                  source: fieldStr(v, "source"))
    of "components":
      for slot, v in pairs(node):
        result.components[slot] = Component(source: fieldStr(v, "source"),
                                            release: fieldStr(v, "release"),
                                            version: fieldStr(v, "version"),
                                            bin: fieldStr(v, "bin"),
                                            prefix: fieldStr(v, "prefix"))
    else: discard

# --------------------------------------------------------------------------
# writing
# --------------------------------------------------------------------------

proc jsonEscape(s: string): string =
  result = ""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add c

proc q(s: string): string = "\"" & jsonEscape(s) & "\""

proc sortedKeys[T](t: Table[string, T]): seq[string] =
  ## Stable output matters: the registry is read by humans and diffed by tools,
  ## and a hash-order shuffle would make every write look like a change.
  result = @[]
  for k, _ in pairs(t): result.add k
  # selection sort via `swap`: assigning one element of a seq from another
  # trips nimony's alias check, and the key count here is a couple of dozen.
  var i = 0
  while i < result.len:
    var j = i + 1
    while j < result.len:
      if result[j] < result[i]: swap(result[i], result[j])
      inc j
    inc i

proc field(name, value: string, more: bool): string =
  if value.len == 0: "" else: "      " & q(name) & ": " & q(value) & (if more: ",\n" else: "\n")

proc renderRegistry*(r: Registry): string =
  var s = "{\n"
  s.add "  " & q("profile") & ": " & q(r.profile) & ",\n"

  s.add "  " & q("overrides") & ": {"
  let ok = sortedKeys(r.overrides)
  if ok.len == 0:
    s.add "},\n"
  else:
    s.add "\n"
    var i = 0
    while i < ok.len:
      s.add "    " & q(ok[i]) & ": " & q(getOrDefault(r.overrides, ok[i], ""))
      s.add(if i + 1 < ok.len: ",\n" else: "\n")
      inc i
    s.add "  },\n"

  s.add "  " & q("links") & ": {"
  let lk = sortedKeys(r.links)
  if lk.len == 0:
    s.add "},\n"
  else:
    s.add "\n"
    var i = 0
    while i < lk.len:
      let l = getOrDefault(r.links, lk[i], Link(prefix: "", version: "", source: ""))
      s.add "    " & q(lk[i]) & ": {\n"
      s.add field("prefix", l.prefix, true)
      s.add field("version", l.version, l.source.len > 0)
      s.add field("source", l.source, false)
      s.add "    }"
      s.add(if i + 1 < lk.len: ",\n" else: "\n")
      inc i
    s.add "  },\n"

  s.add "  " & q("components") & ": {"
  let ck = sortedKeys(r.components)
  if ck.len == 0:
    s.add "}\n"
  else:
    s.add "\n"
    var i = 0
    while i < ck.len:
      let c = getOrDefault(r.components, ck[i],
        Component(source: "", release: "", version: "", bin: "", prefix: ""))
      s.add "    " & q(ck[i]) & ": {\n"
      s.add field("source", c.source, true)
      s.add field("release", c.release, true)
      s.add field("version", c.version, true)
      s.add field("bin", c.bin, true)
      s.add field("prefix", c.prefix, false)
      s.add "    }"
      s.add(if i + 1 < ck.len: ",\n" else: "\n")
      inc i
    s.add "  }\n"

  s.add "}\n"
  s

# --------------------------------------------------------------------------
# the write lock
# --------------------------------------------------------------------------
#
# `mkdir` is atomic on POSIX — it fails if the directory already exists — and it
# is the only exclusive-create primitive reachable from nimony's stdlib today
# (there is no O_EXCL). That makes it a real lock, not a decorative one: two
# `aowlup use` runs cannot interleave their read-modify-write and lose an edit.
#
# A lock we cannot take is reported, never silently skipped: a stale lock left by
# a killed process must look like a problem, because that is what it is.

proc lockPath(): string = aowlHome() & "/.registry.lock"

proc acquireLock*(waitSeconds = 10): bool =
  let d = lockPath()
  var waited = 0
  while true:
    if execShellCmd("mkdir " & quoteShell(d) & " 2>/dev/null") == 0:
      return true
    if waited >= waitSeconds: return false
    discard execShellCmd("sleep 0.2")
    waited = waited + 1

proc releaseLock*() =
  discard execShellCmd("rmdir " & quoteShell(lockPath()) & " 2>/dev/null")

proc saveRegistry*(r: Registry): bool =
  ## Returns false (loudly) rather than corrupting a concurrent edit.
  discard execShellCmd("mkdir -p " & quoteShell(aowlHome()))
  if not acquireLock():
    stdout.writeLine "  " & red(GCross) & " registry is locked by another " &
      "aowlup (stale? remove " & tildeAbbrev(lockPath()) & ")"
    return false
  var wrote = false
  try:
    writeFile(regPath(), renderRegistry(r))
    wrote = true
  except:
    stdout.writeLine "  " & red(GCross) & " could not write " & tildeAbbrev(regPath())
  releaseLock()
  wrote

proc withProfile*(r: Registry, defaultProfile: string): string =
  if r.profile.len > 0: r.profile else: defaultProfile
