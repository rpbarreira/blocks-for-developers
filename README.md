# Blocks for Developers

A macOS desktop app that runs in the background, indexes your watched local git
repositories (commit history + working-tree file changes) into a searchable
"developer memory," and exposes that memory to a **locally-run LLM** via an MCP server.

Chat with the model to recall past work and generate summaries, and keep a library of
code snippets. **Nothing leaves your machine** — capture, retrieval, the MCP server, and
the LLM all run locally.

> Status: all v1 functionality is implemented and the app is packaged into a
> self-contained macOS `.app`. This repo is meant to be a solid starting point if you
> want to fork and extend it. The detailed engineering log lives in
> [`docs/PROGRESS.md`](docs/PROGRESS.md) — read it first when picking up the code.

## Features

- **Memory capture** — git commits (indexed incrementally) plus working-tree
  file-change snapshots (debounced, content-hash-deduped). Scope is git-tracked content
  only; no terminal/window/clipboard capture.
- **Retrieval** — local embeddings + vector search plus SQLite FTS5 keyword search,
  exposed through an MCP server as `search_memory` / `get_activity` / `get_commits`.
- **Chat** — a local llama.cpp runtime with an OpenAI-compatible API on loopback. Chat
  uses retrieval-augmented generation: the app queries `search_memory` first and injects
  the hits as context (not native tool-calling, which small models do unreliably).
- **Single-click summaries** — Day Recap, What's Top of Mind, and Standup Update, each a
  canned turn that pulls recent activity via `get_activity` and asks the model to write it.
- **Materials** — saved code snippets with a language tag, annotation, and text-expander
  note; searchable, sortable, filterable, copy-to-clipboard, and save-from-chat linking.
- **Always-on** — a menu-bar tray app; capture, the MCP server, and the UI live in one
  process.
- **Local-first & private** — your code memory and models stay in one folder on your Mac.

## How it works

```
                    ┌─────────────────────────────────────────────┐
                    │  Blocks app (Native SDK + Zig, one process)  │
                    │                                              │
   watched repos ──▶│  capture  ──▶  SQLite (app.db)  ◀── retrieval│
   (git + files)    │  (git log,      events/snapshots/            │
                    │   file scan)    embeddings/FTS5               │
                    │                      ▲                        │
                    │   chat UI ──────┐    │ reads (read-only)      │
                    └───────────────┼─┼────┼────────────────────────┘
                                    │ │    │
                       HTTP (loopback) │    │ spawns
                                    ▼ │    ▼
                   ┌────────────────────┐  ┌──────────────────────┐
                   │ llama-server       │  │ blocks-mcp (sidecar) │
                   │ (OpenAI-compatible)│  │ MCP over JSON-RPC/HTTP│
                   └────────────────────┘  └──────────────────────┘
```

The app spawns two child processes at runtime and reaches them over loopback HTTP:
- **`blocks-mcp`** — a standalone MCP server that opens `app.db` read-only and serves the
  three memory tools. Built separately (`mcp/`), links only the system `libsqlite3`.
- **`llama-server`** — the llama.cpp chat runtime, serving an OpenAI-compatible API.

All data lives in one folder: `~/Library/Application Support/dev.blocks.app/`
(`app.db`, `config.json`, `models/`). Settings shows this path so you can back it up.

## Tech stack

- **UI framework:** [Native SDK](https://native-sdk.dev) (native-rendered — GPU surface /
  Metal — no WebView, no npm, no build files for the app). The `native` CLI owns the build.
- **Language:** Zig (0.16.0). **Zero TypeScript.**
- **View layer:** declarative `.native` markup (`src/app.native`) bound to a
  Model / Msg / `update` core in `src/main.zig` (Elm-style architecture; the pure core
  requests side effects through an effects handle and receives results as messages).
- **Storage:** SQLite via the SDK's relational store (STRICT tables) with FTS5 for
  keyword search; schema is migration-driven (`src/schema/NNNN_*.sql`).
- **MCP sidecar:** a standalone Zig binary (`src/mcp_server.zig`, built by `mcp/build.zig`
  outside the SDK build graph) linking the system `libsqlite3`.
- **LLM runtime:** llama.cpp `llama-server`, spawned as a subprocess.
- **Embeddings:** a deterministic in-process hashing embedder (`hash-v1`, dim 256), so the
  index never needs re-embedding. A neural embedder can be added later under a new model
  id (the schema allows both to coexist).

macOS-only, Apple Silicon focus.

## Getting started

### Prerequisites

