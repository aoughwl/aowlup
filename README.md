# aowlup

The **aoughwl toolchain manager** — `rustup` for the aowl/nimony stack.

`aowlup` installs, versions, and *selects* the components of the compilation
pipeline; **[aowlmony](https://github.com/aoughwl/aowlmony)** compiles your code
against whatever `aowlup` has selected. The relationship is exactly **rustup :
cargo** — one provisions the toolchain, the other runs it.

```
aowlup  ── manages the toolchain ──►  ~/.aowl/registry.json  ◄── reads ──  aowlmony
                                       (single source of truth)
```

## Written in aowl

`aowlup` is being rewritten from JavaScript into **the language it manages** —
the manager for a self-hosted toolchain ought to be built by that toolchain.

```sh
./build.sh            # → bin/aowlup-ng   (needs nimony + aowlkit)
./test/diff.sh        # every command, Node build vs Nimony build, byte-for-byte
./test/registry.sh    # the write path, against a sandboxed AOWL_HOME
```

The JavaScript build in `bin/aowlup` stays the installed entry point and serves
as the **oracle**: a command counts as ported only when its stdout, stderr and
exit code are byte-identical to the original, or the difference is listed in
`test/diff.sh` with a reason. Today that is 40 of 48 checks identical and 8
deliberate improvements — real recorded versions instead of a hardcoded
`"0.1.0"`, an unresolvable slot that names every path it probed, an unknown slot
told apart from an unbuilt one, and the new `shim` / `uninstall` / `rollback`
commands.

Once parity is complete the Nimony binary becomes `aowlup` and ships as a
prebuilt release asset, so installing the toolchain no longer requires already
having it.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/aoughwl/aowlup/main/install.sh | sh
export PATH="$HOME/.aowl/bin:$PATH"
aowlup setup --yes        # clones + builds the rest of the toolchain
```

Published builds are at [releases](https://github.com/aoughwl/aowlup/releases).
The current one is a **pre-release** and needs **glibc ≥ 2.34** (Ubuntu 22.04+,
Debian 12+) — `install.sh` checks that before installing and tells you to build
from source rather than leaving you a binary that cannot start.

`install.sh` is POSIX sh and is the only part of this project not written in the
language — it necessarily runs on a machine that has none of it yet. It downloads
a prebuilt `aowlup` for your platform, **verifies its sha256**, and puts it in
`~/.aowl/bin`; everything after that is `aowlup`'s job.

`aowlup shim` then writes per-tool shims into `~/.aowl/bin` that resolve through
the registry **on every run**, so switching profile changes what they execute
without rewriting anything. `aowlup uninstall` and `aowlup rollback` undo an
install — a version that turns out bad is a normal event, and needing to
re-download to escape it is not.

## The three axes

- **Variants** — every pipeline *slot* has interchangeable implementations. The
  parser can be **aowlparser** (ours) or nimony's **nifler**; sem **aowlsem** or
  **nimsem**; lowering **aowlhexer** or nimony's **hexer**. Backends
  (`native/interp/vm/js/ts/py`) and tooling (`lsp/suggest/fmt/lens`) live in the
  same catalog.
- **Profiles** — a named whole-stack selection, flipped in one command:

  | profile | parser | sem | hexer |
  |---|---|---|---|
  | `aowl`   | aowlparser | aowlsem | aowlhexer | *(all ours)* |
  | `nimony` | nifler | nimsem | hexer | *(all nimony)* |
  | `hybrid` | aowlparser | nimsem | aowlhexer | *(the driver default)* |

- **Versions** — each component is a git checkout. `aowlup status` asks GitHub
  whether any is behind its branch (doubles as a **nimony version manager** —
  nifler/nimsem/hexer all track your nimony checkout). `aowlup update` pulls;
  `aowlup rebuild` / `aowlup setup` build from source.

## Commands

```
aowlup setup [--yes]        clone + build the whole toolchain (fresh machine)
aowlup doctor               resolved toolchain for the active profile
aowlup profile [use NAME]   show / switch the whole-stack profile
aowlup use SLOT VARIANT     override one slot (e.g. use sem nimsem)
aowlup unset SLOT           drop a slot override
aowlup status [--json]      git rev + GitHub update check per component
aowlup update [NAME] --yes  pull updates (check-only without --yes)
aowlup rebuild NAME --yes   rebuild a component from source
aowlup vscode [DIR] --yes   wire the editor / LSP to the active profile
aowlup config [--lsp]       emit editor initializationOptions from the registry
aowlup backend link S REPO  register a working repo for slot S
aowlup which SLOT           print the resolved exe (raw)
aowlup shim                 write ~/.aowl/bin shims that follow the profile
aowlup install [NAME]       fetch a released binary component (verified)
aowlup uninstall NAME       remove an installed release component
aowlup rollback [NAME]      point a slot back at the previous installed tag
```

**One-shot profile** (rustup `+toolchain` syntax): `aowlup +nimony doctor`,
`aowlmony +nimony run foo.nim`. Ephemeral — it does not change your stored
selection.

## Building from source

```
./build.sh                 # → bin/aowlup-ng   (needs nimony + aowlkit)
./release.sh               # → dist/aowlup-<os>-<arch> + .sha256
ln -sf "$PWD/bin/aowlup-ng" ~/.local/bin/aowlup
```

`~/.aowl` is the data home (the registry + resolved-component manifests);
`AOWL_HOME` overrides it. No component path is ever named on the command line.

## Layout

- `src/aowlup.nim` + `src/aowlup/` — the manager, in the language it manages
- `bin/aowlup` — the JavaScript build, kept as the differential oracle
- `~/.aowl/` — data home: `registry.json`, `backends/<slot>/backend.json`
