# Blocks for Developers — Progress & Resumption Notes

Last updated: end of Task 4 (git history capture; not yet committed). Read this
first when resuming. To continue: open the IDE on this repo folder
(`/Users/rpbarreira/Projects/GitHub/rpbarreira/blocks-for-developers`) and say
"read docs/PROGRESS.md and continue from Task 5."

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
- [x] **Task 4 — Git history capture.** DONE (not yet committed). New module
  `src/git.zig` + capture wiring in `main.zig`. 40 tests pass; format verified
  against real `git log` output from this repo.
- [ ] **Task 5 — Working-tree file-change capture (debounced snapshots).** ← NEXT
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
     Current keys used: 100-102 (bootstrap), 110-113 (repos), 120-122 (git capture).
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

## NEXT: Task 5 — Working-tree file-change capture (debounced snapshots)

Goal: watch each active repo's working tree for file saves and record debounced,
coalesced snapshots (full content + diff vs the previous snapshot) into
`file_snapshots`. Use `fx.startTimer` for debounce/coalescing; SHA-256 the content
to skip unchanged saves (schema `content_hash`). The `file_snapshots` table +
`idx_snapshots_repo_path_time` index already exist. Keep the same shape as Task 4:
a pure module (hashing/diff/path helpers, unit-tested) + thin effectful wiring in
`main.zig`. Note: there is no built-in FS-watch effect surfaced yet — check the SDK
effects surface (`src/runtime/effects.zig`) for a watch/notify effect; if none, a
periodic timer that stats/scans tracked files (or `git status --porcelain` +
`git diff`) is the fallback.
