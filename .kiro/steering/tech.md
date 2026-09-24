# Tech Stack & Commands — Blocks for Developers

## Stack

- **UI framework:** Native SDK (native-sdk.dev, vercel-labs/native) — native-rendered
  (GPU surface, Metal), NO WebView / npm / build files for the app itself. The `native`
  CLI owns the build.
- **Language:** Zig (0.16.0). Zero TypeScript.
- **View layer:** declarative `.native` markup (`src/app.native`), bound to a
  Model/Msg/`update` core in `src/main.zig` (Elm-style architecture).
- **Storage:** SQLite via the SDK's relational store (STRICT tables where possible),
  with FTS5 for keyword search. Schema is migration-driven (`src/schema/NNNN_*.sql`).
- **MCP sidecar:** a standalone Zig binary (`src/mcp_server.zig`) built OUTSIDE the SDK
  build graph (`mcp/build.zig`), linking the system `libsqlite3` — NO `native_sdk` dep.
- **LLM runtime:** llama.cpp `llama-server`, spawned as a subprocess, OpenAI-compatible
  API over loopback HTTP.
- **Embeddings:** deterministic in-process hashing embedder (`hash-v1`, dim 256).

## Toolchain

- `@native-sdk/cli` (`native`) installed globally via npm (was 0.10.1).
- Zig 0.16.0 auto-installed by the CLI at `~/.native/toolchains/zig-0.16.0/zig`.
- **SDK source is an invaluable reference** — it lives inside the CLI npm package at
  `<npm-global>/@native-sdk/cli/src`. Key files:
  - `src/root.zig` — the public API surface.
  - `src/runtime/effects.zig` (~17k lines) — the effects channel (spawn/fetch/file/db/
    timer/host/window). Grep here to learn what effects exist.
  - `src/primitives/canvas/` — widgets/markup, icons, svg_icon.
  - `src/tooling/package.zig` — how `native package` assembles bundles.
  - `schemas/app.schema.json` / `app.json` — the manifest contract.

## Commands (run from repo root)

- `native check` — validate `src/*.native` markup + `app.json` (and the model contract
  after a test run). Run this after markup or Model/Msg changes.
- `native test --yes` — build + run Zig tests. `--yes` auto-approves the one-time Zig
  toolchain download. Also refreshes the model contract that `native check` reads.
- `native build --yes` — ReleaseFast binary into `zig-out/bin/blocks`.
- `native dev --yes` — run the app (opens a GPU window).
- `native dev --yes -Dautomation=true` — run WITH the automation server for headless
  GUI verification (see below).
- `native db new-migration <name>` / `native db status` / `native db reset --yes`.
- **MCP sidecar build** (separate graph): `zig build` from `mcp/` →
  `mcp/zig-out/bin/blocks-mcp`.
- **Packaging:** `packaging/package-macos.sh` (see `packaging/README.md`).

## Live runs — llama-server

`native dev` must be launched with the runtime path in the env so the app can spawn it:

```sh
BLOCKS_LLAMA_SERVER=/opt/homebrew/bin/llama-server native dev --yes -Dautomation=true
```

Install the runtime with `brew install llama.cpp`. The packaged build vendors it, so end
users don't need Homebrew. Env overrides the app respects:
- `BLOCKS_LLAMA_SERVER` — absolute path to `llama-server` (else `vendor/llama/bin/llama-server`).
- `BLOCKS_MCP_SERVER` — absolute path to `blocks-mcp` (else `mcp/zig-out/bin/blocks-mcp`).

## Automation (headless GUI verification)

Run with `-Dautomation=true`, then from another shell (repo root):
- `native automate wait`
- `native automate snapshot` — the widget tree with `#id`s, roles, names, actions.
  Widget ids are large numbers and CHANGE per rebuild — snapshot to get current ids.
- `native automate widget-action main-canvas <id> set_text "<text>"` — fill a textbox.
- `native automate widget-click main-canvas <id>` — click a button/row.
- `native automate assert [--absent] [--timeout-ms N] "<regex>"` — assert snapshot text.
The GPU view label is `main-canvas`. Buttons inside a `<scroll>` may not receive
synthesized clicks (harness limit) — prove that logic with update-arm tests instead.

## Terminal quirk (this environment)

The shell often echoes commands garbled and shows exit code -1 as a DISPLAY artifact.
Commands actually run fine — check the real logged output, not the exit-code line.

## Verification expectations

Every task is: PURE logic unit-tested + wired into `main.zig` + `native check` clean +
verified END-TO-END live via automation. When you change code, run `native test --yes`
and `native check` before claiming done.
