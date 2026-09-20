## Talks to the aoughwl store (aoughwl.com/api/v1) to turn a purchased licence
## key into a downloadable release. Shells to curl, same as gh.nim and for the
## same reason: this must work before any TLS stack this project owns exists.

import std/strutils
import aowlkit/subprocess

const StoreApi* = "https://aoughwl.com/api/v1"

type
  DownloadInfo* = object
    ok*: bool
    url*: string
    version*: string
    sha256*: string
    error*: string
    detail*: string

proc jfield(j, name: string): string =
  ## Extract one JSON field's raw text (string or bare number/bool/null). The
  ## store's replies are compact with no escapes in these particular fields
  ## (urls, versions, hex digests, slug-shaped errors), so a purpose-built scan
  ## is enough -- deliberately the SAME approach as the C launcher's `jstr`/
  ## `jnum` (aowl-release/launcher/util.h), so the two never learn to parse
  ## JSON two different ways.
  result = ""
  let pat = "\"" & name & "\":"
  let i = find(j, pat)
  if i < 0: return
  var k = i + pat.len
  while k < j.len and j[k] == ' ': inc k
  if k >= j.len: return
  if j[k] == '"':
    inc k
    while k < j.len and j[k] != '"':
      if j[k] == '\\': return ""   # an escape means the fast path does not apply
      result.add j[k]
      inc k
    return
  while k < j.len and j[k] != ',' and j[k] != '}' and j[k] != '\n' and j[k] != ' ':
    result.add j[k]
    inc k

proc storeDownload*(key: string): DownloadInfo =
  ## POST {"key"} to /download. The key goes over stdin (never argv/env), so it
  ## never shows in `ps` -- it is bearer-token-shaped, not a debugging value.
  result = DownloadInfo(ok: false)
  let body = "{\"key\":\"" & key & "\"}"
  let r = runWithInput("curl",
    @["-sS", "-m", "20", "-H", "Content-Type: application/json", "--data-binary", "@-",
      StoreApi & "/download"], body)
  if not r.ok:
    result.error = "network"
    return
  let j = r.output
  if find(j, "\"ok\":true") < 0:
    result.error = jfield(j, "error")
    result.detail = jfield(j, "detail")
    return
  result.ok = true
  result.url = jfield(j, "url")
  result.version = jfield(j, "version")
  result.sha256 = jfield(j, "sha256")
