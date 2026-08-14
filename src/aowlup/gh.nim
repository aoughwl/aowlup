## git and GitHub, both shelled out.
##
## `curl` and `git` stay external on purpose: this is a toolchain manager, not an
## HTTP client, and the one job it must never fail at is bootstrapping a machine
## that has neither our runtime nor our TLS stack built yet.
##
## Every call is capture-based through aowlkit's runCaptured — nimony's own
## execCmdEx mangles long lines, which silently corrupts JSON.

import std/[strutils, json]
import aowlkit/subprocess

type
  Compare* = object
    slug*: string
    branch*: string
    head*: string
    status*: string   ## "identical" | "ahead" | "behind" | "diverged"
    behind*: int
    ahead*: int
    error*: string    ## "" when the comparison succeeded

  Asset* = object
    name*: string
    url*: string

  Release* = object
    slug*: string
    tag*: string
    assets*: seq[Asset]
    error*: string

proc gitOut*(dir: string, args: seq[string]): string =
  ## Trimmed stdout, or "" for any failure. Callers treat "" as "not a git repo
  ## / no answer", which is the only distinction they need.
  var full = @["-C", dir]
  for a in args: full.add a
  let r = runCaptured("git", full, "", false)
  if r.ok and r.exitCode == 0: strip(r.output) else: ""

proc isDirty*(dir: string): bool =
  gitOut(dir, @["status", "--porcelain"]).len > 0

proc ghSlug*(url: string): string =
  ## owner/repo out of any github remote spelling (https, ssh, with or without
  ## the .git suffix and a trailing slash).
  if url.len == 0: return ""
  let i = find(url, "github.com")
  if i < 0: return ""
  var rest = url[i + len("github.com") ..< url.len]
  while rest.len > 0 and (rest[0] == ':' or rest[0] == '/'):
    rest = rest[1 ..< rest.len]
  while rest.len > 0 and rest[rest.len - 1] == '/':
    rest = rest[0 ..< rest.len - 1]
  if rest.endsWith(".git"):
    rest = rest[0 ..< rest.len - 4]
  let parts = split(rest, '/')
  if parts.len < 2: return ""
  parts[0] & "/" & parts[1]

proc curlJson(url: string, timeoutSecs: int): tuple[body: string, ok: bool] =
  let r = runCaptured("curl", @["-sSL", "-m", $timeoutSecs, "-H",
                                "Accept: application/vnd.github+json", url], "", false)
  # The verdict is computed into a `let` BEFORE the tuple is built, and that is
  # load-bearing. Returning `(r.output, r.ok and … )` directly compiles without a
  # diagnostic and evaluates to FALSE for a request that plainly succeeded: the
  # first element moves r.output and the `and` expression is then read against
  # the moved-from local. Reported upstream with a minimal reproducer.
  let ok = r.ok and r.exitCode == 0 and r.output.len > 0
  (r.output, ok)

proc topLevel(body: string, key: string): string =
  ## One field off a JSON object, as a string. Returns "" when absent.
  var tree: JsonTree
  try:
    tree = parseJson(body)
  except:
    return ""
  if hasError(tree): return ""
  for k, v in pairs(root(tree)):
    if k == key:
      case kind(v)
      of JInt: return $getInt(v, 0)
      else: return getStr(v, "")
  ""

proc ghCompare*(dir: string): Compare =
  ## How far the checkout is from its own branch on GitHub. Unauthenticated: this
  ## only ever reads public metadata.
  result = Compare(slug: "", branch: "", head: "", status: "", behind: 0,
                   ahead: 0, error: "")
  let head = gitOut(dir, @["rev-parse", "HEAD"])
  let branch = gitOut(dir, @["rev-parse", "--abbrev-ref", "HEAD"])
  let slug = ghSlug(gitOut(dir, @["remote", "get-url", "origin"]))
  if head.len == 0 or branch.len == 0 or slug.len == 0:
    result.error = "no-git"
    return
  result.slug = slug
  result.branch = branch
  result.head = if head.len >= 7: head[0 ..< 7] else: head

  let url = "https://api.github.com/repos/" & slug & "/compare/" & branch & "..." & head
  let got = curlJson(url, 8)
  if not got.ok:
    result.error = "offline"
    return
  var tree: JsonTree
  try:
    tree = parseJson(got.body)
  except:
    result.error = "bad-json"
    return
  if hasError(tree):
    result.error = "bad-json"
    return
  let msg = topLevel(got.body, "message")
  if msg.len > 0:
    # "Not Found" here means the branch was never pushed, not that the repo is
    # missing — saying "local-only" is the honest reading.
    result.error = if msg == "Not Found": "unpushed" else: msg
    return
  result.status = topLevel(got.body, "status")
  try:
    result.behind = parseInt(topLevel(got.body, "behind_by"))
  except:
    result.behind = 0
  try:
    result.ahead = parseInt(topLevel(got.body, "ahead_by"))
  except:
    result.ahead = 0