- **macOS on Apple Silicon** (the app is arm64; llama.cpp uses Metal).
- **[Native SDK CLI](https://native-sdk.dev)** — `npm install -g @native-sdk/cli`
  (developed against 0.10.1). The `native` command drives everything.
- **Zig** — auto-installed by the CLI on first build (at `~/.native/toolchains`), so you
  don't install it yourself. `native test`/`build` will prompt once; pass `--yes` to
  auto-approve.
- **llama.cpp** — `brew install llama.cpp`, which provides `llama-server`. Needed for the
  chat runtime during development. (The packaged `.app` vendors it, so end users don't
  need Homebrew.)

### Run it (development)

The app spawns `llama-server`, so point it at your Homebrew binary via an env var:

```sh
BLOCKS_LLAMA_SERVER=/opt/homebrew/bin/llama-server native dev --yes
```

`native dev` builds a Debug binary and opens the app with hot reload for
`src/app.native` — edit the markup and the window updates in ~2s without losing model
state. (The Zig core is not hot-reloaded; changing it needs a rebuild.)

Env vars the app respects:

| Variable | Purpose | Default |
| --- | --- | --- |
| `BLOCKS_LLAMA_SERVER` | absolute path to `llama-server` | `vendor/llama/bin/llama-server` |
| `BLOCKS_MCP_SERVER` | absolute path to the `blocks-mcp` sidecar | `mcp/zig-out/bin/blocks-mcp` |

Under `native dev` the working directory is the repo root, so the relative defaults
resolve. A packaged `.app` sets both env vars from a launcher script (see Packaging).

### Core commands (run from the repo root)

```sh
native check          # validate src/*.native markup + app.json (run after UI/Model changes)
native test --yes     # build + run the Zig test suite (also refreshes the model contract)
native build --yes    # ReleaseFast binary into zig-out/bin/blocks
native dev --yes      # build + run with markup hot reload
native db status      # inspect the relational schema / dev database
native db new-migration <name>   # scaffold src/schema/NNNN_<name>.sql
```

Build the MCP sidecar separately (it lives outside the SDK build graph):

```sh
cd mcp && zig build      # -> mcp/zig-out/bin/blocks-mcp
```

### Automation harness (headless GUI verification)

The app ships an automation server so you can drive and assert the GUI headlessly —
handy for verifying flows end-to-end. Start the app with the flag, then drive it from
another shell:

```sh
# terminal 1
BLOCKS_LLAMA_SERVER=/opt/homebrew/bin/llama-server native dev --yes -Dautomation=true

# terminal 2 (from the repo root)
native automate wait
native automate snapshot                         # widget tree with #ids, roles, names, actions
native automate widget-action main-canvas <id> set_text "hello"
native automate widget-click main-canvas <id>
native automate assert [--absent] [--timeout-ms N] "<regex>"
```

The GPU view label is `main-canvas`. Widget ids are large numbers that change per
rebuild — snapshot to get the current ones. Note: buttons inside a `<scroll>` may not
receive synthesized clicks (a harness limitation) — prove that logic with unit tests.

### Packaging a distributable `.app`

```sh
packaging/package-macos.sh
```

This builds the app + the MCP sidecar, vendors a relocatable `llama-server` (with its
dylib closure) into the bundle, assembles an ad-hoc-signed `Blocks for Developers.app`,
and zips it. See [`packaging/README.md`](packaging/README.md) for details (signing,
notarization, and the `--skip-llama` option).

## Project layout

```
src/
  main.zig        the app: Model/Msg/update, boot, effect firing, the Zig-built
                  secondary windows (Settings, material editor, delete-confirm)
  app.native      the main-window declarative view (markup binds ONE canvas)
  config.zig      data-dir/path resolution, username detection (pure)
  git.zig         git-history capture builders + parsers (pure)
  snapshots.zig   working-tree file-change capture (pure)
  embeddings.zig / embed_core.zig   hashing embedder + vector/FTS search
  chat.zig        chat data layer + LLM protocol shaping (pure)
  models.zig      local-model catalog + llama runtime argv/paths (pure)
  repos.zig       watched-repos data layer (pure)
  snippets.zig    materials data layer (pure)
  tray.zig        menu-bar menu definition (pure)
  mcp/            pure MCP protocol + tools (JSON-RPC, SQL, shapers)
  mcp_server.zig  the standalone sidecar binary (no Native SDK dependency)
  schema/         SQL migrations (NNNN_*.sql) + migrations.lock.json
  tests.zig       test root (imports every module + update-arm/markup tests)
mcp/              separate build graph for the sidecar (build.zig)
packaging/        package-macos.sh, vendor-llama.sh, README.md
docs/PROGRESS.md  the authoritative engineering log — read first
```

Almost all logic lives in **pure, unit-tested modules**; only effect firing lives in
`main.zig`. That is the pattern to follow when extending: add pure builders/parsers in a
module with tests, then wire the effects in `main.zig`.

## Contributing / extending

- Read [`docs/PROGRESS.md`](docs/PROGRESS.md) for the per-feature "what was built" notes,
  the database schema, and hard-won Native SDK + Zig learnings.
- After any change to markup or the Model/Msg, run `native test --yes` (refreshes the
  model contract) then `native check`.
- Keep new logic pure and tested; wire effects in `main.zig` with a fresh, documented
  effect-key block.

## Roadmap

- **v2 — truly cross-platform.** Native builds and installers for Windows and Linux (the
  Native SDK targets both), so Blocks isn't macOS-only. This means per-platform packaging
  of the app and its sidecars (the MCP server and the llama.cpp runtime) and platform
  equivalents for the macOS-specific bits.
- **Text-expander notes with real expansion.** Each material already carries a
  "text expander" note; the plan is to wire that into [espanso](https://espanso.org) (and
  similar tools) so a snippet's trigger actually expands system-wide, turning saved
  materials into live text-expansion shortcuts.

## License

See [LICENSE](LICENSE) for details.
