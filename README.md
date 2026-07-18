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
```

**One-shot profile** (rustup `+toolchain` syntax): `aowlup +nimony doctor`,
`aowlmony +nimony run foo.nim`. Ephemeral — it does not change your stored
selection.

## Install

`aowlup` is a dependency-free Node script. Symlink it onto your `PATH`:

```
ln -sf "$PWD/bin/aowlup" ~/.local/bin/aowlup
aowlup setup          # see the plan;  add --yes to clone + build
```

`~/.aowl` is the data home (the registry + resolved-component manifests);
`AOWL_HOME` overrides it. No component path is ever named on the command line.

## Layout

- `bin/aowlup` — the manager (the whole tool; no runtime dependencies)
- `~/.aowl/` — data home: `registry.json`, `backends/<slot>/backend.json`