proc ghLatestRelease*(slug: string): Release =
  result = Release(slug: slug, tag: "", assets: @[], error: "")
  let got = curlJson("https://api.github.com/repos/" & slug & "/releases/latest", 15)
  if not got.ok:
    result.error = "offline"
    return
  var tree: JsonTree
  try:
    tree = parseJson(got.body)
  except:
    result.error = "bad-json"
    return
  if hasError(tree):
    result.error = "bad-json"
    return
  for k, v in pairs(root(tree)):
    case k
    of "message":
      result.error = getStr(v, "error")
      return
    of "tag_name":
      result.tag = getStr(v, "")
    of "assets":
      for a in items(v):
        # NB: locals must NOT share a name with the object's fields — nimony
        # mangles the collision into a C struct member that does not exist, and
        # the failure surfaces as a gcc error about the generated code.
        var assetName = ""
        var assetUrl = ""
        for ak, av in pairs(a):
          if ak == "name": assetName = getStr(av, "")
          elif ak == "browser_download_url": assetUrl = getStr(av, "")
        if assetName.len > 0:
          result.assets.add Asset(name: assetName, url: assetUrl)
    else: discard

proc downloadTo*(url, dest: string): bool =
  let r = runCaptured("curl", @["-sSL", "-m", "180", "-o", dest, url], "", false)
  let ok = r.ok and r.exitCode == 0
  ok

proc sha256Of*(path: string): string =
  ## Shelled out: this runs before the toolchain it installs exists, so it can
  ## only rely on what a base system already has.
  let r = runCaptured("sha256sum", @[path], "", false)
  if not r.ok or r.exitCode != 0: return ""
  let parts = split(strip(r.output), ' ')
  if parts.len > 0: parts[0] else: ""

proc hostTriple*(): string =
  ## `<os>-<arch>`, matching the asset naming a multi-platform release needs.
  ## Selecting an asset by exact name works for exactly one platform, which is
  ## the same as not supporting any.
  let osr = runCaptured("uname", @["-s"], "", false)
  let arr = runCaptured("uname", @["-m"], "", false)
  var osName = if osr.ok: toLowerAscii(strip(osr.output)) else: ""
  var arch = if arr.ok: strip(arr.output) else: ""
  if osName == "darwin": osName = "macos"
  if arch == "x86_64": arch = "amd64"
  elif arch == "aarch64": arch = "arm64"
  if osName.len == 0 or arch.len == 0: "" else: osName & "-" & arch

proc pickAsset*(rel: Release, want: string): tuple[name, url, sha: string] =
  ## Prefer the asset for THIS platform, fall back to the bare name, and pick up
  ## a sibling `<asset>.sha256` when the release publishes one.
  result = ("", "", "")
  let triple = hostTriple()
  var chosenName = ""
  var chosenUrl = ""
  if triple.len > 0:
    for a in rel.assets:
      if a.name == want & "-" & triple:
        chosenName = a.name
        chosenUrl = a.url
  if chosenName.len == 0:
    for a in rel.assets:
      if a.name == want:
        chosenName = a.name
        chosenUrl = a.url
  if chosenName.len == 0: return
  var shaUrl = ""
  for a in rel.assets:
    if a.name == chosenName & ".sha256": shaUrl = a.url
  (chosenName, chosenUrl, shaUrl)

proc fetchExpectedSha*(url: string): string =
  ## The published digest, as `sha256sum` writes it: "<hex>  <name>".
  if url.len == 0: return ""
  let r = runCaptured("curl", @["-sSL", "-m", "30", url], "", false)
  if not r.ok or r.exitCode != 0: return ""
  let parts = split(strip(r.output), ' ')
  if parts.len > 0: parts[0] else: ""
