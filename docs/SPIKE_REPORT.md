# Task 0 — Spike Report: Native SDK for the Blocks backend

**Date:** 2026-09-05
**Machine:** Apple Silicon (arm64), macOS 26.6.2, 18 GB RAM
**Toolchain:** `@native-sdk/cli` 0.10.1, Zig 0.16.0 (auto-installed by `native` into `~/.native/toolchains`)
**Verdict:** ✅ **PASS — commit to Native SDK (markup + Zig, zero TypeScript).** No pivot to Tauri needed.

---

## What was validated

The spike scaffolded a `zig-core` Native SDK app (`native init --template zig-core`, zero
TypeScript) and probed every risky backend capability. Probes (a) and (b) run under `native test`
(real SQLite engine, real markup build). Probes (c)–(f) run under a live `native dev` app whose
`init_fx` fires the real effects on boot and writes outcomes to `/tmp/blocks_spike_results.txt`.

| Probe | Capability | How validated | Result |
|-------|-----------|---------------|--------|
| (a) | `code` component: syntax highlight + line numbers + diff wash | `native test` asserts the built view contains monospace spans with syntax colors | ✅ PASS |
| (b) | Real SQLite round-trip + FTS5 | `native test` binds a real `relational_store.Database`, runs CREATE/INSERT/SELECT and an FTS5 virtual table + MATCH | ✅ PASS — **FTS5 is available** |
| (c) | Subprocess spawn (`git log`) | Live app `fx.spawn(... git -C <repo> log ...)` collect-mode; captured real output | ✅ PASS |
| (d) | Arbitrary-path file read | Live app `fx.readFile(<repo>/nginx.conf)`; read 24 real bytes | ✅ PASS |
| (e) | Streaming subprocess (llama.cpp token pattern) | Live app `fx.spawn(... sh -c 'echo token-$i; sleep')` in `.lines` mode; received all 5 lines incrementally via `on_line` | ✅ PASS |
| (f) | HTTP fetch to a localhost server | Live app `fx.fetch(http://127.0.0.1:39881/)`; got HTTP 200 | ✅ PASS |

Final `/tmp/blocks_spike_results.txt`:

```
(c) git spawn      : ok=true first_line="450c127 Add neovim setup"
(d) readFile       : ok=true bytes=24
(e) stream spawn   : ok=true lines=5
(f) fetch listener : ok=true status=200
```

---

## Key findings that shape the build

1. **Zig-only authoring is fully first-class.** The scaffold, `native check`, `native test`, and
   `native dev` all work with `.native` markup + `src/main.zig` and no TypeScript.

2. **The effects channel already covers the "risky" OS work** — these are NOT in the public
   *Capabilities* doc but ARE first-class `Effects` methods, verified in the SDK source
   (`src/runtime/effects.zig`) and by live execution:
   - `spawn` (argv, stdin, `.lines` streaming via `on_line`, `.collect` whole-output via `on_exit`,
     `cancel`, plus a full PTY family). The SDK source even cites streaming agent CLIs
     (`claude -p --output-format stream-json`) as the intended use — the exact llama.cpp pattern.
   - `readFile` / `writeFile` / `appendFile` / `statFile` / `deleteFile` (+ streaming variants).
   - `fetch` (buffered and `.stream`).
   - `dbExec` / `dbQuery` / `dbSubscribe` over a real bundled SQLite.

3. **SQLite is real but capability-gated.** The engine links `third_party/sqlite/sqlite3.c` only
   when the manifest declares `"sqlite"` in `capabilities`. Compiled flags include
   `-DSQLITE_ENABLE_FTS5` and `-DSQLITE_ENABLE_JSON1`, so **FTS5 full-text search is available** —
   we get FTS5 + vector search (hybrid) with no external dependency.

4. **Arbitrary file access is sandboxed by default.** `src/runtime/file_access.zig`: without a
   `"filesystem"` grant, raw file effects are confined to six app-owned dirs. Blocks reads
   watched-repo files anywhere on disk, so **the app must declare the `filesystem` capability +
   permission.** (Declared in the spike's `app.json` and validated.)

5. **No in-process socket `listen`/`bind` effect.** The SDK has no generic TCP/HTTP *server*
   effect (only `fetch` as a client). **Decision for Task 8: host the MCP server as a spawned
   child process** (proven `spawn`) that binds the custom port; the app's LLM reaches it over HTTP
   via `fetch` (proven). Both halves are validated.

6. **Tray, dialogs, real SQLite store are all public API** (`native_sdk.TrayOptions`/`TrayShell`,
   `OpenDialogOptions`, `runtime.RelationalStore`) — covering the always-on tray (Task 6), the
   watched-folder picker (Task 3), and the memory store (Task 2).

7. **Interactive toolchain prompt:** `native test`/`dev` prompt to download Zig on first run; pass
   `--yes` for non-interactive/CI use.

---

## Manifest requirements captured for the real app

`app.json` must declare (validated in the spike):
- `capabilities`: `native_views`, `gpu_surfaces`, `sqlite`, `filesystem`, `network`, `tray`, `dialog`
  (add `notifications`, `store`, `persist` as features land)
- `permissions`: `view`, `command`, `filesystem`, `network`

## API specifics captured (for the real implementation)

- Spawn results: `EffectExit { code, reason (.exited/.signaled/.cancelled/.rejected/.spawn_failed), output, stderr_tail }`; lines: `EffectLine { line, truncated }`.
- Fetch result: `EffectResponse { outcome (.ok/.rejected/...), status, body }` — success is `outcome == .ok`.
- DB result: `EffectDbResult { kind (.page/.done/.exec), outcome (.ok/...), bytes }`; a `.page`'s first u32 is the row count.
- Read-only `<code>` renders as a highlighted paragraph (`.text` spans with syntax colors); an
  `editable` `<code>` renders as a `.textarea`. Both keep syntax highlighting.
- Boot effects go in `init_fx(model, fx)` (runs once before first paint); per-message effects in `update_fx`.

---

## Decision gate → PROCEED

All of (a)–(f) are viable on documented/first-class SDK APIs. Proceeding to Task 1 on
**Native SDK (markup + Zig), macOS-only for v1.** The one design consequence to carry forward:
**the MCP server runs as a spawned child process** rather than an in-process listener.
