# Structure & Architecture — Blocks for Developers

## Architecture pattern

Elm-style: a pure `update(model, msg, fx)` core drives everything. Side effects are
requested through an effects handle (`fx`) — spawn, fetch, file I/O, db, timers, host
requests, window control — and their results come back as `Msg`s. The view is
declarative `.native` markup bound to Model accessors. Keep ALL logic PURE and
unit-testable in dedicated modules; only effect firing lives in `main.zig`.

## Top-level layout

- `src/` — all app source (see below).
- `mcp/` — the standalone MCP sidecar build (`build.zig`, `build.zig.zon`); output
  `mcp/zig-out/bin/blocks-mcp`. Built with plain `zig build`, OUTSIDE the SDK graph.
- `packaging/` — `package-macos.sh`, `vendor-llama.sh`, `README.md`. Produces
  `dist/Blocks for Developers.app` + `.zip`. `vendor/` and `dist/` are gitignored.
- `docs/PROGRESS.md` — the detailed resumption log (read first, but see the note below
  about it lagging the current code in places).
- `docs/SPIKE_REPORT.md` — the Task 0 decision-gate write-up.
- `app.json` — the manifest (id `dev.blocks.app`, window shell, capabilities).

## Source modules (`src/`)

- **main.zig** — the app: Model/Msg/`update`/`initFx`, window/manifest wiring, boot
  sequence, and the full shell (onboarding + chat + materials + settings). Registers
  `app_icons`, creates the `UiApp`, runs the runner. Holds ALL effect firing + the
  per-feature state machines, AND the Zig builders for the secondary windows.
