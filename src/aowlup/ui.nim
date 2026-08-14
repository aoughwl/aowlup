## Presentation layer: truecolor ANSI, ANSI-aware padding, and the aligned table.
##
## No dependencies beyond the stdlib. Colour is OFF for NO_COLOR, TERM=dumb and
## non-TTY output, ON when FORCE_COLOR is set — the same rule the whole aoughwl
## CLI family uses, so piping any of these tools into a file gives plain text.

import std/[syncio, strutils, envvars, terminal]

const
  # aoughwl palette — teal primary (the owl), violet for profiles.
  Teal* = "45;212;191"
  TealDim* = "20;148;136"
  Violet* = "167;139;250"
  Green* = "52;211;153"
  Amber* = "251;191;36"
  Red* = "248;113;113"
  Cyan* = "103;232;249"
  Gray* = "120;130;145"
  White* = "228;232;240"

  # glyphs
  GDiamond* = "◆"
  GDot* = "●"
  GRing* = "○"
  GOk* = "✓"
  GDown* = "⬇"
  GUp* = "▲"
  GCross* = "✗"
  GBullet* = "·"
  GGear* = "⚙"
  GArrow* = "→"
  GBar* = "│"
  GWarn* = "⚠"

var colorOn = false
var colorKnown = false

proc colorEnabled*(): bool =
  ## Decided once per process. FORCE_COLOR wins over the TTY check so that a
  ## harness capturing our output can still exercise the styled paths.
  if not colorKnown:
    colorKnown = true
    let noColor = getEnv("NO_COLOR", "")
    let term = getEnv("TERM", "")
    if noColor.len > 0 or term == "dumb":
      colorOn = false
    elif getEnv("FORCE_COLOR", "").len > 0:
      colorOn = true
    else:
      colorOn = isatty(stdout)
  colorOn

proc col*(rgb: string, s: string): string =
  if colorEnabled(): "\e[38;2;" & rgb & "m" & s & "\e[0m" else: s

proc bold*(s: string): string =
  if colorEnabled(): "\e[1m" & s & "\e[22m" else: s

proc dim*(s: string): string =
  if colorEnabled(): "\e[2m" & s & "\e[22m" else: s

proc teal*(s: string): string = col(Teal, s)
proc violet*(s: string): string = col(Violet, s)
proc green*(s: string): string = col(Green, s)
proc amber*(s: string): string = col(Amber, s)
proc red*(s: string): string = col(Red, s)
proc cyan*(s: string): string = col(Cyan, s)
proc gray*(s: string): string = col(Gray, s)
proc white*(s: string): string = col(White, s)

proc visibleLen*(s: string): int =
  ## Column width: SGR escapes discarded, and UTF-8 counted in CHARACTERS, not
  ## bytes. Every glyph in this UI (◆ ✓ ✗ ⬇ →) is multi-byte, so a byte count
  ## silently under-pads exactly the cells that carry status — the columns most
  ## worth reading.
  var n = 0
  var i = 0
  while i < s.len:
    if s[i] == '\e':
      # skip to the terminating letter of the escape sequence
      inc i
      while i < s.len and s[i] != 'm':
        inc i
      if i < s.len: inc i
    else:
      # count a codepoint once: continuation bytes are 0b10xxxxxx
      if (uint8(s[i]) and 0xC0'u8) != 0x80'u8: inc n
      inc i
  n

proc padRight*(s: string, n: int): string =
  let v = visibleLen(s)
  if v >= n: s else: s & repeat(' ', n - v)

proc padLeft*(s: string, n: int): string =
  let v = visibleLen(s)
  if v >= n: s else: repeat(' ', n - v) & s

proc joinStr*(xs: seq[string], sep: string): string =
  ## std/strutils has no `join`.
  var r = ""
  var first = true
  for x in xs:
    if not first: r.add sep
    r.add x
    first = false
  r

type Column* = object
  title*: string
  alignRight*: bool

proc column*(title: string, alignRight = false): Column =
  Column(title: title, alignRight: alignRight)

proc renderTable*(cols: seq[Column], rows: seq[seq[string]], indent = "  "): string =
  ## Header is dim+bold uppercase over a hairline rule; cells may be pre-styled.
  var w: seq[int] = @[]
  for c in cols: w.add visibleLen(c.title)
  for r in rows:
    var i = 0
    while i < r.len and i < w.len:
      let v = visibleLen(r[i])
      if v > w[i]: w[i] = v
      inc i

  var head: seq[string] = @[]
  var rule: seq[string] = @[]
  var i = 0
  while i < cols.len:
    head.add bold(gray(padRight(toUpperAscii(cols[i].title), w[i])))
    rule.add dim(repeat("─", w[i]))
    inc i

  var res = indent & joinStr(head, "  ") & "\n" & indent & joinStr(rule, "  ")
  for r in rows:
    var cells: seq[string] = @[]
    var j = 0
    while j < cols.len:
      let raw = if j < r.len: r[j] else: ""
      cells.add(if cols[j].alignRight: padLeft(raw, w[j]) else: padRight(raw, w[j]))
      inc j
    res.add "\n" & indent & joinStr(cells, "  ")
  res

proc banner*(prog: string, sub: string): string =
  "\n  " & teal(GDiamond) & " " & bold(teal(prog)) & "  " & dim(GBar) & "  " &
    gray(sub) & "\n"

proc pill*(txt: string): string =
  ## A colour-block label for the active profile.
  bold(violet(" " & txt & " "))

proc kv*(k: string, v: string): string =
  "  " & gray(padRight(k, 9)) & v
