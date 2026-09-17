# Blocks for Developers — Progress & Resumption Notes

Last updated: end of Task 8 (MCP server child; not yet committed).
Committed so far: Task 4 (`01969e5`), Task 5 (`56ae2a2`), Task 6 (`c2afa1b`),
Task 7 (`e27eb0a`). Read this first when resuming. To continue: open the IDE on
this repo folder
(`/Users/rpbarreira/Projects/GitHub/rpbarreira/blocks-for-developers`) and say
"read docs/PROGRESS.md and continue from Task 9."

---

## What this project is

A macOS desktop app ("Blocks for Developers") that runs in the background,
indexes the user's watched local git repositories (commit history + working-tree
file changes) into a searchable "developer memory," and exposes that memory to a
locally-run LLM via an MCP server. The user chats with the model to recall past
work and generate summaries (Day Recap, What's Top of Mind, Standup Update), and
manages code snippets ("materials"). UI modeled on 5 provided mockups (welcome,
model picker, chat, materials, settings modal) plus 2 additions (a Watched
Repositories settings section and a repo-watching welcome step).

## Locked decisions

- **Stack:** Native SDK (https://native-sdk.dev, vercel-labs/native) with `.native`
  markup views + **Zig** core, **zero TypeScript**. macOS-only for v1.
- **Memory scope:** git (commits, diffs, branch/checkout) + working-tree file
  changes (debounced, coalesced save snapshots, full content + diffs). No
  terminal/window/clipboard capture.
- **Repo watching:** manual add (Watched Repositories settings section).
- **LLM access:** MCP-first. The MCP server runs as a SPAWNED CHILD PROCESS
  (there is no in-process socket listener effect; the SDK only has a `fetch`
  client). The app's LLM reaches it over HTTP. v1 consumer is the app's own LLM.
- **Retrieval:** local embeddings + vector search, plus structured query tools
  (search_memory, get_activity, get_commits). FTS5 is available for hybrid search.
- **LLM runtime:** bundled llama.cpp, subprocess first (embed via Zig FFI later).
- **Embeddings:** ONE fixed dedicated small embedding model for all users
  (independent of the chat tier), so the index never needs re-embedding.
- **Process model:** single tray app, auto-start on login, always running
  (capture + MCP + UI in one process).
- **DATA LOCATION (user decision):** EVERYTHING in ONE folder, the macOS app-data
  dir `~/Library/Application Support/dev.blocks.app/` — `app.db` (engine-owned,
  runner opens it), `config.json`, and `models/`. NO `~/blocks`. The Settings
  modal must show this path under the app version for backup.
- **Frontend note:** user dislikes JS; Native SDK Zig-only path confirmed viable
  by the spike. If Native SDK ever proved unworkable the fallback was Tauri+Rust,
  but the spike PASSED so we're committed to Native SDK.

## Environment / toolchain

- Apple Silicon arm64, macOS 26.6.2, 18 GB RAM.
- `@native-sdk/cli` 0.10.1 installed globally via npm. Zig 0.16.0 auto-installed
  at `~/.native/toolchains` (the CLI downloads it on first build).
- **SDK source (invaluable reference)** lives inside the CLI npm package at
  `~/.nvm/versions/node/v26.8.1/lib/node_modules/@native-sdk/cli/src`.
  `src/root.zig` is the public API surface; `src/runtime/effects.zig` (~17k lines)
  is the effects channel; `src/primitives/canvas/` has widgets/markup; the
  `schemas/app.schema.json` documents `app.json`.
- **Key commands** (run from the repo root):
  - `native check` — validate markup + app.json (+ model contract after a test).
  - `native test --yes` — build + run Zig tests (the `--yes` auto-approves the
    one-time Zig toolchain download).
  - `native dev --yes` — run the app (opens a GPU window).
  - `native dev --yes -Dautomation=true` — run WITH the automation server so you
    can drive/verify the GUI headlessly (see "Automation" below).
  - `native db new-migration <name>` / `native db status` / `native db reset --yes`.
- **Terminal quirk:** this environment echoes commands garbled and often shows
  exit code -1 as a DISPLAY artifact. Commands actually run fine — always check
  the real logged output, not the exit code line.

## Automation (how to verify GUI flows headlessly)

Run the app with `-Dautomation=true`, then in another shell (from repo root):
- `native automate wait`
- `native automate snapshot` — prints the widget tree with `#id`s, roles, names,
  placeholders, and `actions=[...]`. Widget ids are large numbers and CHANGE per
  rebuild — snapshot to get current ids.
- `native automate widget-action main-canvas <id> set_text "<text>"` — fill a textbox.
- `native automate widget-click main-canvas <id>` — click a button/row.
- `native automate assert [--absent] [--timeout-ms N] "<regex>"` — assert snapshot text.
The GPU view label is `main-canvas`. This is how Task 3 was verified end-to-end.

---

## Task status

- [x] **Task 0 — Spike / decision gate.** PASSED. Validated (a) code component
  (syntax highlight/line-numbers/diff wash), (b) real SQLite + FTS5, (c) git
  subprocess spawn, (d) file read + write, (e) streaming subprocess (llama.cpp
  token pattern), (f) HTTP fetch to a localhost server. Full write-up in
  `docs/SPIKE_REPORT.md`. Throwaway spike app was deleted.
- [x] **Task 1 — Skeleton + data-dir bootstrap + username detection.**
- [x] **Task 2 — SQLite schema + migrations.** (commit 33413f5)
- [x] **Task 3 — Watched Repositories management.** (commit cef9fb1)
- [x] **Task 4 — Git history capture.** (commit `01969e5`). Module `src/git.zig`
  + capture wiring in `main.zig`. Format verified against real `git log` output.
- [x] **Task 5 — Working-tree file-change capture (debounced snapshots).**
  (commit `56ae2a2`). Module `src/snapshots.zig` + timer-driven scan wiring in
  `main.zig`. Verified end-to-end via the automation GUI (see the Task 5 section).
- [x] **Task 6 — Always-on tray + auto-start on login.** (commit `c2afa1b`).
  Module `src/tray.zig` + declarative tray wiring in `main.zig`. Verified E2E via
  automation. The "OPEN ARCHITECTURAL ITEM" is RESOLVED (see the resolved-item
  section) — no Runtime rewrite was needed.
- [x] **Task 7 — Embeddings generation + vector search.** (commit `e27eb0a`).
  New module `src/embeddings.zig` + a generation pass + search helpers wired into
  `main.zig`. VERIFIED END-TO-END via automation (7 events + 3 snapshots embedded,
  10 vectors + 10 FTS rows, dedup held, live search returned the right memory).
  v1 uses a DETERMINISTIC in-process hashing embedder — llama.cpp is deferred to
  Task 9 (see the Task 7 section). NOTE: in Task 8 the pure embedder was extracted
  into `src/embed_core.zig`; `embeddings.zig` now re-exports it.
- [x] **Task 8 — MCP server (spawned child) exposing memory tools.** DONE (not yet
  committed). New standalone binary `src/mcp_server.zig` (+ `mcp/build.zig`) and a
  pure core `src/mcp/` (protocol + tools) + `src/embed_core.zig`; spawn/health wired
  into `main.zig`. 100 tests pass; VERIFIED END-TO-END (app spawned the child, added
  this repo, and `get_commits`/`get_activity`/`search_memory` returned correct real
  data over HTTP). See the Task 8 section.
- [ ] **Task 9 — Local model management + llama.cpp runtime.** ← NEXT
- [ ] Task 10 — Chat experience wired to model + MCP.
- [ ] Task 11 — Single-click summaries.
- [ ] Task 12 — Materials (snippets) screen + chat cross-linking.
- [ ] Task 13 — Welcome flow + settings modal completion + polish.

---

## Source layout (all under `src/`)

- **main.zig** — the app: Model/Msg/`update`/`initFx`, window/manifest wiring,
  boot sequence, and (currently) the Watched Repositories screen. `main(init)`
  detects username, then `UiApp.create(...)` + `runner.runWithOptions(...)`.
- **config.zig** — PURE, unit-tested. `Paths.resolve(alloc, bundle_id, lookup)`
  -> `{data_dir, db, models, config}` via `native_sdk.app_dirs` (macOS `.data` =
  `<HOME>/Library/Application Support/<bundle_id>`). `detectUsername(lookup, home)`
  (precedence USER > LOGNAME > HOME-basename > "developer"), `detectHome`,
  `joinPath`, `envFromLookup`.
- **env.zig** — `get(name)`/`lookup(name)` read env via `std.c.environ` (app links
  libc; Zig 0.16 std.process env API is unstable). Returns borrowed slices.
- **bootstrap.zig** — `defaultConfigJson(alloc, username, version)` -> JSON
  `{version, username, onboarded:false}`; `modelsKeepPath`; `models_keep_contents`.
  No mkdir effect exists — `writeFile` auto-creates parent dirs, so the data dir is
  materialized by writing `config.json` + `models/.keep`.
- **db.zig** — typed SQLite helpers. `Value`/`Statement`/`Migration` aliases;
  `val.int/text/real/blob/null_value` param ctors; `migrations` array (embeds the
  `.sql` for TESTS; the running app uses the build-generated identical copy);
  **PageReader** decodes the query `.page` wire format
  (`init(bytes)` -> `rowCount()`/`columnCount()`/`next(out []ColumnValue)`;
  `ColumnValue.asInt/asText/asBlob/isNull`). Page bytes are valid ONLY during the
  update that received the EffectDbResult — copy anything kept.
- **git.zig** — git history capture, PURE builders + parsers (Task 4).
  `logArgv(argv, fmt_buf, range_buf, path, since_oid)` builds
  `git -C <path> log --reverse --numstat --format=<log_format> [<since>..HEAD]`.
  `log_format` frames each commit with control chars: RS `0x1e` starts a record,
  US `0x1f` between the six fields (`%H %an %ae %aI %s %b`), trailing US closes the
  body; `--numstat` lines (`add<TAB>del<TAB>path`, `-` for binary) follow until the
  next RS. `LogParser`/`parseLog(out, bytes)` -> `[]Commit`
  `{oid, author_name, author_email, author_date_iso, subject, body, files_changed,
  insertions, deletions}` (slices borrow the input — copy what's kept).
  `isoToUnixMs(iso, fallback)` converts `%aI` to Unix-ms (civil-days algorithm,
  handles `Z` and `+HH:MM`/`+HHMM`). `insertStatement(*[11]Value, repo_id, commit,
  occurred_ms, now_ms)` builds the `events` INSERT (kind='commit'), and
  `updateIndexedStatement(*[3]Value, repo_id, last_oid, now_ms)` +
  `select_last_indexed_sql` maintain `repos.last_indexed_oid/last_indexed_at`.
  All statement builders use the caller-owned param-buffer pattern (lifetime trap).
- **snapshots.zig** — working-tree file capture, PURE builders + parsers (Task 5).
  `statusArgv(argv, path)` -> `git -C <path> status --porcelain=v1 -z
  --untracked-files=all`; `diffArgv(argv, path, rel)` -> `git -C <path> diff --
  <rel>`. `StatusParser`/`parseStatus(out, bytes)` -> `[]Change{x, y, rel_path}`
  over the NUL-delimited porcelain -z stream: each entry is `XY<space>path\0`; a
  rename/copy (`R`/`C`) carries a SECOND NUL field (the original path) that the
  parser consumes/discards (we snapshot the CURRENT path); deletions and empty
  paths are skipped. `Change.isUntracked()/isDelete()/isRenameOrCopy()`.
  `sha256Hex(content, *[64]u8)` writes the lowercase hex digest (KAT-tested).
  `insertStatement(*[7]Value, repo_id, rel_path, content, diff, content_hash,
  now_ms)` inserts a `file_snapshots` row (byte_len = content.len); `select_last_
  hash_sql` + `lastHashParams(*[2]Value, repo_id, rel_path)` fetch the newest
  stored hash so unchanged saves are skipped. Caller-owned param buffers throughout.
- **tray.zig** — menu-bar (status item) menu definition, PURE (Task 6).
  Command-name consts `cmd_open`/`cmd_toggle_login`/`cmd_quit` (shared with
  main.zig's `on_command`). `buildMenu(buf []TrayMenuItem, login_enabled,
  login_supported) []const TrayMenuItem` lays out the rows (Open / — / Start at
  Login / — / Quit); `loginToggleLabel(enabled)` prefixes a ✓ when on. The tray
  ITSELF is declarative (see the Task 6 section) — this module only builds the
  menu and (via the shared consts) names the commands.
- **embeddings.zig** — embeddings + vector search, PURE (Task 7). `dim = 256`,
  `model_id = "hash-v1"`, `Vector = [256]f32`. `vectorBytes`/`vectorFromBytes`
  pack a vector to/from the raw LE-f32 `embeddings.vector` BLOB; `normalize`/`dot`/
  `cosine`. `Tokenizer` splits text/code into lowercased sub-words (non-alnum +
  camelCase + underscores); `embed(text, *Vector)` is the deterministic HASHING
  embedder (Wyhash → bucket + sign bit, L2-normalized), `embedValue` returns by
  value. `SourceKind{event,file_snapshot,message,snippet}` + `name()`/`kindFromName`.
  Text builders `eventText(buf, subject, body)` / `fileSnapshotText(buf, rel_path,
  content)`. Statement builders (caller-owned bufs): `insertStatement`
  (embeddings row: kind, id, model, dim, vector blob, now) + `ftsInsertStatement`
  (memory_fts row). Queries: `select_unembedded_events_sql` /
  `select_unembedded_snapshots_sql` (rows lacking a `hash-v1` embedding, oldest
  first, `?1`=model `?2`=limit), `select_vectors_sql` (`?1`=model → kind,id,vector),
  `fts_search_sql` (memory_fts MATCH `?1` ORDER BY rank LIMIT `?2`). Ranking:
  `Hit{kind,source_id,score}`, `considerTopK` (alloc-free top-k), and `rankPage`
  (decode + score a `select_vectors_sql` page against a query vector).
- **embed_core.zig** — SDK-FREE embedding core (Task 8), std-only. The vector math
  (`vectorBytes`/`vectorFromBytes`/`normalize`/`dot`/`cosine`), the `hash-v1` hashing
  `embed`/`embedValue`, the `Tokenizer`, `SourceKind`/`kindFromName`, the text
  builders (`eventText`/`fileSnapshotText`), the top-k `Hit`/`considerTopK`, and
  `model_id`/`dim`/`select_vectors_sql`. Extracted OUT of `embeddings.zig` so the
  standalone MCP server (which links libsqlite3, never `native_sdk`) shares the EXACT
  same embedder — the index is never re-embedded across the process boundary.
  `embeddings.zig` re-exports every symbol here, so app-side call sites are unchanged.
- **mcp/protocol.zig** — PURE MCP/JSON-RPC core (Task 8), std-only. `parseRequest`
  (id + method + raw `params`), `isNotification`; a hand-rolled `JsonWriter` (exact
  escaping/field order, works in both builds); response builders `writeError`,
  `writeInitializeResult` (protocol `2025-06-18`, server `blocks-memory`),
  `writeToolsListResult` (the 3 tool descriptors + JSON Schemas), `writeToolResult`
  (wraps text as MCP `content`). `tools` table + `findTool`.
- **mcp/tools.zig** — PURE memory-tool query builders + JSON shapers (Task 8). Arg
  parsing (`parseCallArguments`, `parseCommitsArgs`/`parseActivityArgs`/
  `parseSearchArgs` with clamped limits + sentinel time bounds); the SQL
  (`commits_sql_all`/`_by_repo`, `activity_sql` = commits∪snapshots, `search_event_
  row_sql`/`search_snapshot_row_sql`); row→JSON writers (`writeCommitRow`/
  `writeActivityRow`/`writeSearchHit` + `begin*`/`endList`); `excerpt()` for snippets.
- **mcp/mcp_tools.zig** — SDK-side (test-only) integration harness for the tools:
  drives each tool's SQL through a REAL in-memory SQLite via the effects channel,
  decodes with `db.PageReader`, and shapes with the pure writers — the authoritative
  correctness check the standalone binary mirrors. Not imported by the app or sidecar.
- **mcp_server.zig** — the STANDALONE MCP server binary (Task 8), NO `native_sdk`.
  Minimal libsqlite3 `extern "c"` bindings + a `Db.openReadOnly`/`query` shell; an
  HTTP accept loop (`std.Io.net` + `std.http.Server`) on `127.0.0.1`; a JSON-RPC
  dispatcher (`handleRpc`) routing `initialize`/`tools/list`/`tools/call`/`ping` into
  the pure core; `runGetCommits`/`runGetActivity`/`runSearchMemory`. Built by
  `mcp/build.zig` (plain `zig build`, OUTSIDE the SDK graph). See the Task 8 section.
- **repos.zig** — watched-repos data layer. `Repo{id,path,name,active,added_at}`
  `.fromRow(cols)`; `RepoEntry` (owned inline path/name copy) `.fromRepo/.path()/.name()`;
  `insert_sql/delete_sql/list_sql/exists_sql`; `insertStatement(*[3]Value, path, name, now_ms)`,
  `deleteStatement(*[1]Value, id)`; path helpers `normalizePath/defaultName/gitMarkerPath/checkPathShape`.
  `max_repos=128, max_path_bytes=1024, max_name_bytes=256`.
- **tests.zig** — test root: `comptime { _ = @import("config.zig"); ...db, repos... }`
  plus markup-builds and update-arm tests. Run via `native test --yes`.
- **schema/0001_initial_schema.sql** + **schema/migrations.lock.json** — see below.
- **app.native** — current view is the Watched Repositories screen (moves into the
  Settings modal in Task 13).

## Database schema (schema/0001_initial_schema.sql, user_version 1)

All timestamps are Unix-ms INTEGER. Tables (STRICT where possible):
- `repos(id, path UNIQUE, name, active, last_indexed_oid, added_at, last_indexed_at)`
- `events(id, repo_id FK cascade, kind['commit'|'branch'|'checkout'], occurred_at,
  commit_oid, author_name, author_email, subject, body, ref_name, diff,
  files_changed, insertions, deletions, created_at)` + indexes on (repo_id,
  occurred_at) and kind + UNIQUE partial index (repo_id, commit_oid) WHERE
  commit_oid IS NOT NULL.
- `file_snapshots(id, repo_id FK, rel_path, content, diff, content_hash, byte_len, captured_at)`
- `chats(id, title, preview, kind['chat'|'day_recap'|'top_of_mind'|'standup'], created_at, updated_at)`
- `messages(id, chat_id FK, role['user'|'assistant'|'system'], content, seq, created_at)`
- `snippets(id, title, content, language, annotation, origin_chat_id FK SET NULL,
  origin_message_id FK SET NULL, created_at, updated_at)`
- `embeddings(id, source_kind['event'|'file_snapshot'|'message'|'snippet'],
  source_id, model, dim, vector BLOB[raw LE f32], created_at)` + UNIQUE(source_kind, source_id, model)
- `memory_fts` = `CREATE VIRTUAL TABLE ... USING fts5(ref_kind UNINDEXED, ref_id UNINDEXED, body)`

**Migration mechanism:** SDK-native. `native db new-migration <name>` appends
`src/schema/NNNN_name.sql`; the runner AUTO-APPLIES pending migrations on launch
inside one transaction and sets `PRAGMA user_version`. `migrations.lock.json` pins
shipped migration hashes (committed). **Migration SQL constraints (authorizer):**
no BEGIN/COMMIT/SAVEPOINT, no runner-owned PRAGMAs (user_version, foreign_keys,
journal_mode, synchronous, ...); CREATE VIRTUAL TABLE (FTS5) + triggers ARE
allowed; multi-statement files OK. FK cascades work (the writer sets foreign_keys=ON).

---

## Critical SDK/Zig learnings (avoid re-discovering these)

1. **Effects API** (all first-class methods on `fx`, proven live):
   - `fx.spawn(.{ .key, .argv, .stdin?, .output=.lines|.collect, .on_line?, .on_exit? })`
     — subprocess. `.collect` gives whole stdout on the exit Msg (`EffectExit.output`
     + `.stderr_tail`); `.lines` streams via `on_line` (`EffectLine`). `EffectExit`
     has `.code`, `.reason(.exited/.signaled/.cancelled/.rejected/.spawn_failed)`.
   - `fx.readFile/writeFile/appendFile/statFile/deleteFile` (`EffectFileResult`
     `{outcome(.ok/...), bytes, total, mtime_ms, exists}`). writeFile creates parent dirs.
   - `fx.fetch(.{ .url, .method?, .timeout_ms?, .response=.buffered|.stream, ... })`
     — success is `outcome == .ok`; `EffectResponse{outcome,status,body}`.
   - `fx.dbExec(.{ .key, .statements: []Statement, .on_result })` and
     `fx.dbQuery(.{ .key, .sql, .params?, .on_result })`. Result `EffectDbResult`
     `{kind(.page/.done/.exec), outcome, bytes}`. A query yields one-or-more `.page`
     then a `.done`; exec yields one `.exec`. Constraint violation -> `outcome==.constraint`.
   - `fx.wallMs()` — journaled clock read (use for timestamps).
   - `fx.startTimer/cancelTimer` — repeating/one-shot timers (for debounce/polling later).
   - Msg constructors: `Effects.lineMsg/exitMsg/fileMsg/responseMsg/dbMsg/timerMsg`.
   - Effect keys share ONE namespace across spawn/fetch/file; timer keys are separate.
     Current spawn/fetch/file/host keys: 100-102 (bootstrap), 110-113 (repos),
     120-122 (git capture), 130-134 (snapshot scan), 140-141 (launch-at-login host
     requests), 150-152 (embedding generation), 160-161 (MCP child spawn + health
     fetch). TIMER keys (own namespace): 1 = the repeating working-tree scan tick,
     2 = the one-shot MCP health-check delay.
2. **ZIG LIFETIME TRAP (will recur!):** a function returning a struct with
   `.params = &.{ runtimeValue, ... }` DANGLES (temporary array dies at return) →
   causes `.rejected` exec and crashes. FIX: builder takes a caller-owned
   `*[N]db.Value` buffer, fills it, returns a Statement pointing into it; the buffer
   must live until `dbExec` returns (params are copied at call time). Each statement
   in a multi-statement exec needs its OWN buffer. (`&.{...}` of comptime-only values
   is fine; runtime values are the trap.)
3. **Model-owned lists from DB:** query page bytes are valid only during the
   receiving update, so COPY rows into owned inline storage (fixed `[N]u8` buffers +
   len). Pattern in `repos.zig` `RepoEntry`. Model holds `[max]Entry` + count; the
   reload query refills it; expose a slice accessor for `<for each>`.
4. **Text input:** Model holds `canvas.TextBuffer(capacity)` by value (inline, no
   alloc, survives updates). The `on-input` Msg carries `canvas.TextInputEvent`; in
   update call `buffer.apply(event)`. Also `.text()/.isEmpty()/.set()/.clear()`.
5. **Markup gotchas:** `<text size="display"|"heading">` (NOT `scale`).
   `<if test="{cond}">` (attr is `test`, not `cond`). `<for each="sliceAccessor"
   key="id" as="r"> {r.field} </for>`. `on-press="msg:{r.id}"` passes an arg to a
   payload Msg (e.g. `remove_repo: i64`). `<text-field on-input="m" on-submit="m2">`.
   `disabled="{boolAccessor}"`. `<button variant="primary|ghost|secondary" size="sm">`.
   Read-only `<code>` renders as `.text` spans; editable `<code>` as `.textarea`.
   The code component supports language highlight + `line-numbers` + `added-lines`/
   `removed-lines` diff washes.
6. **Lint:** to silence "model field never bound in markup" warnings for
   update-only/accessor-read fields, add `pub const view_unbound = .{ "field", ... }`
   to the Model (and to the Msg union for effect-delivered variants).
7. **Real-DB test pattern:** `relational_store.Database.openMemoryMigrated(alloc,
   &db.migrations)` -> `OpenResult{outcome==.ok, database}`; `fx.bindRelationalStore(
   db.binding())`; drive `dbExec/dbQuery`; drain via `fx.takeMsg()`. Fake executor:
   `fx.executor = .fake` with `feedLine/feedExit/feedDbResult` for wiring-only tests.

## RESOLVED architectural item (was: "tray needs Runtime access")

The earlier worry was that the tray (`createTray`) and native dialogs are
**Runtime methods** unreachable from the pure `update(model, msg, fx)` core. Task 6
proved that WRONG for the tray: `UiApp` exposes the tray DECLARATIVELY, and reaches
system services through the effects channel the core already has. No drop-down to
the App/Runtime layer was needed. Specifically:
- **Tray:** `UiApp.Options` has `status_item`/`status_item_fn`/`status_items_fn`.
  We use `status_item_fn(model, scratch) StatusItemState` (builds the menu into the
  provided scratch each rebuild) + `on_command(name) ?Msg`. The runtime calls the
  Runtime-level `createStatusItem`/`updateStatusItem*` for us. Menu selections and
  activation/open commands all arrive through `on_command`.
- **Window control / quit from the core:** `fx.showWindow(label)`,
  `fx.hideWindow`, `fx.closeWindow`, `fx.quitApp()` (all on the Effects handle,
  all mirrored by the fake executor via `fx.windowActionState()`). Also
  `fx.setDockPresence(visible)` for accessory-app mode later if wanted.
- **Launch-at-login:** a native host request on the same `fx` — no Runtime and no
  manifest capability. See the Task 6 section.

STILL OPEN (Task 3 nicety only): a **native folder picker** for Watched
Repositories (`showOpenDialog`) is a Runtime/WebView-bridge path; Task 3's
text-input path field remains in place. If we ever want the native picker we can
revisit whether a UiApp seam exposes it, or use the JS bridge — low priority.

---

## Task 4 — Git history capture (DONE — what was built)

Commit history for each active watched repo is indexed INCREMENTALLY into the
`events` table (kind='commit') via `fx.spawn` of `git`. Progress is tracked in
`repos.last_indexed_oid` + `last_indexed_at`. Diffs/branch/checkout events were
DEFERRED (schema allows NULL diff; branch/checkout is lower priority for v1) —
see "Deferred / follow-ups" below.

Capture pipeline (all in `main.zig`, driven by the pure builders/parsers in
`git.zig`):
1. `repos_listed` terminal `.done` (on boot after the list loads, and again after
   a repo is added) calls `startCapture` → `captureNext`.
2. `captureNext` walks `repo_list` from `capture_idx`, skips inactive repos, and
   for the current repo `dbQuery`s `select_last_indexed_sql` (key 120) to learn
   where it left off.
3. `captureSinceDone` copies the `last_indexed_oid` (empty = never indexed), then
   on the query's terminal `.done` calls `spawnCaptureLog`.
4. `spawnCaptureLog` (key 121) spawns `git.logArgv(...)` with `.output = .collect`.
5. `captureLogDone` parses the collected stdout with `git.parseLog` (up to
   `max_commits_per_pass = 128` commits), builds ONE `dbExec` batch (key 122) of an
   INSERT per commit + a final `updateIndexedStatement` setting `last_indexed_oid`
   to the newest (last, since `--reverse`) commit's oid, all params in
   frame-local buffers (lifetime trap). A non-zero git exit or empty result just
   advances to the next repo.
6. `capture_write_done` advances `capture_idx` and calls `captureNext`; when the
   list is exhausted, `capturing` is cleared.

Idempotency: a re-run asks git only for `<since>..HEAD`, so already-indexed repos
return nothing and are skipped. The UNIQUE(repo_id, commit_oid) partial index is
the backstop (a duplicate insert → `.constraint`), which the integration test
exercises.

Model state added: `capturing`, `capture_idx`, `capture_repo_id`,
`capture_path_buf/len` (+ `capturePath`), `capture_since_buf/len` (+ `captureSince`).
Msg arms: `capture_since_done`, `capture_log_done`, `capture_write_done`.

Tests (40 total pass): `git.zig` unit tests for `logArgv` (with/without range),
`parseLog` (single, multi + multi-line body, empty, binary `-` counts, no-change
commit), `isoToUnixMs` (UTC / `+HH:MM` offset / malformed fallback), and the two
statement builders; plus two REAL in-memory-DB integration tests (parse→insert→
read-back with correct numstat totals + bookkeeping oid, and the duplicate-commit
constraint). The exact `--format` string was also verified against real
`git log` output from THIS repo (multi-line bodies and binary-file `-\t-` numstat
lines parse correctly).

### Deferred / follow-ups (candidates for later polish)
- **Per-commit full diff** (`events.diff`): still NULL. Fetch lazily (`git show
  <oid>`) when a commit is opened, or add a `--patch` pass — decide when the chat/
  retrieval UI needs it.
- **Branch/checkout events**: not captured yet (commits are the core for v1).
- **>128 new commits in one pass**: bookkeeping advances to the last written oid,
  so the REST is captured on the NEXT pass (boot/add) — full history is still
  captured, just across passes. If a repo import needs to complete in one go,
  loop the log spawn until `parseLog` returns fewer than the cap.
- **Capture is only triggered on boot + after add** (no live polling yet). A timer
  (`fx.startTimer`) or the Task 6 always-on tray can drive periodic re-capture.

## Task 5 — Working-tree file-change capture (DONE — what was built)

**Design decision:** there is NO filesystem-watch effect in the SDK (confirmed by
scanning `src/runtime/effects.zig` — no watch/notify/fs_event surface). So capture
is POLL-based: a repeating `fx.startTimer` (interval `snapshot_interval_ms =
15_000`) IS the debounce/coalesce window. Each tick asks git which working-tree
files changed, reads each one's current content, and stores a snapshot into
`file_snapshots` ONLY when the content hash differs from the last stored snapshot
for that path (unchanged saves are skipped — the core dedup rule).

Scan pipeline (all in `main.zig`, driven by the pure builders/parsers in
`snapshots.zig`):
1. `armSnapshotTimer` (once, on the first `repos_listed` `.done`) starts the
   repeating timer (timer key 1, its OWN namespace) delivering `snapshot_tick`.
2. `snapshot_tick`: ignored if `.rejected` or if a scan is already running (a tick
   mid-scan is dropped — that IS the coalescing). Else `startScan` → `scanNextRepo`.
3. `scanNextRepo` walks `repo_list`, skips inactive repos, and spawns
   `snapshots.statusArgv` (`git status --porcelain=v1 -z`, key 130, `.collect`).
4. `snapStatusDone` parses the NUL-delimited output with `parseStatus` into the
   model-owned `scan_paths` list (copied out — the output bytes don't survive),
   then `scanNextFile`.
5. `scanNextFile` queries the file's last stored hash (`select_last_hash_sql`,
   key 131). When the file list is exhausted, advances to the next repo.
6. `snapLastHashDone` copies the last hash; on the query `.done`, `readCurrentFile`
   reads the file (key 132, absolute path joined into a STACK buffer — readFile
   copies the path at call time, so no arena leak).
7. `snapContentDone`: skips if `outcome != .ok` (unreadable / deleted between
   status and read) or the content is `.truncated`/over `max_content_bytes` (256K)
   — we never store a partial file. Otherwise copies content into owned storage,
   SHA-256s it; if the hash equals the last stored hash, SKIP. Untracked files get
   an empty diff; tracked files spawn `snapshots.diffArgv` (`git diff -- <path>`,
   key 133, `.collect`).
8. `snapDiffDone` caps the diff at `max_diff_bytes` (256K) and `writeSnapshot`
   inserts the `file_snapshots` row (key 134, frame-local params).
9. `snap_write_done` advances the file index and continues.

Bounds/state: `max_changed_files = 64` per repo per scan; content/diff capped at
256K each. Model state: `scanning`, `scan_timer_started`, `scan_repo_idx`,
`scan_repo_id`, `scan_repo_path_*` (+ `scanRepoPath`), `scan_paths[]` +
`scan_path_count`, `scan_file_idx`, `scan_content_*`, `scan_hash_buf`,
`scan_last_hash_*`. New type `ChangedPath` (inline path copy + `untracked` flag).
NOTE (Zig): all Model FIELDS must precede all Model METHODS — interleaving a new
field block after existing accessor fns fails with "declarations are not allowed
between container fields." Group new fields with the other fields.

Tests (50 total pass): `snapshots.zig` unit tests for `statusArgv`/`diffArgv`,
`parseStatus` (modified+untracked, rename 2nd-field skip, deletion skip, empty),
`sha256Hex` (KATs for "abc"/""), and `insertStatement`; plus a REAL in-memory-DB
integration test (two snapshots of one file → last-hash query returns the newest,
both versions retained, byte_len stored). The porcelain `-z` format was verified
against a real repo (`XY path\0`, rename `R  new\0orig\0`).

**Verified END-TO-END via the automation GUI:** added THIS repo as a watched repo,
made working-tree changes, and confirmed against `app.db`: 4 changed files each got
one snapshot (tracked files carried a real `diff`, untracked files an empty diff);
a second tick added NOTHING (unchanged files skipped); editing one file produced
exactly ONE new snapshot version (row count 4 → 5). Test data was cleared from
`app.db` afterward.

### Deferred / follow-ups
- **Deletions**: a deleted working-tree file is skipped (no content to snapshot).
  Recording a "file deleted" marker is a later concern.
- **Rename provenance**: renames are snapshotted at the NEW path; the old path is
  discarded (not linked as "renamed from"). Fine for content memory.
- **Poll cadence**: fixed 15s. Could adapt (faster right after a save, idle-backoff)
  or, if the SDK later exposes an FS-watch effect, switch off polling entirely.
- **Non-git-tracked dirs**: capture is scoped to `git status` output, so files
  ignored by `.gitignore` are NOT captured (intentional — matches "git-scoped
  memory").
- **Large files (>256K)**: skipped entirely (no partial snapshots).

## Task 6 — Always-on tray + auto-start on login (DONE — what was built)

The app now installs a menu-bar (status item) tray and can register itself as a
login item. This is entirely on top of the existing `UiApp` — NO drop-down to the
App/Runtime layer (see "RESOLVED architectural item" above). The capture loops
(Task 4 git, Task 5 snapshots) already run while the process is alive, so
"always-on" is: keep the process reachable from the tray + start it at login.

Tray (declarative, in `main.zig` on the `BlocksApp.create(...)` Options):
- `.status_item_fn = statusItem` — `statusItem(model, scratch)` calls
  `tray.buildMenu(&scratch.items, model.login_enabled, model.login_supported)` and
  returns `StatusItemState{ .title = "Blocks", .tooltip = ..., .items = ... }`. The
  menu is model-derived, so the "Start at Login" row reflects live state and the
  runtime re-applies it on rebuild.
- `.on_command = onTrayCommand` — maps the menu command strings (from `tray.zig`)
  to `Msg`s: `blocks.open_window` → `.open_window`, `blocks.toggle_login` →
  `.toggle_login`, `blocks.quit` → `.quit_app`.
- Update arms: `.open_window` → `fx.showWindow("main")`; `.quit_app` →
  `fx.quitApp()`.

Launch-at-login (native host request on `fx`, keys 140/141):
- On boot, `initFx` fires `fx.hostRequest(.{ .name = "native-sdk.launch-at-login.
  status", .on_result = Effects.hostMsg(.login_status_done) })`.
- `.toggle_login` (guarded by `login_supported`) sends
  `"native-sdk.launch-at-login.set"` with a one-byte payload
  (`@intFromBool(enable)`), result → `.login_set_done`.
- `applyLoginResult` decodes `EffectHostResult`: on `ok`, bytes `"enabled"`/
  `"requires_approval"` → `login_enabled = true`; `"disabled"`/`"not_found"` →
  false; on `!ok`, `"unsupported"` → `login_supported = false` (toggle shown
  disabled). Model fields: `login_enabled`, `login_supported`.

Tests (61 total pass): `tray.zig` unit tests for `buildMenu`/`loginToggleLabel`/
row ids; plus fake-executor `update` tests in `tests.zig` — tray Open bumps
`fx.windowActionState().show_count` with label "main", Quit bumps `quit_count`,
and the login result arms flip `login_enabled`/`login_supported` for each bytes
case (enabled/disabled/requires_approval/unsupported) incl. the unsupported-toggle
no-op.

**Verified END-TO-END via automation:** the snapshot showed
`tray #1 title="Blocks" visible=true items=5` with the exact rows/commands;
`tray-action 1` (Open) delivered and the window stayed present; `tray-action 5`
(Quit) drove the runtime log `event="blocks.quit"` → `event="stop"` →
`native dev: app exited` — definitive proof the tray→command→effect chain works.
The timer ticks in the same log confirm the Task 5 scan runs alongside the tray.
NOTE: under `native dev` the "Start at Login" row is DISABLED because the dev build
isn't an installed `.app` bundle SMAppService can register (host returns
"unsupported"/"not_found") — expected; it becomes enabled in a packaged build.

### Deferred / follow-ups
- **Native folder picker** for Watched Repositories (Task 3 nicety) — still the
  text-input path; a Runtime/bridge dialog, low priority.
- **Dock presence** — the app currently shows a normal Dock icon + window
  (matches the mockups). `fx.setDockPresence(false)` could make it an
  accessory/menu-bar-only app later if desired.
- **Packaged-build login item** — verify the enabled toggle actually registers via
  SMAppService when running the packaged `.app` (dev can't exercise this).

## Task 7 — Embeddings generation + vector search (DONE — what was built)

Captured memory (git commit events + working-tree file snapshots) is embedded into
the `embeddings` table and mirrored into `memory_fts`, and there is a vector-search
+ FTS hybrid retrieval path ready for Task 8's MCP tools.

**KEY DECISION — the embedder (read this before Task 9):** the locked decision is
"bundled llama.cpp embeddings," but that runtime is Task 9. Rather than block Task 7
on it, v1 uses a DETERMINISTIC in-process HASHING embedder (feature hashing, model
id `hash-v1`, `dim = 256`) in `embeddings.zig` — no model download, no subprocess,
fast, and one fixed function so the index never needs re-embedding (matches the
"ONE fixed embedding model" decision). It gives real lexical/semantic-ish retrieval
now. When Task 9 lands a neural embedder, register it under a NEW `model` id (e.g.
`llama-<name>-v1`); `UNIQUE(source_kind, source_id, model)` lets both coexist and a
query picks which model's vectors to search — so the swap is localized and clean.
This is an honest v1 stand-in, NOT the final embedding quality.

Generation pass (`main.zig`, keys 150-152), triggered when a git-capture pass or a
snapshot scan finishes (`startEmbedPass` at the end of `captureNext`/`scanNextRepo`):
1. `startEmbedPass` (coalesced by an `embedding` flag) → `queryUnembedded(.events)`.
2. `queryUnembedded` runs `select_unembedded_events_sql`/`_snapshots_sql` (rows with
   no `hash-v1` embedding, `LIMIT embed_batch = 16`), resetting `embed_last_rows`.
3. On a `.page`, `embedPageRows` embeds up to 16 rows IN-PROCESS and issues ONE
   `dbExec` batch of (embedding insert + memory_fts insert) per row — all backing
   storage (vectors, text, params) frame-local (dbExec copies params at call; the
   page bytes are valid this update).
4. Continuation is driven STRICTLY from `embed_write_done` → `queryUnembedded`
   again, so each write commits before the next query runs (no re-embedding). The
   query's terminal `.done` advances the phase / ends the pass ONLY when the batch
   came back empty (`embed_last_rows == 0`). Events drain first, then snapshots,
   then `embedding = false`. (Relies on the runtime's FIFO effect delivery: a
   query's `.done` is enqueued before the write it spawned.)

Search / retrieval (in `embeddings.zig`, consumed by Task 8):
- Vector: `embed(query)` → `select_vectors_sql` (all vectors for the model) →
  `rankPage(hits, count, &query, page_bytes)` decodes each stored vector and
  top-k ranks by dot product (== cosine for the normalized vectors).
- Keyword/hybrid: `fts_search_sql` (`memory_fts MATCH ?1 ORDER BY rank`).

Tests (74 total pass): `embeddings.zig` unit tests (blob round-trip, normalize,
deterministic + normalized embed, camelCase tokenizer, similar>unrelated cosine,
top-k, statement params) + TWO real in-memory-DB integration tests (vector search
ranks the most-similar memory first; FTS keyword arm finds the right row).

**Verified END-TO-END via automation** (added THIS repo, waited for capture+embed,
inspected `app.db`): 7 commit events → 7 event embeddings, 3 file snapshots → 3
file_snapshot embeddings; 10 embeddings == 10 `memory_fts` rows, all `model=hash-v1
dim=256` with 1024-byte (256×f32) vectors; a second scan tick added NOTHING (dedup
via the NOT-EXISTS query + UNIQUE index); live FTS `MATCH 'tray'` surfaced the
Task 6 tray commit and the `tray.zig` snapshot. Test data cleared from `app.db`
afterward.

### Deferred / follow-ups
- **Neural embedder (Task 9)**: swap in bundled llama.cpp under a new `model` id;
  the schema + the model-parameterized queries already support coexistence.
- **Chunking**: long files/commits are embedded as ONE truncated
  (`embed_text_bytes = 4096`) vector. Per-chunk embeddings (with an offset column)
  would improve recall on large files — later.
- **Hybrid fusion**: vector and FTS arms exist independently; blending them (e.g.
  reciprocal-rank fusion) into one ranked list is a Task 8 concern once the MCP
  `search_memory` tool defines its output contract.
- **Re-embed on model change**: not automated yet — when a new `model` id ships,
  the un-embedded queries naturally pick every row up (they filter by model), so a
  pass simply re-runs; no migration needed.

## Task 8 — MCP server (spawned child) exposing memory tools (DONE — what was built)

The developer memory is now exposed to an LLM over MCP. The server is a SPAWNED
CHILD PROCESS (locked decision: the SDK has a `fetch` CLIENT but NO in-process
socket-listener effect), it opens the same `app.db` READ-ONLY, and speaks JSON-RPC
2.0 over HTTP on `127.0.0.1`. Three tools: `search_memory` (vector + keyword),
`get_activity` (commits ∪ file snapshots), `get_commits`.

**KEY DECISION — the child's runtime + how it opens the DB (read before Task 9/10):**
- The child is a STANDALONE Zig binary (`src/mcp_server.zig`) with NO `native_sdk`
  dependency, built by its OWN `mcp/build.zig` via plain `zig build` — deliberately
  OUTSIDE the SDK's generated/ejected build graph. Why not the SDK's sidecar seam?
  The SDK's `{app}_services` child is TypeScript-core only (`ts_stage` in the
  framework `build/app.zig`); a zig-core app can't use it without ejecting the whole
  build. Why not import the SDK's relational store? It's only wired into the
  app-runtime build graph. So the child links the SYSTEM **libsqlite3** (ships on
  every macOS) and opens `app.db` with `sqlite3_open_v2(..., SQLITE_OPEN_READONLY)`.
  The app runtime remains the SOLE WRITER; the child only reads. `app.db` is a plain
  SQLite file (the spike confirmed this), so this is clean.
- To keep the SAME embedder on both sides of the process boundary (so the index is
  never re-embedded), the pure embedding math was extracted into `src/embed_core.zig`
  (std-only); both `embeddings.zig` (app) and `mcp_server.zig` (child) use it. Same
  `hash-v1`, same vectors.
- **Transport shape:** Streamable HTTP, v1 subset — a POST carries one JSON-RPC
  request and the response body is the JSON-RPC reply (no SSE/GET stream yet; a GET
  returns 405). Protocol version advertised: `2025-06-18`. The app's own LLM is the
  only v1 consumer, over loopback.

Layering (all tool LOGIC is PURE and unit-tested; only I/O lives in the binary):
- `mcp/protocol.zig` — JSON-RPC parse + a hand-rolled `JsonWriter` + the
  `initialize`/`tools/list`/tool-result payloads. `mcp/tools.zig` — arg parsing +
  SQL + row→JSON shapers. Both are std-only and exercised by `native test`
  (`mcp/mcp_tools.zig` runs them against a REAL in-memory SQLite via the effects
  channel). `mcp_server.zig` re-runs the IDENTICAL SQL through its libsqlite3 shell.

The binary (`mcp/zig-out/bin/blocks-mcp`), usage
`blocks-mcp --db <app.db> [--port N] [--endpoint <file>]`:
1. Opens the DB read-only; builds an `Io` from `std.process.Init` (Zig 0.16).
2. Binds `127.0.0.1` — the requested port (default `39017`), scanning up to 32
   ports on `AddressInUse` — and writes `{"port":N,"pid":P}` to
   `<db-dir>/mcp-endpoint.json` so the parent can discover it.
3. Accept loop: each POST body is parsed once, dispatched, and answered.
   `initialize` → capabilities + serverInfo; `tools/list` → the 3 descriptors;
   `tools/call` → run the tool's SQL, shape rows to JSON, wrap as MCP text content;
   `ping` → `{}`; notifications → 202; unknown method → JSON-RPC -32601.
   `search_memory` embeds the query with `embed_core`, ranks ALL stored vectors for
   `hash-v1` (top-k `considerTopK`), then fetches each hit's display row.

App wiring (`main.zig`, keys 160/161, timer key 2): on the first `repos_listed`
`.done` (app.db exists + migrations applied), `startMcpServer` spawns the child with
`--db <paths.db> --port 39017` (`.collect`; a child exit delivers `mcp_exit` →
`mcp_failed`, non-fatal — the app keeps running). A one-shot 400 ms timer then fires
`healthCheckMcp`, which POSTs a `tools/list` to `http://127.0.0.1:39017/`; a 200
sets `model.mcp_ready`. Model flags: `mcp_started`/`mcp_ready`/`mcp_failed`.

Tests (100 total pass): pure `protocol.zig` tests (envelope parse, escaping, each
payload is valid JSON, error shape) + pure `tools.zig` tests (arg clamping, SQL
selection, each shaper round-trips through `std.json`) + `mcp_tools.zig` real-DB
integration tests (get_commits newest-first + repo filter, get_activity union +
time window, search_memory vector ranking + FTS arm) + `embed_core.zig` unit tests
+ four `main.zig` update-arm tests (health 200 → ready; failed health → not ready
non-fatal; child exit → failed; rejected timer tick ignored).

**Verified END-TO-END** against the real running app: `native dev -Dautomation=true`
spawned the child (endpoint file written with pid+port); added THIS repo via the
automation GUI; after capture+embed (`app.db`: 1 repo, 8 events, 18 embeddings, 18
FTS rows) a `curl` POST to the app-spawned child returned real `get_commits` (Task
7/6/5 with correct OIDs/authors/stats), and `search_memory "embeddings vector
search"` ranked the "Task 7: Embeddings…" commit first (0.20) then the
`src/embed_core.zig` snapshot. Also confirmed the raw protocol: `initialize`,
`tools/list`, `notifications/initialized`→202, unknown→-32601, `ping`→`{}`, GET→405.
Test data cleared from `app.db` and the endpoint file removed afterward.

### Deferred / follow-ups
- **Packaged-build binary path**: the app spawns the child by the repo-relative
  path `mcp/zig-out/bin/blocks-mcp` (works under `native dev`, whose cwd is the repo
  root). A packaged `.app` ships the binary in the bundle; locating it there needs
  the bundle/executable dir, and the SDK effects channel has NO self-path/exe-dir
  helper today. Options for later: add a UiApp seam for it, pass the path via env at
  package time, or have the app write a launcher. `fx.spawn` argv[0] resolves via
  the child's PATH, so a bare name won't do — an absolute path is required.
- **Build integration**: the sidecar is built with a SEPARATE `zig build --build-file
  mcp/build.zig` step; it is NOT hooked into `native build`/`native package` yet, so
  packaging must invoke it (and copy the binary into the bundle). Wire this when
  Task 13 does packaging/polish.
- **Health-check retry/backoff**: a failed first health check leaves `mcp_ready`
  false with no retry (the 400 ms delay is usually enough). Task 10 (chat) should add
  retry/backoff and surface `mcp_ready`/`mcp_failed` in the UI, and restart the child
  if it dies (`mcp_exit`).
- **search_memory hybrid fusion**: v1 ranks by VECTOR similarity only (the FTS arm
  exists in `embeddings`/`embed_core` + is integration-tested, but the tool doesn't
  yet blend FTS into the ranked list). Reciprocal-rank fusion is the natural next
  step once real neural embeddings (Task 9) raise the bar.
- **Streamable-HTTP GET/SSE**: not implemented (v1 is POST-only; GET→405). Only
  needed if a non-app MCP client wants server-initiated streaming.
- **Auth**: none — the server binds loopback only and is single-user. If it ever
  binds beyond `127.0.0.1`, add a token (e.g. written next to the endpoint file).
- **get_commits diff/body**: commits expose subject + stats, not the full diff
  (still NULL in `events.diff`, a Task 4 deferral). Add a `get_commit_diff` tool or a
  `diff` field once capture stores diffs.
