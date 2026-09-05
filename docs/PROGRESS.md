# Blocks for Developers — Progress & Resumption Notes

Last updated: end of Task 3 (commit `cef9fb1`). Read this first when resuming.
To continue: open the IDE on this repo folder
(`/Users/rpbarreira/Projects/GitHub/rpbarreira/blocks-for-developers`) and say
"read docs/PROGRESS.md and continue from Task 4."

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
- [ ] **Task 4 — Git history capture.** ← NEXT (not started; only sketched a plan).
- [ ] Task 5 — Working-tree file-change capture (debounced snapshots).
- [ ] Task 6 — Always-on tray + auto-start on login. (NOTE: tray needs Runtime
  access — see "Open architectural item" below.)
- [ ] Task 7 — Embeddings generation + vector search.
- [ ] Task 8 — MCP server (spawned child) exposing memory tools.
- [ ] Task 9 — Local model management + llama.cpp runtime.
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
     Current keys used: 100-102 (bootstrap), 110-113 (repos).
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

## OPEN ARCHITECTURAL ITEM (blocks Task 6, affects a Task 3 nicety)

Native dialogs (`showOpenDialog`) and the tray (`createTray`) are **Runtime
methods** (see `core.zig` `SystemServiceMethods`), but the pure model core's
`update(model, msg, fx)` never receives a `Runtime`, and the UiApp Options hooks
(`on_command/on_lifecycle/on_frame/on_key`) only return `?Msg`. The bridge dialog
path is WebView/JS only. So:
- Task 3 used a TEXT-INPUT path field instead of a native folder picker (works
  fine, verified).
- Task 6 (tray, always-on) WILL need Runtime access. Plan: drop down to the
  lower-level App/Runtime layer (the App Model doc's "dropping down" section:
  `UiApp is a layer over the lower-level App/Runtime pair`). Solve it there, and
  optionally restore a native folder picker for Watched Repositories at the same time.

---

## NEXT: Task 4 — Git history capture (plan)

Goal: for each watched repo, read commit history + diffs + branch/checkout events
into the `events` table INCREMENTALLY (only new activity since last index), using
`fx.spawn` of `git` (proven in the spike). Track progress with
`repos.last_indexed_oid` (and `last_indexed_at`).

Suggested approach:
- New module `src/git.zig`: PURE argv builders + PURE output PARSERS (unit-testable
  without spawning), keeping the effectful spawn wiring thin in main.zig.
- Commits: `git -C <path> log --reverse --format=<fmt> [<since>..HEAD]` (oldest-first
  so `last_indexed_oid` advances correctly; `<since>` = last_indexed_oid when present,
  else full history). Use control-char delimiters to parse robustly regardless of
  message content, e.g. fields separated by `%x1f` (unit sep) and records by `%x1e`
  (record sep). Suggested format fields: `%H` (hash) `%an` `%ae` `%aI` (author ISO
  date) `%s` (subject) `%b` (body). Consider adding `--numstat` (or a `--shortstat`
  pass) to fill files_changed/insertions/deletions.
- Per-commit full diff (`diff` column) can be fetched lazily/separately
  (`git show <oid>`), or deferred — the schema allows NULL diff; decide during impl.
- Branch/checkout events: lower priority for v1; commits are the core. Can capture
  current branches via `git branch` / reflog later if time allows.
- Insert parsed commits with `insertStatement`-style caller-owned param buffers
  (remember the lifetime trap!). Respect the UNIQUE(repo_id, commit_oid) index —
  inserting a duplicate should be avoided (query max indexed, or ignore constraint).
- After indexing a repo, UPDATE repos.last_indexed_oid + last_indexed_at.
- Trigger: index each active repo on boot after the repo list loads, and after a
  repo is added (Task 3's add flow already knows when a repo is added).

Tests: build a fixture git repo with known commits (create in a tmp dir inside the
test, or a helper), run the parser over real `git log` output captured as a fixture
string, assert the parsed commits. Also a real-DB integration test: insert parsed
commits and query them back; verify incremental re-run adds nothing new.

I had started only by creating a throwaway fixture at /tmp/blocks_t4_repo to design
the parser format — no code written yet. That tmp dir may be gone; recreate as needed.