- **app.native** — the MAIN-window declarative view. `<if needsOnboarding>` overlay +
  the main app (header nav, Chat screen, Materials screen). The `<if>`-gated panels here
  are the onboarding overlay and the Materials sort / language-FILTER dropdown menus.
  Three surfaces are NOT here — they are SEPARATE OS windows built in Zig (a UiApp binds
  markup to exactly ONE canvas, so a second window's tree must be Zig-built via `Ui.*`):
  - **Settings** (`settings_open`) — built by `blocksWindowView`.
  - **Material add/edit editor** (`editor_open`) — built by `editorWindowView`. (Formerly
    an inline `<if editorOpen>` sheet; moved to its own window. The old set-language modal
    was REMOVED — a snippet's language is now edited inside this editor window.)
  - **Delete-confirmation dialog** (`confirm_delete_open`) — built by
    `confirmDeleteWindowView`.
  All three are declared by `windows_fn` (`blocksWindows`) and routed by window label
  inside `window_view` (`blocksWindowView`). Each open hands the window a FRESH canvas
  label (`<base>-canvas-<n>`) to dodge the reopen-blank-canvas reconcile bug.
- **config.zig** — PURE. `Paths.resolve` (data_dir/db/models/config via
  `native_sdk.app_dirs`), username/home detection, path joins, env lookup.
- **env.zig** — read env via `std.c.environ` (the app links libc; Zig 0.16 std env API
  is unstable). Returns borrowed slices.
- **bootstrap.zig** — PURE. `config.json` builders; there is no mkdir effect, so writing
  `config.json` + `models/.keep` materializes the data dir (writeFile auto-creates dirs).
- **db.zig** — typed SQLite helpers: `Value`/`Statement`/`Migration`, param ctors, the
  `migrations` array (embedded for tests), and `PageReader` to decode the query `.page`
  wire format. Page bytes are valid ONLY during the update that received them — copy.
- **git.zig** — PURE git-history capture builders/parsers (log argv, `parseLog`, ISO→ms,
  insert/bookkeeping statement builders).
- **snapshots.zig** — PURE working-tree capture (status/diff argv, porcelain-z parser,
  `sha256Hex`, insert + last-hash statement builders).
- **tray.zig** — PURE menu-bar menu definition + command name consts.
- **embeddings.zig** — embeddings + vector/FTS search, PURE. Re-exports `embed_core.zig`.
- **embed_core.zig** — SDK-FREE embedding core (std-only) shared by the app AND the MCP
  sidecar so the index is never re-embedded across the process boundary.
- **mcp/protocol.zig** — PURE JSON-RPC + a hand-rolled `JsonWriter` + payload builders.
- **mcp/tools.zig** — PURE tool arg parsing + SQL + row→JSON shapers.
- **mcp/mcp_tools.zig** — test-only integration harness (drives the tools against a real
  in-memory SQLite via the effects channel).
- **mcp_server.zig** — the standalone sidecar binary: libsqlite3 bindings, HTTP accept
  loop, JSON-RPC dispatcher. NO `native_sdk`.
- **models.zig** — PURE local-model mgmt + llama.cpp runtime (catalog, path/argv builders,
  `parseProgress`, `resolveServerBinary`, `parseSelectedModel`/`parseOnboarded`, tier/RAM
  display helpers).
- **chat.zig** — PURE chat data layer + LLM protocol shaping (chats/messages SQL, request
  builder, SSE stream parser, MCP search/activity request+response shaping, SummaryKind).
- **repos.zig** — PURE watched-repos data layer.
- **snippets.zig** — PURE materials data layer (lightweight list CARD vs full DETAIL).
- **tests.zig** — test root: imports every module + markup-build + update-arm tests.
- **schema/NNNN_*.sql** + **migrations.lock.json** — migrations (see below).
- **assets/icons/sparkle.svg** — custom `app:sparkle` icon (must live UNDER `src/`).

## Database schema (user_version 2, all timestamps Unix-ms INTEGER)

- `repos(id, path UNIQUE, name, active, last_indexed_oid, added_at, last_indexed_at)`
- `events(id, repo_id FK, kind['commit'|'branch'|'checkout'], occurred_at, commit_oid,
  author_*, subject, body, ref_name, diff, files_changed, insertions, deletions,
  created_at)` + a UNIQUE partial index on (repo_id, commit_oid).
- `file_snapshots(id, repo_id FK, rel_path, content, diff, content_hash, byte_len,
  captured_at)`
- `chats(id, title, preview, kind['chat'|'day_recap'|'top_of_mind'|'standup'],
  created_at, updated_at)`
- `messages(id, chat_id FK, role, content, seq, created_at)`
- `snippets(id, title, content, language, annotation, text_expander, origin_chat_id FK
  SET NULL, origin_message_id FK SET NULL, created_at, updated_at)`
- `embeddings(id, source_kind, source_id, model, dim, vector BLOB[raw LE f32],
  created_at)` + UNIQUE(source_kind, source_id, model)
- `memory_fts` = fts5(ref_kind UNINDEXED, ref_id UNINDEXED, body)

Migrations are SDK-native: `native db new-migration <name>` appends `src/schema/NNNN_*.sql`;
the runner auto-applies pending ones on launch inside one transaction and sets
`user_version`. Each new `.sql` MUST also be added to the `migrations` array in `db.zig`
(embedded for tests); `native test` regenerates `migrations.lock.json`.

## Effect-key convention

Spawn/fetch/file share ONE key namespace; timer keys are separate. Keys are grouped by
feature (100s bootstrap, 110s repos, 120s git, 130s snapshots, 140s login, 150s embed,
160s MCP, 170s models/llama, 180s chat, 190s materials, 200 config-persist). When adding
a feature, pick a fresh block and document it near the key consts in `main.zig`.

## Where to start when resuming

`docs/PROGRESS.md` is the MAIN SOURCE OF TRUTH — read it first. It has a per-task "what
was built" section, source-layout notes, the schema, a "Critical SDK/Zig learnings"
section, the "Packaging" section, and a "Post-v1 changes" log. As a general habit, when a
doc and the code ever disagree, trust the code (check `app.native` + the
`windows_fn`/`window_view` builders in `main.zig`) — but PROGRESS.md is kept current, so
that should be rare. The global Native SDK + Zig steering files
(`~/.kiro/steering/native-sdk-*.md`) hold the reusable, project-agnostic version of those
learnings.

## Keeping the docs accurate (maintenance rule)

`docs/PROGRESS.md` is the project's authoritative resumption log and is read first. EVERY
codebase change must be documented there in the SAME change — update the relevant Task
section (or add a "Post-v1 changes" entry), and if a change supersedes an earlier
description, edit that section or add an inline `> SUPERSEDED:` note rather than leaving it
wrong. If a change alters the architecture/structure/stack/schema described in THESE
steering files, update them too. A stale source of truth is worse than none.
