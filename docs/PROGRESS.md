# Blocks for Developers — Progress & Resumption Notes

> **THIS FILE IS THE MAIN SOURCE OF TRUTH FOR THE PROJECT. KEEP IT ACCURATE.**
> Going forward, EVERY change to the codebase must be reflected here in the SAME
> change — update the relevant Task section (or add a "Post-v1 changes" entry) so a
> future reader can trust this file over their memory. If a later change supersedes
> something an earlier section described, edit that section (or add an inline
> `> SUPERSEDED:` note) rather than leaving it wrong. A stale resumption log is worse
> than none, because it is read first and trusted.

Last updated: end of Task 13 (Welcome/onboarding flow + Settings modal + UI
polish), VERIFIED END-TO-END live via automation, PLUS packaging + a set of post-v1
UI refactors (see "Post-v1 changes" below). Schema is still user_version 2
(migration 0002 added `snippets.text_expander`). All 14 v1 tasks (0-13) are
implemented, committed, and the app is packaged (see the "Packaging" section). Read
this file first when resuming.
Committed so far: Tasks 4-9 (`01969e5`/`56ae2a2`/`c2afa1b`/`e27eb0a`/`887480e`/
`7a6961d`+`2ec4210`), Task 10 (`db4ce24`), Task 11 (`0fd1db3`), Task 12 (`9ff424a`),
Task 13 (`b824dd2`+`2b4c904`+`c0f3d95`+`78fceb3`+`fb48067`+`6663f46`+`323d86f`+
`38fcec6`+`7fa5827`+`8c49c81`). All 14 v1 tasks (0-13) are implemented AND committed.
Packaging is DONE (`94cb022`; see the "Packaging" section). Post-v1 UI refactors are
logged under "Post-v1 changes". Read this file first when resuming.

**Runtime note for live runs:** the llama.cpp runtime is `llama-server`
(installed via `brew install llama.cpp`, at `/opt/homebrew/bin/llama-server`).
`native dev` must be launched with `BLOCKS_LLAMA_SERVER=/opt/homebrew/bin/llama-server`
so the app can spawn it (the packaged build will vendor it — Task 13).

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
- [x] **Task 8 — MCP server (spawned child) exposing memory tools.** DONE
  (commit `887480e`). New standalone binary `src/mcp_server.zig` (+ `mcp/build.zig`) and a
  pure core `src/mcp/` (protocol + tools) + `src/embed_core.zig`; spawn/health wired
  into `main.zig`. 100 tests pass; VERIFIED END-TO-END (app spawned the child, added
  this repo, and `get_commits`/`get_activity`/`search_memory` returned correct real
  data over HTTP). See the Task 8 section.
- [x] **Task 9 — Local model management + llama.cpp runtime.** DONE.
  New PURE module `src/models.zig` (curated GGUF catalog + curl/mv/
  llama-server argv builders + progress + config parsing), `config.json` gains a
  `selected_model` (bootstrap `configJson`), and the download/runtime lifecycle is
  wired into `main.zig` (keys 170-175, timer key 3) with a "Local model" section in
  `app.native`. 123 tests pass; `native check` clean. See the Task 9 section.
- [x] **Task 10 — Chat experience wired to model + MCP.** DONE. New PURE module
  `src/chat.zig` (chats/messages data layer + OpenAI request builder + SSE stream
  parser + MCP search request/response shaping) + the chat lifecycle wired into
  `main.zig` (keys 180-185) + a chat view in `app.native`. Uses retrieval-augmented
  generation (MCP `search_memory` → injected context), NOT native tool-calling.
  148 tests; `native check` clean; VERIFIED END-TO-END live (streamed replies
  grounded in real git memory, persisted to `chats`/`messages`). See the Task 10
  section. A semantic review caught + fixed a turn-overlap persistence race.
- [x] **Task 11 — Single-click summaries.** DONE. New PURE additions to
  `src/chat.zig` (`SummaryKind` enum + `chat_insert_kind_sql`/
  `chatInsertKindStatement` + `buildActivityRequest`/`formatActivityContext`) +
  the summary turn wired into `main.zig` (key 186, `pending_summary_kind`) +
  three summary cards in `app.native`. Day Recap / What's Top of Mind / Standup
  Update each pull recent activity from the MCP `get_activity` tool and ask the
  local model to write a canned summary, saved as a chat with its own
  `chats.kind`. 159 tests; `native check` clean. See the Task 11 section.
- [x] **Task 12 — Materials (snippets) screen + chat cross-linking.** DONE.
  Schema migration `0002` adds `snippets.text_expander` (user_version now 2). New
  PURE `src/snippets.zig` (list card `SnippetEntry` + full `SnippetDetail` + SQL +
  statement builders + LIKE search). Materials screen wired into `main.zig`
  (keys 190-198, a `Screen` nav) + `app.native` (sidebar list with sort +
  language-filter menus, search, selected-snippet panel with code + All Context
  = Annotations + Text Expander, an editor for add/edit, a set-language typeahead),
  plus Save-to-Snippets from chat + Start-Copilot-Chat + copy-to-clipboard. 184
  tests; `native check` clean; VERIFIED END-TO-END live. See the Task 12 section.
  (SUPERSEDED post-v1: the editor is now a separate OS window and the set-language
  modal was removed — language is edited in the editor. See "Post-v1 changes".)
- [x] **Task 13 — Welcome flow + settings modal completion + polish.** DONE.
  Full-screen onboarding (welcome splash -> pick-a-local-model) gated on the
  persisted `onboarded` flag, a Settings modal (About / Model Context Protocol /
  Local Model + Watched Repositories) moved out of the chat screen, model catalog
  cards with size + RAM + tier badges, and a custom `app:sparkle` vector icon.
  Fixed a real boot bug (onboarded was inferred from config-file EXISTENCE; now
  read from the config CONTENTS) + the Task 9 `wrote_config` clobber. 198 tests;
  `native check` clean; VERIFIED END-TO-END live via automation. See the Task 13
  section. This was the FINAL v1 task — Tasks 0-13 are all implemented.

---

## Source layout (all under `src/`)

- **main.zig** — the app: Model/Msg/`update`/`initFx`, window/manifest wiring, the
  boot sequence, and the full app shell (onboarding + chat + materials + settings).
  `main(init)` detects username, registers `app_icons` (`app:sparkle`), then
  `UiApp.create(...)` + `runner.runWithOptions(...)`. BOOT/ONBOARDING (Task 13): the
  `onboarded` flag is read from the config CONTENTS (`models.parseOnboarded` in
  `config_read_done`), NOT inferred from config-file existence — so a user who quit
  mid-onboarding still sees the welcome flow. Model has `onboard_step`/`settings_open`/
  `settings_section` + the `needsOnboarding`/`onWelcomeStep`/`settings*`/`appVersionText`/
  `mcpUrlText`/`llamaUrlText`/`loginToggleLabel` accessors; `persistConfig` (key 200)
  rewrites config.json for a model change / onboarding completion WITHOUT re-running
  the first-run arm. SETTINGS WINDOW (Task 13): `blocksWindows` (windows_fn) declares a
  SECONDARY OS window when `settings_open`, and `blocksWindowView` (window_view) builds
  its tree in Zig with the `Ui.*` builders (markup binds only the main canvas). Wired
  into `BlocksApp.create` via `.windows_fn`/`.window_view`.
- **config.zig** — PURE, unit-tested. `Paths.resolve(alloc, bundle_id, lookup)`
  -> `{data_dir, db, models, config}` via `native_sdk.app_dirs` (macOS `.data` =
  `<HOME>/Library/Application Support/<bundle_id>`). `detectUsername(lookup, home)`
  (precedence USER > LOGNAME > HOME-basename > "developer"), `detectHome`,
  `joinPath`, `envFromLookup`.
- **env.zig** — `get(name)`/`lookup(name)` read env via `std.c.environ` (app links
  libc; Zig 0.16 std.process env API is unstable). Returns borrowed slices.
- **bootstrap.zig** — `configJson(alloc, username, version, selected_model,
  onboarded)` -> JSON `{version, username, onboarded, selected_model}`;
  `defaultConfigJson(alloc, username, version)` = `configJson` with the catalog
  default model + `onboarded:false` (Task 9 added `selected_model`);
  `modelsKeepPath`; `models_keep_contents`.
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
- **models.zig** — local model management + llama.cpp runtime, PURE (Task 9; extended
  in Task 13). `CatalogModel{id, display_name, blurb, url, file_name, size_bytes,
  sha256, context_length, tier, min_ram_bytes, recommended}` + `catalog` (3 curated
  instruct GGUFs) + `default_model_id` (`qwen2.5-3b-instruct-q4`) + `findModel(id)`.
  Task 13 added the `Tier{premium,balanced,basic}` enum (`.label()`), the RAM/tier/
  recommended fields (Qwen2.5-3B=premium+recommended, Llama-3.2-3B=balanced,
  Qwen2.5-1.5B=basic), `recommendedModelId()`, and the display helpers `formatSize(buf,
  bytes)` (`"3.5 GB"`/`"769 MB"`/`"—"`) + `formatRam(buf, bytes)` (`"Needs N GB RAM"`).
  Path builders (caller-owned bufs):
  `modelFilePath`/`partFilePath` (`<models>/<file>[.part]`). Argv builders (fixed
  `*_argv_len`, caller-owned bufs): `downloadArgv` (`curl -fL --silent --show-error
  --progress-bar --output <part> --url <url> --no-buffer`), `renameArgv`
  (`mv -f <part> <final>` — the SDK has NO rename file effect), `serverArgv`
  (`<bin> -m <model> --host 127.0.0.1 --port <p> -c <ctx> --no-webui`).
  `parseProgress(line)` pulls the trailing `NN.N%` out of a curl bar line → 0..1.
  `resolveServerBinary(env)` = `$BLOCKS_LLAMA_SERVER` else `default_server_binary`
  (`vendor/llama/bin/llama-server`). `parseSelectedModel(json)` reads the config
  `selected_model` via a tiny hand `jsonStringField`. Task 13 added
  `parseOnboarded(json)` (the sibling `jsonBoolField`) reading the `onboarded`
  bool (null when absent -> caller defaults to not-onboarded). All unit-tested.
- **chat.zig** — chat data layer + local-LLM protocol shaping, PURE (Task 10).
  `Role{user,assistant,system}` (`.name`/`.fromName`). CHATS/MESSAGES: `chat_insert_sql`
  (kind='chat', created=updated), `chat_touch_sql` (preview+updated_at), `max_chat_id_sql`
  (`SELECT MAX(id)` — recovers the just-inserted chat id, since the SDK store may run a
  follow-up query on a different pooled connection where `last_insert_rowid()` is 0),
  `messages_by_chat_sql` (ORDER BY seq), `message_insert_sql`; statement builders
  `chatInsertStatement`/`chatTouchStatement`/`messageInsertStatement` (caller-owned
  param bufs). `Message.fromRow`; `MessageEntry` (inline-owned copy: `content`, `roleLabel`
  = You/Blocks/System, `fromMessage`/`set`). `max_content_bytes=8192`, `max_messages=256`.
  LLM PROTOCOL: `system_prompt` (Blocks memory-assistant persona); `buildRequest(out, alloc,
  history []OutMessage, context, stream, max_tokens)` → the `/v1/chat/completions` body
  (system message + optional "Relevant memory:" context block + history, all JSON-escaped
  via a local `JsonWriter`); `parseStreamLine(line, scratch)` → `StreamEvent{delta,done,
  ignore}` (scans a `data:` SSE chunk for `delta.content`, detects `[DONE]`; `unescapeJsonString`
  handles the standard escapes + BMP `\uXXXX`). MCP RAG: `buildSearchRequest(out, alloc,
  query, limit)` → a `tools/call search_memory` JSON-RPC body; `formatSearchContext(out,
  alloc, response_body, max_hits)` unwraps the double-wrapped `result.content[0].text` →
  inner `{results:[{repo,title,snippet}]}` → `"- [repo] title: snippet"` lines (fail-soft:
  0 hits on any parse error, never blocks the chat). `excerptTitle` (chat title/preview).
  SUMMARIES (Task 11): `SummaryKind{day_recap,top_of_mind,standup}` with `.chatKind()`
  (the `chats.kind` value), `.title()`, `.prompt()` (canned instruction), `.lookbackMs()`
  (activity window), `.activityLimit()`; `chat_insert_kind_sql` + `chatInsertKindStatement`
  (`*[4]Value`: title, preview, kind, now) inserts a chat with an EXPLICIT kind;
  `buildActivityRequest(out, alloc, since_ms, limit)` builds a `tools/call get_activity`
  body; `formatActivityContext(out, alloc, response_body, max_rows)` unwraps `get_activity`'s
  double-wrapped result into inner `{activity:[{repo,title,kind}]}` -> `"- [repo]
  commit|edit title"` lines (fail-soft, same as search).
- **repos.zig** — watched-repos data layer. `Repo{id,path,name,active,added_at}`
  `.fromRow(cols)`; `RepoEntry` (owned inline path/name copy) `.fromRepo/.path()/.name()`;
  `insert_sql/delete_sql/list_sql/exists_sql`; `insertStatement(*[3]Value, path, name, now_ms)`,
  `deleteStatement(*[1]Value, id)`; path helpers `normalizePath/defaultName/gitMarkerPath/checkPathShape`.
  `max_repos=128, max_path_bytes=1024, max_name_bytes=256`.
- **snippets.zig** — Materials ("snippets") data layer, PURE (Task 12).
  `Snippet.fromRow(cols[9])` -> `{id,title,content,language,annotation,text_expander,
  origin_chat_id,origin_message_id,updated_at}` (nullable origins decode to 0). TWO
  model-owned copies: `SnippetEntry` = a LIGHTWEIGHT sidebar card (id/title/language/
  `cardBlurb`[160]/updated_at/origins — NO body, so the `[max_snippets=64]` list stays
  small) and `SnippetDetail` = the FULL body of the ONE selected snippet
  (title/content/language/annotation/text_expander); the Model holds one detail loaded
  on demand. `LanguageEntry{name,index,filterIndex}` for the filter menu + typeahead.
  SQL: `list_recent_sql`/`list_alpha_sql` (+ `_by_lang` `?1=lang`), `search_*` LIKE
  variants (`?1=%term%` [+ `?2=lang`]) + `likePattern`, `distinct_langs_sql`, `get_sql`,
  `max_id_sql`, `insert_sql`, `update_sql`, `set_language_sql`, `delete_sql`. Caller-owned
  param builders `insertStatement(*[8]...)` (0 origin -> `null_value`),
  `updateStatement(*[7])`, `setLanguageStatement(*[3])`, `deleteStatement(*[1])`,
  `getParams`/`langFilterParams`. `defaultTitle(content)` (first line / "Untitled snippet").
  Bounds: content 8K, annotation/text_expander 1K, title 200, language 64.
- **tests.zig** — test root: `comptime { _ = @import("config.zig"); ...db, repos... }`
  plus markup-builds and update-arm tests. Run via `native test --yes`.
- **schema/0001_initial_schema.sql** + **schema/migrations.lock.json** — see below.
- **app.native** — the MAIN-window shell (Task 13): a `<if needsOnboarding>` onboarding
  overlay (welcome splash + pick-a-local-model), the main app (`<if onboarded>`) with a
  header (Chat/Materials nav + a Settings button), a Chat screen (sidebar + single-click
  summary cards + transcript + composer), and a Materials screen. (At Task 13 the editor
  sheet + set-language modal were still `<if>`-gated panels; SUPERSEDED post-v1 — the
  editor became a separate OS window and the set-language modal was removed. See "Post-v1
  changes".) The SETTINGS UI is NOT here — it's a
  SEPARATE OS window built in Zig (`window_view`/`windows_fn` in main.zig), because a
  UiApp binds markup to exactly ONE canvas (the main window). The header "Settings"
  button just dispatches `open_settings`.
- **assets/icons/sparkle.svg** (embedded from `src/assets/icons/`) — the welcome-splash
  sparkle, parsed at comptime (`canvas.svg_icon.parseComptime`), registered as
  `app:sparkle` via `pub const app_icons` + `canvas.icons.registerAppIcons(&app_icons)`
  in `main`. The built-in icon set has no sparkle; custom SVGs must live UNDER `src/`
  (the package root) for `@embedFile` to reach them.

## Database schema (schema/0001_initial_schema.sql + 0002_snippets_text_expander.sql, user_version 2)

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
- `snippets(id, title, content, language, annotation, text_expander, origin_chat_id
  FK SET NULL, origin_message_id FK SET NULL, created_at, updated_at)` — `text_expander`
  added by migration `0002` (Task 12).
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
Task 12 added the FIRST follow-on migration (`0002`): `ALTER TABLE snippets ADD
COLUMN text_expander TEXT NOT NULL DEFAULT ''` (a constant default keeps the ALTER
legal on the STRICT table). Each `NNNN_*.sql` must ALSO be added to the `migrations`
array in `db.zig` (embedded for tests); `native test` regenerates `migrations.lock.json`
(now 2 hashes + a new schema_hash).

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
     fetch), 170-175 (Task 9: 170 config read, 171 model stat, 172 model download
     curl, 173 model rename mv, 174 llama-server spawn, 175 llama /health fetch),
     180-185 (Task 10: 180 MCP search_memory POST, 181 llama chat `.stream` POST,
     182 chat INSERT, 183 chat MAX(id) query, 184 messages write batch, 185 messages
     reload query), 186 (Task 11: MCP get_activity POST for a summary's context),
     200 (Task 13: rewrite config.json for a model change / onboarding completion
     — SEPARATE from the first-run 101 so it never re-runs the first-run arm),
     190-198 (Task 12 materials: 190 snippets list, 191 distinct languages, 192
     snippet INSERT, 193 snippet MAX(id), 194 update, 195 set-language, 196 delete,
     197 writeClipboard, 198 selected-snippet detail get).
     TIMER keys (own namespace): 1 = the repeating working-tree scan
     tick, 2 = the one-shot MCP health-check delay, 3 = the one-shot llama health delay.
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
- **Health-check retry/backoff**: RESOLVED in Task 11 — the single 400 ms check used
  to leave `mcp_ready` false forever on a bind race (silently disabling ALL
  retrieval); the check now retries on a fixed backoff up to a cap (see the Task 11
  verification section). Still open: surface `mcp_ready`/`mcp_failed` in the UI and
  restart the child if it dies (`mcp_exit`).
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

## Task 9 — Local model management + llama.cpp runtime (DONE — what was built)

Blocks now manages the LOCAL chat model end-to-end: a curated download catalog,
a selection persisted in `config.json`, a resumable-into-place download, and a
spawned `llama-server` runtime that serves an OpenAI-compatible API on loopback
(the same "spawned child + fetch client" shape as the MCP server, since the SDK
has no in-process HTTP listener). Task 10 wires the chat UI to this runtime.

**KEY DECISIONS (read before Task 10):**
- **Why subprocesses for BOTH download and runtime (SDK constraints):** the
  `fetch` effect buffers at most `max_effect_body_bytes` = **256 KiB** and its
  `.stream` mode is LINE-framed text — so it CANNOT pull a multi-hundred-MB GGUF.
  We DOWNLOAD via a spawned **`curl`** (`/usr/bin/curl`, present on macOS; proven
  in the spike) in `.lines` mode so its `--progress-bar` meter streams to the app.
  For the RUNTIME, there is no in-process socket-listen effect (locked since Task
  8), so the llama.cpp runtime is a spawned **`llama-server`** the app reaches over
  HTTP with `fetch` and health-checks at `GET /health`.
- **No rename file effect exists** (`EffectFileOp` = read/write/append/stat/delete
  only). So curl writes to `<file>.gguf.part` and, ONLY on a clean curl exit, a
  spawned **`mv -f <part> <final>`** moves it atomically into place — an aborted or
  failed download never appears as a complete model.
- **The embedder stays `hash-v1` (Task 7).** Task 9 stands up the CHAT runtime, not
  a neural embedder. Swapping embeddings to llama.cpp is still the documented Task 7
  follow-up (register under a new `model` id; the schema already allows coexistence).
- **Catalog + selection.** `models.catalog` is a small curated set of instruct
  GGUFs (Qwen2.5 3B / Llama-3.2 3B / Qwen2.5 1.5B), default `qwen2.5-3b-instruct-q4`.
  The chosen id lives in `config.json` `selected_model` and is re-read on boot.
- **llama-server binary path.** `resolveServerBinary` prefers `$BLOCKS_LLAMA_SERVER`
  (dev override / packaged env) else `vendor/llama/bin/llama-server` (relative to the
  app cwd, same convention as the MCP child under `native dev`). If the binary is
  ABSENT the spawn fails with `.spawn_failed` → `llama_failed = true`, NON-FATAL: the
  app runs; Task 10's chat surfaces "runtime unavailable" and offers a retry.

Layering: ALL logic is PURE + unit-tested in `models.zig` (catalog, path/argv
builders, `parseProgress`, `parseSelectedModel`); only the effect firing lives in
`main.zig`.

Boot + lifecycle (`main.zig`, keys 170-175, timer key 3, `llama_port = 39018`):
1. Returning user (`stat_config` exists) → `readConfig` reads `config.json` →
   `config_read_done` adopts `selected_model` (falls back to the catalog default) →
   `statSelectedModel`. First run (`wrote_config`) writes the default-model config,
   then `statSelectedModel`.
2. `model_stat_done` sets `model_present`. If present → `startLlama`.
3. `startLlama` (once) spawns `llama-server -m <gguf> --host 127.0.0.1 --port 39018
   -c <ctx> --no-webui` (`.collect`; an exit → `llama_exit` → `llama_failed`,
   non-fatal), then arms a one-shot `llama_health_delay_ms = 1500` timer (model load
   is slower than a socket bind) → `llama_health_tick` → `healthCheckLlama` GETs
   `/health`; a 200 → `llama_ready`.
4. Download flow (user presses Download in the Local-model section): `startDownload`
   spawns `curl … --output <part> --url <url>` in `.lines` mode →
   `download_progress_line` runs `parseProgress` into `download_progress` (0..1) →
   `download_done`: on a clean exit spawns `mv` → `model_renamed`: on success sets
   `model_present` and calls `startLlama`; any failure sets `download_failed`.
5. `select_model:<idx>` switches the selection, rewrites `config.json`
   (`persistSelectedModel` via `bootstrap.configJson`), clears presence/progress, and
   re-stats the newly selected model.

Model state added: `selected_model_buf/len` (+ `selectedModel`), `model_present`,
`downloading`, `download_progress`, `download_failed`, `llama_started/ready/failed`,
`model_choices[catalog.len]` (rebuilt by `refreshModelChoices`). View accessors:
`modelChoices`, `selectedModelName`, `modelStatusText`, `downloadPercent`,
`canDownload`. Msg arms: `config_read_done`, `model_stat_done`, `download_model`,
`select_model`, `download_progress_line`, `download_done`, `model_renamed`,
`llama_exit`, `llama_health_tick`, `llama_health_done`.

View (`app.native`): a "Local model" section — a `<for each="modelChoices">` list
(each row: name + blurb, a "Selected" marker, a Choose button →
`select_model:{index}`), a `{modelStatusText}` line, and a Download button (shown
when `canDownload`) → `download_model`. The full model-picker mockup lands with the
chat (Task 10) / settings modal (Task 13); this is enough to drive the flow now.

Tests (123 total pass, was 100): `models.zig` unit tests (catalog lookup, path +
argv builders, `parseProgress` incl. multi-percent + clamp + null, `resolveServer
Binary` env precedence, `parseSelectedModel` present/absent), `bootstrap.zig` config
round-trip (default + chosen model), and `main.zig` update-arm tests via the fake
executor (config adoption, model present/absent, select + out-of-range, a curl
progress line → `downloadPercent`, failed download/rename, `/health` 200 → ready,
child exit → failed non-fatal, rejected health tick ignored, and the health
retry/backoff arms — retry under the cap, give-up at the cap, attempt counter).
`native check` is clean (`app.native: ok`, app.json valid; the only warnings —
`hasRepos`, `statusText`, `repo_input` — pre-date Task 9).

**VERIFIED END-TO-END via automation** (post-commit, on this machine): installed
`llama-server` (`brew install llama.cpp`, v0.4.1) and set `$BLOCKS_LLAMA_SERVER=
/opt/homebrew/bin/llama-server`. First, a STANDALONE smoke test confirmed the
catalog URL resolves, the exact `downloadArgv` curl + `mv` produce a valid GGUF, and
the exact `serverArgv` starts a server whose `GET /health` → 200 `{"status":"ok"}`
and `POST /v1/chat/completions` returns a real completion (buffered AND SSE
`data:`-framed streaming + `[DONE]`). Then a full FIRST-RUN app run (`native dev
--yes -Dautomation=true`, config + model deleted first): the app wrote fresh config
(default 3B selected), the Local-model picker rendered, clicking Choose on the 1.5B
row persisted `selected_model` to `config.json`, clicking Download spawned curl (a
`.part` appeared, status → "Downloading model…"), the app `mv`d it to the final
`.gguf`, spawned `llama-server` with the expected argv, and after the health
retries the status reached **"Model ready."** — and a `curl` to the app-spawned
runtime answered a real chat completion. The downloaded 1.5B GGUF was LEFT in the
app data dir as the real model for Task 10.

**Fix that fell out of the live run (in this same change):** the first health check
fired at 1.5 s but a cold GGUF load takes ~10-30 s, so the single check missed and
`llama_ready` never flipped. `main.zig` now RETRIES `/health` on a fixed
`llama_health_retry_ms = 1500` backoff up to `llama_health_max_attempts = 40`
(~60 s grace), tracked by `llama_health_attempts` (reset each `startLlama`); only
after the cap is `llama_failed` set. Verified: the status now reaches "Model ready."

### Deferred / follow-ups
- **Bundling `llama-server` + Metal.** v1 expects the binary on `PATH`/env or vendored;
  packaging (Task 13) must ship a Metal-enabled `llama-server` (and its `.metallib`)
  in the bundle and resolve its path (same bundle-exe-dir gap noted for the MCP child).
- **Download integrity.** `sha256` is empty in the catalog for v1 (curl `-f` + the
  post-download presence/size are the guard). Pin real digests and verify with a
  spawned `shasum -a 256` before the `mv` when we lock exact catalog builds. Also:
  no resume (`curl -C -`), no cancel button (wire `fx.cancel(key_model_download)`),
  and `download_progress` is fraction-only (no bytes/ETA) — all easy follow-ups.
- **Runtime supervision.** Health-check retry/backoff is now DONE (see above). Still
  open: a crashed `llama-server` sets `llama_failed` but is not auto-restarted, and
  `llama_started` latches (selecting a new model persists + re-stats but does NOT
  re-spawn the runtime for it without a relaunch). Task 10 should add crash-restart
  and re-spawn on `select_model` (stop the old child, spawn the new model).
- **Model deletion / disk management.** No UI to delete a downloaded GGUF or show
  disk usage yet (Settings, Task 13).
- **Chat wiring (Task 10).** The OpenAI-compatible endpoint is up but nothing calls
  `/v1/chat/completions` yet; streaming tokens back into the chat view + injecting the
  MCP memory tools is Task 10.

## Task 10 — Chat experience wired to model + MCP (DONE — what was built)

The user can now chat with the LOCAL model, and its answers are grounded in the
developer's own git/file memory. The chat POSTs to the llama.cpp runtime's
OpenAI-compatible `/v1/chat/completions` (streamed, SSE), and BEFORE each turn the
app queries the MCP `search_memory` tool with the user's message and injects the top
hits as context. Conversations persist to the `chats`/`messages` tables.

**KEY DECISION — retrieval-augmented generation, NOT native tool-calling (read before
Task 11).** llama-server exposes OpenAI `tools`/`tool_calls`, but a 1.5-3B local model
calls tools unreliably. So instead of a model-driven tool loop, the app does RAG: it
always calls `search_memory(query = the user's message)` first and injects the ranked
hits into the system message as a "Relevant memory:" block, then asks the model. This
is deterministic, works with a small model, and still exercises the Task 8 MCP tools.
Native tool-calling (letting the model choose `get_commits`/`get_activity` too) is a
documented follow-up. Retrieval is BEST-EFFORT: if the MCP server isn't ready or the
search fails, the turn proceeds with no context (the chat never blocks on memory).

Layering: all protocol/SQL shaping is PURE + unit-tested in `chat.zig`; only the effect
firing + turn state machine live in `main.zig`.

**The turn lifecycle** (`main.zig`; effect keys 180-185):
1. `send_chat` (guarded by `canSend` = `llama_ready and !sending`, and non-empty input):
   copy the input to `pending_user_buf`, optimistically `pushMessage(.user)` for instant
   display, clear the field, set `sending = true`, `finalizing = false`.
2. If `mcp_ready`: `searchMemory` POSTs `buildSearchRequest` to the MCP root (key 180);
   `mcp_search_done` runs `formatSearchContext` into `context_buf` (best-effort) →
   `startCompletion`. If MCP isn't ready, `sendChat` calls `startCompletion` directly.
3. `startCompletion` builds the request from the loaded history + context and opens a
   `.stream` fetch (key 181) — `on_line = chat_line`, `on_response = chat_done`.
4. `chat_line` runs `parseStreamLine` and appends each `delta.content` token to
   `streaming_buf` (shown live via the `isStreaming` bubble).
5. `finalizeChat` runs on the `[DONE]` sentinel (see the finalization note) — pushes the
   assistant message, then persists: a NEW chat does `createChatThenPersist` (INSERT chat
   key 182 → `chat_rowid_done` reads `MAX(id)` key 183 → `persistTurn`); an existing chat
   goes straight to `persistTurn` (key 184: user msg + assistant msg + chat touch in ONE
   exec batch). `chat_write_done` clears `sending`, then reloads the chat (key 185) so
   ids/seqs are authoritative.

**FINALIZATION — why we finalize on `[DONE]`, not the terminal response (important
SDK/llama-server detail).** llama-server keeps the HTTP connection OPEN (keep-alive)
AFTER it emits the reply + `data: [DONE]`, so the `.stream` fetch's terminal
`on_response` (`chat_done`) lags by the WHOLE `chat_stream_timeout_ms` (120 s). The
reliable end-of-turn signal is the `data: [DONE]` LINE, which arrives promptly. So
`chat_line` finalizes on the `[DONE]` `StreamEvent`, and `finalizeChat` does
`fx.cancel(key_llama_chat)` to tear down the held-open fetch (which then delivers a
`.cancelled` `chat_done`). `finalizeChat` is IDEMPOTENT via a `finalizing` guard, so the
follow-up `chat_done` is a no-op. A transport failure that lands as `chat_done` with a
non-`ok` outcome (no `[DONE]`) also finalizes, with `ok=false`: it keeps the user's
message visible and surfaces an error. (An earlier idle-timer watchdog approach was
tried and REMOVED once the `[DONE]` path proved reliable — no dead code.)

**Persisting the new chat's id — `MAX(id)`, not `last_insert_rowid()`.** The `.exec`
result carries no rowid, and a follow-up `SELECT last_insert_rowid()` returned 0 in
practice (the SDK relational store ran it on a DIFFERENT pooled connection where no
insert had happened — confirmed live). Since Blocks is the SOLE writer and rows aren't
deleted mid-turn, `SELECT MAX(id) FROM chats` recovers the just-inserted id. This is
safe ONLY if turns don't overlap — see the race fix below. `next_seq` is tracked
in-model but is authoritatively recomputed from `MAX(seq)+1` on every reload.

Model state added: `chat_input` (TextBuffer 2048), `current_chat_id`, `next_seq`,
`messages[256]MessageEntry` + `message_count`, `pending_user_buf`, `streaming_buf` +
`streaming_len`, `context_buf` + `context_len`, `sending`, `finalizing`, `streaming`,
`chat_error`. View accessors: `messagesSlice`, `streamingText`, `isStreaming`,
`canSend`/`sendDisabled`, `chatStatusText`, `chatEmpty`. Msg arms: `chat_input_edit`,
`send_chat`, `mcp_search_done`, `chat_line`, `chat_done`, `chat_inserted`,
`chat_rowid_done`, `chat_write_done`, `messages_listed`.

View (`app.native`): chat is now the PRIMARY screen — a scroll transcript
(`<for each="messagesSlice">` role-labeled bubbles + the live `isStreaming` bubble), a
`chatStatusText` line, and the input row (text-field + Send, `disabled="{sendDisabled}"`).
The Task 3 Watched Repositories + Task 9 Local model sections remain BELOW (they move into
the Settings modal in Task 13). This is a FUNCTIONAL demo layout; the high-fidelity
`chat_screen.png` (sidebar + chat list, single-click summary cards, message bubbles,
Save-to-Snippets) is Task 13 polish, once its dependencies (Task 11 summaries, Task 12
snippets) exist. (User confirmed this sequencing — "Option A".)

**Allocator discipline:** per-turn request/response JSON is built in SHORT-LIVED arenas
(`ArenaAllocator(page_allocator)` with `defer deinit` in `startCompletion`/`mcpSearchDone`,
a stack `FixedBufferAllocator` in `searchMemory`) — `fx.fetch` copies the body at call
time, so nothing accumulates across turns. (An earlier version used the process-lifetime
`boot_arena` for these — a real per-turn leak, and it crashed tests where `boot_arena`
is uninitialized; fixed.)

Tests (148 total): the pure `chat.zig` layer (Role, statement params, `MessageEntry`,
`buildRequest` with/without context + JSON validity, `parseStreamLine` delta/DONE/role-
only/blank/escapes, `buildSearchRequest`, `formatSearchContext` happy + malformed,
`excerptTitle`, `Message.fromRow`) + `main.zig` update-arm tests (send gating when not
ready, optimistic display, empty-input, streamed append, ignore-when-not-streaming,
`[DONE]` finalize, failed `chat_done`, `mcp_search_done` → stream, turn stays gated
through persistence, second-finalize no-op). `native check` clean (0 warnings).

**VERIFIED END-TO-END via automation** (`native dev -Dautomation=true` +
`BLOCKS_LLAMA_SERVER`, real Qwen2.5-1.5B): added this repo (→ 11 commit events, embeddings),
then chatted. "What did I most recently work on?" → a streamed reply grounded in the real
Task 6 commit ("Always-on tray + auto-start on login… resolved the 'tray needs Runtime
access' concern"), persisted as `chats`(1 row) + `messages`(user seq 0, assistant seq 1),
and the status returned to idle. A LONG reply (detailed task-by-task summary, 2609 chars)
streamed fully, finalized on `[DONE]`, and persisted intact — no stall on longer
generation. A post-fix run confirmed exactly ONE chat row per new conversation (no
duplicate from the race fix).

### Semantic review + the turn-overlap race fix
A behavioral review (semantic-review/2026-09-18-…-pr-task10-chat.md) caught a BLOCKER:
`finalizeChat` originally cleared `sending` BEFORE the async persist chain adopted
`current_chat_id`, so a fast second `send_chat` on a brand-new chat could create a second
`chats` row and race the `MAX(id)` recovery → both turns adopt the same id with colliding
`seq`s (and `messages` has no `UNIQUE(chat_id, seq)`, so SQLite accepts the dupes).
FIXED: idempotency now uses a dedicated `finalizing` flag, and `sending` stays SET through
the ENTIRE persist chain (cleared only in `chat_write_done`, or on the finalize failure
path) — so `canSend` keeps a second turn from overlapping the id recovery. Also fixed from
the review: clear `context_len` on the failure path (no stale memory leaking into a later
turn), dropped a redundant in-model `next_seq += 2` (the reload is authoritative), surfaced
a chat error if the id recovery yields nothing (instead of silently dropping the write),
and sized the search scratch for worst-case JSON escaping so retrieval is never silently
skipped.

### Deferred / follow-ups
- **Native tool-calling.** v1 is RAG-only (always `search_memory`). Letting the model
  drive `get_commits`/`get_activity`/`search_memory` via OpenAI `tool_calls` is a
  follow-up — worthwhile once a stronger model is the default (it needs a tool-call loop:
  model → tool request → app runs the MCP tool → feed the result back → continue).
- **Chat sidebar / history.** v1 starts a FRESH chat each session (a row is created on the
  first send); prior chats accumulate in the DB but there is no "New chat" button or chat
  list to switch between them yet. The `chat_screen.png` sidebar is Task 13.
- **Single-click summaries (Task 11).** The chat mockup's Day Recap / What's Top of Mind /
  Standup cards are Task 11 — they reuse this same runtime + MCP plumbing with canned
  prompts and a `chats.kind` other than 'chat'.
- **Save-to-Snippets (Task 12).** The "Save to Snippets" affordance in the mockup + the
  `snippets.origin_chat_id/origin_message_id` cross-link is Task 12.
- **8 KiB reply cap.** A streamed reply longer than `max_content_bytes` (8 KiB) is
  displayed + persisted TRUNCATED with no marker. Fine for v1 (the long-reply test was
  2.6 KiB); add a visible indicator or a larger stored cap later.
- **Runtime not ready / offline.** If `llama_ready` is false the composer's Send is
  disabled and `chatStatusText` shows the model status; there's no explicit "start the
  model" affordance in the chat area yet (the Local model section below handles download).
- **High-fidelity chat UI (Task 13).** The faithful `chat_screen.png` layout (bubbles,
  avatars, sidebar, summary cards) lands in Task 13 once Tasks 11/12 exist.

## Task 11 — Single-click summaries (DONE — what was built)

The chat mockup's three summary cards now work: **Day Recap**, **What's Top of
Mind**, and **Standup Update**. Each is a ONE-CLICK canned "turn" that pulls the
developer's RECENT ACTIVITY from the MCP `get_activity` tool, injects it as
context, and asks the local model to write the summary with a fixed instruction —
saved as a chat with its own `chats.kind`.

**KEY DECISION — a summary is a canned chat turn, reusing the Task 10 machinery.**
Rather than a parallel code path, a summary is modeled as an ordinary turn whose
"user message" is a fixed prompt (`SummaryKind.prompt()`). It reuses the exact Task
10 pipeline — `startCompletion` (stream) -> `chat_line` tokens -> `finalizeChat`
on `[DONE]` -> `createChatThenPersist`/`persistTurn`. Only two things differ:
- **Retrieval source.** A normal chat retrieves with `search_memory` (semantic,
  keyed on the typed question). A summary retrieves with **`get_activity`** — a
  time-windowed union of commits ∪ file snapshots (newest first) — because "what
  did I do recently" is a RANGE query, not a similarity query. The window comes
  from `SummaryKind.lookbackMs()` (1 day for recap/standup, 3 days for
  top-of-mind), computed as `now - lookback` and passed as `since_ms`.
- **The chat's kind + title.** A summary always starts a FRESH chat, INSERTed with
  its `chats.kind` (`day_recap`|`top_of_mind`|`standup`) and a fixed title via the
  new `chat.chatInsertKindStatement` (the ordinary path still uses the kind='chat'
  `chatInsertStatement`). The schema already allowed these kinds (Task 2).

Retrieval is BEST-EFFORT, exactly like Task 10: if the MCP server isn't ready or
`get_activity` fails, the summary proceeds with no injected context (the model then
says it has nothing recent). The turn never blocks on memory.

Layering: all protocol/SQL shaping is PURE + unit-tested in `chat.zig`; only the
effect firing + the per-turn state live in `main.zig`.

**The summary lifecycle** (`main.zig`; effect key 186 for the activity POST, then
the shared 181-185 chat keys):
1. `start_summary(kind)` (a card tap; guarded by `canSend` = `llama_ready and
   !sending`): reset the active chat (`current_chat_id=0`, `next_seq=0`,
   `message_count=0`), set `pending_summary_kind=kind`, `setPendingUser(kind.prompt())`,
   `pushMessage(.user, prompt)` for instant display, set `sending=true`.
2. If `mcp_ready`: `retrieveActivity` POSTs `buildActivityRequest(since_ms, limit)`
   to the MCP root (key 186); `mcp_activity_done` runs `formatActivityContext` into
   `context_buf` (best-effort) -> `startCompletion`. If MCP isn't ready,
   `startCompletion` runs directly.
3. From here it's the Task 10 path verbatim: stream tokens, finalize on `[DONE]`,
   then `createChatThenPersist` — which now branches on `pending_summary_kind` to
   INSERT the kind-tagged chat — `chat_rowid_done` -> `persistTurn` (user prompt +
   assistant summary + chat touch) -> `chat_write_done` clears `sending` AND
   `pending_summary_kind`, then reloads the chat.

`pending_summary_kind` is the summary's interlock: it is cleared on EVERY turn-end
path (success in `chat_write_done`, the finalize failure path, the `persistTurn`
id-recovery failure, and the `chat_inserted` failure — which now also clears
`sending`, closing a latent stuck-`sending` gap), and set to null at the start of
an ordinary `sendChat` so a chat turn never inherits a stale kind.

Model state added: `pending_summary_kind: ?chat.SummaryKind`. View: `summaryCards`
(a `[3]SummaryCard{tag,label,blurb}` where `tag = @tagName(kind)`), `summaryDisabled`
(= `!canSend`). `chatStatusText` now reads "Gathering your recent activity…" /
"Writing your summary…" while a summary is in flight. Msg arms: `start_summary:
chat.SummaryKind` (markup-bound) and `mcp_activity_done` (effect-delivered).

View (`app.native`): a `<row>` of `<for each="summaryCards">` buttons above the
transcript — `<button variant="secondary" on-press="start_summary:{c.tag}"
disabled="{summaryDisabled}">{c.label}</button>`.

**SDK note — passing an ENUM as a message payload from markup.** `on-press=
"start_summary:{c.tag}"` works because the markup engine's payload `coerce` for an
enum field does `std.meta.stringToEnum(EnumType, value.string)` (confirmed in the
CLI's `ui_markup_view.zig`). So the payload binding must resolve to a STRING equal
to the tag name — hence `SummaryCard.tag = @tagName(SummaryKind.<x>)`. (Contrast
the Task 9 `select_model:{m.index}` which coerces a binding integer to `usize`.)

Tests (159 total, was 148): pure `chat.zig` tests (SummaryKind kinds/titles/prompts/
windows, `chatInsertKindStatement` params, `buildActivityRequest` shape + JSON
validity, `formatActivityContext` happy + malformed) + `main.zig` update-arm tests
(start_summary gated when the runtime isn't ready; a canned turn shows the prompt +
streams; a summary resets any prior conversation; a second card tap is ignored while
one is in flight; `mcp_activity_done` -> stream; a summary finalizes + stays gated
until `chat_write_done`, which releases the kind). `native check` clean (markup
validated against the refreshed model contract, 0 warnings).

### VERIFIED END-TO-END via automation (+ two bugs found and fixed live)
Driven live (`native dev --yes -Dautomation=true` with `BLOCKS_LLAMA_SERVER`, real
Qwen2.5-1.5B, this repo already watched). All four criteria confirmed: (a) each of
the three cards streams a summary GROUNDED in the injected `get_activity` context
(the replies referenced the real `src/*.zig` edits; the standup used its
"Yesterday/Today/Blockers" framing); (b) each persists a `chats` row with the right
`kind` (`day_recap`/`top_of_mind`/`standup`) + title, and `messages` (user seq 0 =
the canned prompt, assistant seq 1 = the summary), preview filled from the reply;
(c) mid-turn all three cards read `enabled=false` with the status "Writing your
summary...", and re-enable after; (d) the empty-activity path degrades to a plain
"no recent activity" reply. Test rows cleared from `app.db` afterward.

**Two bugs the live run surfaced (both fixed in this change; +3 regression tests):**
1. **MCP `mcp_ready` never flipped -> ALL retrieval silently skipped.** The Task 8
   MCP health check was a SINGLE shot 400 ms after spawn; it raced the child's
   `listen()` and, on a miss, left `mcp_ready` false forever -- so BOTH Task 10's
   `search_memory` and Task 11's `get_activity` were skipped and every reply was
   ungrounded ("you have not provided recent activity"). This was the documented
   Task 8 fragility finally biting. FIX: the MCP health check now RETRIES on a fixed
   backoff (`mcp_health_retry_ms = 500`, up to `mcp_health_max_attempts = 20`,
   tracked by `mcp_health_attempts`, via a new `armMcpHealth` helper reset in
   `startMcpServer`) -- mirroring the llama health check (Task 9). `mcp_failed` is set
   only after the cap. This hardening benefits Task 10's chat RAG too.
2. **`retrieveActivity` request buffer too small -> context dropped.** The
   `get_activity` request body was built into a 256-byte `FixedBufferAllocator`;
   `std.ArrayList`'s growth overflowed it, so `buildActivityRequest` errored and the
   `catch` fell through to `startCompletion` with NO context (`context_len = 0`) --
   even though MCP was healthy. Diagnosed by temporary logging that showed
   `startSummary mcp_ready=true` immediately followed by `startCompletion
   context_len=0` with no `mcpActivityDone`. FIX: bumped the scratch buffer to 1024
   bytes. (Task 10's `searchMemory` was never affected -- it already sizes its buffer
   for worst-case escaping, ~49 KiB.)

After both fixes a clean run passed all four criteria above; 161 tests green;
`native check` clean.

### Deferred / follow-ups
- **Activity context de-duplication.** The injected context is one line PER activity
  row, so a file edited repeatedly (e.g. `src/main.zig`) appears many times and the
  summary parrots the repetition. De-dup by path (keep the newest) and/or fold
  counts ("edited src/main.zig x7") before injecting — surfaced by the live run.
- **Activity → prompt richness.** The injected context is one line per activity row
  (`- [repo] commit|edit <title>`); it omits diffs/bodies and the timestamp (a
  `occurred_at` prefix like "2h ago" is parsed-but-unused, reserved for later). The
  `get_activity` window is a fixed lookback, not "since your last summary."
- **Summary history / sidebar.** Summaries persist as their own `chats.kind` but
  there is still no chat list to revisit them (the `chat_screen.png` sidebar is Task
  13). A "regenerate" affordance and per-repo scoping are later polish.
- **Standup date framing.** The standup prompt says "Yesterday/Today" but the window
  is a rolling 24h, not calendar-aware; a real "since yesterday 9am" bound is a
  follow-up once we track summary runs.
- **Model quality.** Same 8 KiB reply cap and small-model caveats as Task 10 apply.

## Task 12 — Materials (snippets) screen + chat cross-linking (DONE — what was built)

> SUPERSEDED (UI only): this section describes the editor as an inline `<if>`-gated
> "editor sheet" and a separate "set-language modal" — accurate at Task 12 time. Post-v1
> the editor became a SEPARATE OS window (`editorWindowView`) and the set-language modal
> was REMOVED (language is edited in the editor). The data layer / SQL / cross-linking
> below is unchanged. See "Post-v1 changes" at the end of this file.

The "Materials" screen from the mockup is live: the user keeps saved code snippets
("materials"), each with a language tag, a free-form annotation, and a "text
expander" note, and can search/sort/filter them, copy them to the clipboard, save
one from a chat message, and start a fresh chat about one.

**Schema change (first follow-on migration).** The mockup's "All Context" panel has
TWO fields — Annotations (already in the schema) and **Text Expander** (new). Migration
`0002_snippets_text_expander.sql` adds `text_expander TEXT NOT NULL DEFAULT ''` to
`snippets`; the runner auto-applies it on launch (a live `app.db` goes user_version
1 -> 2 automatically). Registered in `db.zig`'s `migrations` array; `migrations.lock.json`
regenerated to 2 hashes.

**KEY DESIGN DECISION — split the model copy into a list CARD + one DETAIL (avoids a
multi-MB Model).** The Model is returned by value from `initialModel()` (tests call it
directly), so a `[max_snippets]` array each holding a full snippet body blows the test
thread's stack (discovered live: SIGABRT in `initialModel`). So `snippets.zig` has TWO
types: `SnippetEntry` — a lightweight sidebar card (id/title/language/short blurb/
origins, no body) held in the `[64]` list — and `SnippetDetail` — the FULL body of the
ONE selected snippet, loaded on demand via `get_sql` (key 198) into a single
`selected_detail`. The detail accessors gate on `selected_detail.id == selected_snippet_id`
so a stale detail never shows.

**Data layer (`snippets.zig`, PURE).** See the source-layout entry above. Mirrors
`repos.zig`: `*_sql` consts, caller-owned `*[N]db.Value` param builders (lifetime trap),
`fromRow` decoders, and a real in-memory-DB integration test (insert/list/filter/update/
delete round-trip + an FK `ON DELETE SET NULL` test proving a deleted origin chat nulls
`snippets.origin_chat_id` while the snippet survives).

**Wiring (`main.zig`).** Effect keys 190-198 (see the keys note). A `Screen` enum
(`chat` | `materials`) + `show_chat`/`show_materials` gives a minimal top-level nav so
the two screens don't stack. Materials state: the `[64]` card list + `[64]` languages,
`selected_snippet_id` + `selected_detail`, `snippet_sort` (recent/alphabetical), a
language filter (`""` = All), a `snippet_search` field, transient sort/lang menu-open
flags, an editor sheet (title/content/language/annotation/text_expander `TextBuffer`s
+ `editing_id`), and a set-language modal (`lang_modal_input` + `lang_modal_id`). Boot
loads snippets + languages after `repos_listed` `.done`. Writes go INSERT (-> `MAX(id)`
recovery, same trick as chats) / UPDATE / DELETE / set-language, each followed by a
list + languages + detail reload; a `snippet_writing` interlock guards the id recovery.
Search is server-side (LIKE) and reloads on each keystroke.

**Language controls (per the user's clarification).** The sidebar's `{}`-style control
is a LANGUAGE FILTER menu: "All" first, then the distinct languages the user actually
has (`distinct_langs_sql`). The main-panel `{}` control is a SET-LANGUAGE MODAL — a
free-text field (there are too many languages to list), with typeahead SUGGESTIONS
drawn from the same distinct-languages set. The right-rail "duplicate"-looking icon is
a COPY action: `fx.writeClipboard` puts the whole snippet on the system pasteboard.

**Cross-linking.** Each chat message has a "Save to Snippets" affordance
(`save_to_snippets:{index}`) that inserts a snippet from that message with
`origin_chat_id`/`origin_message_id` set (the FK back-link). "Start Copilot Chat" on a
selected snippet seeds the chat input with a prompt about it and sends it through the
Task 10 chat path (persists + streams).

**View (`app.native`).** Restructured into the `Screen` nav + two `<if>`-gated screens.
Functional-demo layout; the high-fidelity mockup (floating +, right-rail icon buttons,
avatars, "saved N ago") is Task 13. Menus/modals are `<if>`-gated panels (not native
`<dialog>`/`<dropdown-menu>`) so their open state is plain, testable Model state.

Tests (184 total, was 161 at end of Task 11): pure `snippets.zig` (row decode incl null
origins, card vs detail copies, all statement builders, `defaultTitle`, `likePattern`) +
two real-DB integration tests + `db.zig` migration-0002 column test + `main.zig`
update-arm tests (select, sort toggle, language filter/All, new-editor, save gating,
clipboard status, lang-modal open + typeahead pick, save-to-snippets insert + out-of-
range guard, start-copilot-chat gated/seeded). `native check` clean (0 warnings).

### SDK markup learnings (Task 12)
- **`on-*` payloads must be a `{binding}`, never a literal.** `set_sort:0` /
  `switch_screen:chat` are REJECTED at check time. Use distinct void Msgs for fixed
  choices (`show_chat`/`show_materials`, `sort_recent`/`sort_alphabetical`,
  `clear_lang_filter`); binding payloads from iterated items are fine
  (`select_snippet:{s.id}`, `set_lang_filter:{l.filterIndex}`, `save_to_snippets:{msg.index}`).
  Iterated items therefore need explicit index fields (`MessageEntry.index`,
  `LanguageEntry.index`/`filterIndex`).
- **`<code>` takes its content via `source="{binding}"` (NO text children); `language`
  must be a LITERAL known name (a binding is rejected) so it's omitted here;
  `line-numbers`/`editable`/`on-input` are supported** (the editable code editor renders
  as a textbox).

### VERIFIED END-TO-END via automation (+ one bug found and fixed)
Driven live (`native dev --yes -Dautomation=true` with `BLOCKS_LLAMA_SERVER`, real
Qwen2.5-1.5B). Confirmed: migration auto-applied user_version 1 -> 2 on launch; the
Materials tab renders (empty state); **+ New -> Save** created a snippet PERSISTED WITH
`text_expander` (verified in `app.db`); the detail panel showed the code body + All
Context (Annotations + Text Expander); **Edit** pre-filled the form and updated (title
changed, language preserved); **Delete** removed it and returned to the empty state;
**Copy** wrote the REAL macOS clipboard (`pbpaste` confirmed the content); the
**set-language modal** opened with a "python" typeahead suggestion and a free-typed
"dockerfile" persisted; **Start Copilot Chat** seeded a snippet-referencing prompt and
streamed a real grounded reply, persisted as a new chat.

**Bug found + fixed live:** after creating a snippet, `snippetRowidDone` set the
selection but never loaded its detail, so the panel stayed on "Select a material". Fixed
by loading the detail in `snippetRowidDone`'s terminal `.done`.

**Not click-verifiable via the automation harness (NOT a logic bug):** the
"Save to Snippets" buttons live INSIDE the `<scroll>` transcript, and `native automate
widget-click` synthesizes a pointer at the widget point that doesn't dispatch for
scroll-clipped children (every non-scroll button clicked fine). The Save-to-Snippets +
Start-Copilot-Chat LOGIC is proven by update-arm tests instead.

### Deferred / follow-ups
- **Save-to-Snippets manual check.** Automation can't click it (scroll-clip harness
  limit); confirm by hand, or move the affordance out of the scroll in Task 13's
  high-fidelity chat layout.
- **High-fidelity Materials UI (Task 13).** The faithful mockup — floating "+", right-
  rail icon buttons (edit/copy/delete), "saved N ago", avatars, real menu surfaces —
  lands in Task 13. The current layout also overflows the window vertically (~108 px)
  because the functional demo stacks sections; Task 13's screen split resolves it.
- **Snippet embeddings.** `snippets` are not embedded into `embeddings`/`memory_fts`
  yet (the `source_kind='snippet'` slot exists), so materials aren't in semantic search
  / MCP `search_memory`. Wire a snippet embed pass when useful.
- **LIKE escaping.** `likePattern` treats the term as plain text (no `%`/`_` escaping);
  add an `ESCAPE` clause if literal wildcards in a search term ever matter.
- **Saved-time + counts.** The sidebar shows a `N`/count badge but not per-snippet
  "saved N ago"; the language filter badge shows the active filter. Cosmetic.

## Task 13 — Welcome flow + settings modal completion + polish (DONE — what was built)

The FINAL v1 task turns the functional-demo shell into the real product surface: a
first-run onboarding flow, a proper Settings modal, model-picker cards with size/RAM/
tier metadata, and a custom vector icon. The Watched Repositories (Task 3) and Local
model (Task 9) sections MOVED OUT of the chat screen into Settings. All five provided
mockups were followed (welcome, pick-a-local-model, chat, materials, settings).

**KEY DECISION — onboarding is gated on the PERSISTED `onboarded` flag, read from
config CONTENTS (fixes a real boot bug found live).** The Task 1 boot code set
`model.onboarded = true` in the `stat_config` arm whenever the config file EXISTED —
so onboarding would never show for anyone who already had a `config.json` (i.e. every
returning user, AND anyone who quit mid-onboarding). Task 13 changed this: `stat_config`
only routes to `readConfig`, and `config_read_done` sets `model.onboarded =
models.parseOnboarded(bytes) orelse false`. A config that predates the flag (or omits
it) reads as NOT onboarded, so the flow runs once and then persists `true`. Verified
live: with `config.json` `"onboarded": false`, the app boots into the welcome overlay;
after "Continue" it boots into the app.

**KEY DECISION — a SEPARATE config-write path so persisting never clears `onboarded`.**
The Task 9 `persistSelectedModel` wrote config.json via the FIRST-RUN key/Msg
(`key_write_config`/`.wrote_config`), and the `.wrote_config` arm sets `onboarded=false`
(correct only on a first run). So changing the model — or completing onboarding — would
clobber the flag. Renamed to `persistConfig`, now writing via a NEW `key_config_persist`
(200) + `.config_persisted` Msg (a no-op success arm). `select_model` and
`onboard_finish` both call it. Regression-tested (`config_persisted` never clears
`onboarded`).

**KEY DECISION — real catalog kept; mockup's Gemma names NOT adopted.** The mockups show
"Gemma 4 E2B / Gemma 3 1B / Qwen3 0.6B". The real `models.catalog` (Qwen2.5-3B /
Llama-3.2-3B / Qwen2.5-1.5B) has VERIFIED-WORKING download URLs (the 1.5B is the model
downloaded + run end-to-end in Tasks 9-12). Renaming would break the verified flow, so
the catalog stays functional and Task 13 only adds the VISUAL metadata the cards need:
per-model `tier` (`Tier{premium,balanced,basic}`), `min_ram_bytes`, and a `recommended`
flag. Card labels are computed by `models.formatSize`/`formatRam` and surfaced through
`ModelChoice` (now carries `recommended`/`tierLabel` + inline `sizeLabel()`/`ramLabel()`/
`hasRam()`).

**Onboarding flow** (`OnboardStep{welcome, pick_model}`, `app.native` `<if
needsOnboarding>`):
1. WELCOME (mockup 4): a large `app:sparkle` icon (64x64), the "Blocks for Developers"
   heading, and the `welcomeBlurb` paragraph — constrained to a `max-width="620"`
   centered column with `text-alignment="center"` and `wrap="true"` so it forms a tidy
   centered block (NOT a full-width line). "Get Started" -> `onboard_next` ->
   `onboard_step = .pick_model`.
2. PICK A LOCAL MODEL (mockup 5): a `<for each="modelChoices">` of cards, each with
   name + `Recommended`/`{tierLabel}`/`Selected` badges, blurb, `{sizeLabel}` +
   `{ramLabel}` (`<if hasRam>`); tapping a card = `select_model:{index}`. A
   `{modelStatusText}` line + an Install/Continue button (`installLabel` = "Install"
   when missing / "Downloading…" mid-download / "Continue" when present) ->
   `onboard_finish`: sets `onboarded=true`, `persistConfig`, and (if the model isn't on
   disk) `startDownload`, then drops into the app.

**Settings — a SEPARATE OS window** (mockup 3; updated after the first inline-modal
pass). It is NOT an inline `<if>` overlay: the header "Settings" button dispatches
`open_settings` (`settings_open = true`), `blocksWindows` (a UiApp `windows_fn`) then
declares a secondary 900x640 window, and `blocksWindowView` (a `window_view`) builds its
canvas tree in Zig (a UiApp binds MARKUP to only ONE canvas — the main window — so a
second window's content must be Zig-built with the `Ui.*` builders). A left nav
(`settings_all`/`settings_about`/`settings_mcp`/`settings_local_model` ->
`SettingsSection`) drives which pane shows; the `settings*` accessors are written so
`all` shows EVERY pane and a specific section narrows to one (`settingsAbout` =
`all|about`, etc.). Panes:
- ABOUT: "Version" `{appVersionText}` (= `app_version`), the data-dir path
  `{dataDirText}` (for backup — the locked "Settings shows the data path" decision), and
  a "Start Blocks at login" row wired to the existing `toggle_login` (label `On`/`Off`
  via `loginToggleLabel`).
- WATCHED REPOSITORIES: the Task 3 add-field + repo list (`reposSlice`/`add_repo_clicked`/
  `remove_repo`), moved here from the chat screen.
- MODEL CONTEXT PROTOCOL: read-only `{mcpUrlText}` (`http://127.0.0.1:39017/`) and
  `{llamaUrlText}` (`http://127.0.0.1:39018/v1`) in `<code>` with Copy buttons
  (`copy_mcp_url`/`copy_llama_url` -> `writeClipboard` -> `url_clip_done`).
- LOCAL MODEL: the same model-picker cards + Download (`download_model`, shown when
  `canDownload`).

**Chat screen polish**: a left sidebar (`+ New chat` + a TODAY placeholder for the future
chat list), a "SINGLE-CLICK SUMMARIES" label over the three summary cards (now tappable
`<column on-press="start_summary:{c.tag}">` with label + blurb — `summaryDisabled` is no
longer bound since `startSummary` self-gates on `sending`/`llama_ready`), the transcript,
and the composer ("Paste code, or ask a technical question…"). Materials screen tidied
(search on top, `+ New` under the sidebar list).

**Custom vector icon (`app:sparkle`)**: the built-in icon set (`canvas.icons.
known_icon_names`) has no sparkle. Authored `src/assets/icons/sparkle.svg` in the
framework's stroke/fill icon dialect (two filled 4-point stars, cubic-bezier paths),
parsed at comptime with `canvas.svg_icon.parseComptime(@embedFile(...))`, exposed as
`pub const app_icons` on the app root (the model contract reflects THIS decl to validate
`app:` names) and installed with `canvas.icons.registerAppIcons(&app_icons)` in `main`
before the runtime starts. Referenced in markup as `<icon name="app:sparkle" .../>`.

Model state added: `onboard_step: OnboardStep`, `settings_open: bool`,
`settings_section: SettingsSection`. New Msgs: `onboard_next`, `onboard_finish`,
`open_settings`, `close_settings`, `settings_all|about|mcp|local_model`, `copy_mcp_url`,
`copy_llama_url`, `url_clip_done` (clipboard result), `config_persisted` (file result).
`ModelChoice` extended (recommended/tierLabel/size+ram buffers). `refreshModelChoices` is
now `pub` (view-build tests seed it).

Tests (198 total, was 184 at end of Task 12): `models.zig` (tier labels, one-recommended
invariant, `formatSize`/`formatRam`, `parseOnboarded` true/false/absent), `main.zig`
update-arm tests via the fake executor (needsOnboarding/onWelcomeStep defaults;
`onboard_next` -> pick-model; `onboard_finish` -> onboarded; `config_read_done` adopts the
persisted flag — stat alone does NOT; `config_persisted` never clears `onboarded`;
settings open/close; `settings_all|mcp|local_model` section gating; `copy_mcp_url` ->
`url_clip_done` "Copied"), and a view-build test that renders the welcome / pick-model /
settings-open trees. `native check` clean (0 warnings; `app:sparkle` validated against the
refreshed model contract).

### SDK markup learnings (Task 13)
- **The bundled font is ASCII-ish — `native check` REFUSES any glyph outside its
  coverage (an ERROR, not a warning): "character outside the bundled font's coverage …
  renders as a tofu box".** Decorative unicode (✦ ★ ◈ ⌨ 🔍 ⚙ ✕ ⓘ ⚭) is rejected. Use
  plain words, a built-in `<icon name="…"/>` (closed vocabulary: `canvas.icons.
  known_icon_names` — plus/x/check/search/settings/trash/download/copy/edit/…), or a
  registered `app:<name>` icon. (The `·` middle dot in the Task 11 summary blurbs IS
  covered, so it stayed.)
- **Custom icons must live UNDER `src/`** (the package root) for `@embedFile` — a
  `../assets/…` path fails with "embed of file outside package path". Moved the SVG to
  `src/assets/icons/`. Register via `pub const app_icons` + `registerAppIcons`; the model
  contract reads the `pub const app_icons` decl name, so `native test` must refresh the
  contract before `native check` accepts an `app:` reference.
- **`<icon>` sizing**: `size="lg"` renders ~20px; for a hero icon set explicit
  `width`/`height` (numbers) — e.g. `width="64" height="64"`.
- **Text wrapping + alignment**: a bare `<text>` paints ONE line (overflow ellipsis).
  `wrap="true"` word-wraps and reserves height; `text-alignment="start|center|end"`
  aligns it. A text leaf grows to its CONTAINER width, so to get a narrow centered
  paragraph, constrain the parent (`max-width`) — otherwise it wraps at the window edge
  with each line left-hugging.
- **Small overlays stay `<if test>`-gated panels** (no dedicated dialog element used):
  the onboarding overlay and the Materials sort / language-FILTER dropdown menus are
  plain conditional subtrees, so their open state is testable Model state. Larger
  modal/dialog SURFACES are separate OS windows instead (the Settings window at Task 13,
  and — post-v1 — the material editor + a delete-confirmation dialog); see "Post-v1
  changes". (At Task 13 the editor + set-language modal were still `<if>` panels; that
  changed post-v1.)

### The Settings window — a model-declared SECONDARY OS window (Task 13)
The Settings UI opens in its OWN native window (per the mockup / the user's request),
not an in-canvas overlay. The SDK mechanism (see `runtime/ui_app.zig` +
`runtime/ui_app_window_tests.zig`):
- A `UiApp(Model, Msg)` binds MARKUP to exactly ONE canvas (the main window). Secondary
  windows are declared by `Options.windows_fn(model, scratch) -> []WindowDescriptor`
  (PRESENCE in the returned slice IS liveness — the runtime reconciles declared vs live
  windows after every rebuild) and their canvas tree is built in Zig by
  `Options.window_view(ui, model, window_label)`. There is NO second markup file for a
  window; `blocksWindowView` uses the `Ui.*` builders (`ui.column/row/scroll/text/
  button/statusBar`, `ui.el(.card, …)`, `ui.el(.badge, …)`, `ui.each(items, key_fn,
  view_fn)`).
- Open = the `open_settings` Msg sets `settings_open = true`; the next rebuild's
  `windows_fn` declares the window; the runtime creates it. Close = `close_settings`
  clears the flag (also the `WindowDescriptor.on_close` for the user's native close),
  the reconcile closes the window.

**THE REINSTALL GOTCHA (and the fix).** Re-declaring a window under the SAME
`canvas_label` after a close does NOT re-install its canvas in a live GPU session — the
recreated window's install frame never arrives, so a reopen renders a BLANK canvas
(0 widgets). Diagnosed by logging `settings_open` in `windows_fn`: the model flag
round-trips correctly (false->true->false->true), so it's a runtime reconcile edge, not
model logic. `close_policy = .quit` and `.hide` both hit it; a persistent-declaration +
`fx.showWindow`/`fx.hideWindow` approach reopened fine but the window FLASHED at launch
(the `windows_fn` create wins over an `initFx` `hideWindow`). THE FIX: keep presence-
based declaration (no launch flash) but hand the window a FRESH canvas label each open —
`settings-canvas-<n>`, where `n` is a `settings_open_count` bumped in the `open_settings`
arm (`refreshSettingsCanvasLabel` writes `settings_canvas_buf`; `windows_fn` reads
`settingsCanvasLabel()`). A new label = a clean install, so every reopen renders. The
`window_view` is keyed by the WINDOW label, so the varying canvas label is invisible to
it. (A closed `.quit` window's empty shell may briefly linger before the OS releases it
— benign; the SDK's own window test explicitly tolerates a lingering `!open` shell.)

### VERIFIED END-TO-END via automation (+ the boot bug found and fixed live)
Driven live (`native dev --yes -Dautomation=true` with `BLOCKS_LLAMA_SERVER`, real
Qwen2.5-1.5B; `config.json` moved aside to force a first run, restored afterward). All
confirmed against the widget snapshot + `app.db`/config:
- WELCOME renders the 64x64 sparkle image, the heading, the centered wrapped blurb (620px
  wide, 3 lines), and Get Started.
- PICK-MODEL renders all three cards with the right badges + `1.7 GB`/`1.8 GB`/`1.0 GB`
  sizes + `Needs 8/8/4 GB RAM`; tapping the 1.5B card moved the `Selected` badge and
  persisted `selected_model` to config with `onboarded` STILL false (no clobber).
- The 1.5B model was detected present -> button flipped to "Continue"; clicking it wrote
  `onboarded: true` to config and dropped into the main app (header + chat sidebar +
  summary cards + composer).
- SETTINGS (re-verified after moving it to a separate window): clicking the header
  "Settings" opened a genuine SECOND OS window (`window @w2 "Settings" 900x640` with its
  own `settings-canvas-<n>` gpu surface, confirmed in the automation snapshot's window
  list) — and NO settings window exists at launch. The left nav's "All" showed Version
  `0.1.0` + the real data-dir path + the login toggle + Watched Repositories (the current
  repo listed) + the MCP URLs; selecting "Local Model" / "MCP" narrowed to that section;
  the MCP Copy button put `http://127.0.0.1:39017/` on the REAL macOS clipboard (`pbpaste`
  confirmed). Open -> close -> reopen all rendered (72 widgets each open; 0 after close) —
  the fresh-canvas-label fix. The on-screen visibility (hidden at launch / after close)
  was confirmed by the user, since automation enumerates hidden windows too.

**The bug the live run surfaced (fixed in this change):** the app booted straight into
the main screen even with `config.json` `"onboarded": false`, because the Task 1
`stat_config` arm set `onboarded=true` on file EXISTENCE. Fixed by reading the flag from
config contents in `config_read_done` (see the KEY DECISION above); re-verified the
welcome flow then showed correctly. 198 tests green; `native check` clean.

### Deferred / follow-ups
- **Chat history sidebar.** The sidebar shows `+ New chat` + a TODAY placeholder but not
  the real per-day chat list from the `chats` table (mockup 1 groups by date). Wire a
  chats-list query + a `select_chat` nav + date grouping. `+ New chat` currently just
  routes to the chat screen (a fresh chat is still created on first send).
- **Packaging — DONE (see the "Packaging" section below).** The `.app` is now built by
  `packaging/package-macos.sh`: it vendors the MCP child + a relocatable `llama-server`
  into the bundle and a launcher script wires their absolute paths via env
  (`BLOCKS_MCP_SERVER`/`BLOCKS_LLAMA_SERVER`), sidestepping the missing self-path effect.
  STILL open: the packaged-build login item (SMAppService) can't be exercised under
  `native dev`, and the bundle is ad-hoc signed (Developer-ID signing + notarization for
  Gatekeeper-clean distribution is a follow-up — see the Packaging section).
- **Onboarding <-> download UX.** `onboard_finish` starts the download and enters the
  app immediately; there's no in-onboarding progress bar/percent (the chat status shows
  "Downloading…"). A progress meter on the pick-model step + a cancel would be nicer.
- **High-fidelity Materials (from Task 12).** Floating "+", right-rail icon buttons, and
  "saved N ago" are still functional-layout, not pixel-faithful.
- **Settings polish.** No model-delete/disk-usage UI; the login toggle is a text button
  (`On`/`Off`), not a native switch; MCP URLs are static strings (not read from the live
  `mcp-endpoint.json` port, which can differ on an `AddressInUse` scan).

## Packaging (DONE — distributable macOS `.app`)

The app is packaged into a self-contained `Blocks for Developers.app` that runs on
another Apple-Silicon Mac with NO Homebrew / PATH / dev-env dependency. One command:

```sh
packaging/package-macos.sh            # full bundle (app + MCP + llama-server)
packaging/package-macos.sh --skip-llama   # smaller bundle; relies on $BLOCKS_LLAMA_SERVER/PATH
```

Outputs `dist/Blocks for Developers.app` (~44 MB) and `dist/Blocks for Developers.zip`
(~16 MB, the distributable). `dist/` and `vendor/` are gitignored (regenerated artifacts).

**The core problem it solves.** The app spawns two child processes at runtime — the MCP
memory server (`blocks-mcp`) and the llama.cpp chat runtime (`llama-server`) — but under
`native dev` it locates them by REPO-RELATIVE paths that only resolve because the dev
cwd is the repo root. Inside a `.app` the cwd is arbitrary, and the SDK effects channel
still exposes NO self-exe-path / bundle-dir helper (the long-standing Task 8/9 deferral).

**The fix — a launcher that injects absolute sidecar paths via env.** `native package`
sets `CFBundleExecutable = blocks`, so macOS launches `Contents/MacOS/blocks`. The
packaging script renames the real Zig binary to `blocks-bin` and drops a zsh launcher in
its place that computes its own bundle dir (`${0:A:h}`), exports `BLOCKS_MCP_SERVER` +
`BLOCKS_LLAMA_SERVER` pointing at the vendored binaries under `Contents/Resources/vendor/`,
then `exec`s `blocks-bin` (same PID, so tray/login still work). Children inherit the env
(SDK spawn passes the host environment). This required ONE code change:
`main.zig` `resolveMcpBinary()` now prefers `$BLOCKS_MCP_SERVER` (mirror of the existing
`models.resolveServerBinary` / `$BLOCKS_LLAMA_SERVER`) before the repo-relative default.
A dev-set `BLOCKS_LLAMA_SERVER` still wins (the launcher only sets it if unset).

**Bundle layout:**
```
Blocks for Developers.app/Contents/
  MacOS/blocks            # zsh launcher (CFBundleExecutable)
  MacOS/blocks-bin        # the real ReleaseFast Zig app binary
  Resources/vendor/mcp/bin/blocks-mcp      # MCP sidecar (links only system libsqlite3)
  Resources/vendor/llama/bin/llama-server  # llama.cpp runtime
  Resources/vendor/llama/lib/*.dylib       # its relocated dylib closure (13 dylibs)
  Resources/icon.png, AppIcon.icns, *manifest.zon
  Info.plist, PkgInfo, _CodeSignature/
```

**Vendoring `llama-server` (`packaging/vendor-llama.sh`).** `llama-server` (Homebrew,
`brew install llama.cpp`) pulls a web of `@rpath` dylibs (libllama*, libmtmd, libggml*,
libomp) + openssl@3 (libssl/libcrypto) from `/opt/homebrew`. The script copies the binary
+ its full non-system dylib closure into `vendor/llama/{bin,lib}`, rewrites every
non-system install-name to `@rpath/<leaf>`, sets each dylib id to `@rpath/<leaf>`, adds an
`LC_RPATH` of `@loader_path` (dylibs) / `@loader_path/../lib` (the binary), strips the old
Homebrew rpaths, and ad-hoc re-signs each Mach-O (rewriting invalidates the signature).
Metal is compiled INTO `libggml.0.dylib` in this build (no separate `libggml-metal` /
`.metallib` to ship). System libs (`/usr/lib`, `/System/...`) are left as-is. Verified
relocatable: the vendored tree runs `llama-server --version` from a temp dir under
`env -i` (clean environment, no `/opt/homebrew` on the path).

**Signing.** `native package --signing adhoc` signs the initial bundle; after the script
mutates it (launcher + vendored sidecars) it re-signs the whole `.app` ad-hoc with
`codesign --force --deep --sign -`. `codesign --verify --deep --strict` passes and the
bundle "satisfies its Designated Requirement". Ad-hoc is enough to RUN locally and for a
user who removes the quarantine attr (`xattr -dr com.apple.quarantine <app>`); a clean
Gatekeeper/notarized distribution needs a Developer ID identity
(`native package --signing identity --identity "Developer ID Application: …"
--notarize --notary-profile <profile>`) — a follow-up (requires an Apple Developer acct).

### VERIFIED
- `native test --yes` → 200/200 pass; `native check` clean, after the `resolveMcpBinary`
  change.
- `mcp/zig-out/bin/blocks-mcp` links only `/usr/lib/libsqlite3.dylib` + libSystem (on
  every macOS) — fully portable; the ReleaseFast app binary links only system frameworks.
- Bundled `llama-server --version` runs from inside the `.app` under `env -i` (clean env).
- Bundled `blocks-mcp` launched from inside the `.app` under `env -i` against a temp
  `app.db`: wrote its endpoint file, and `curl POST tools/list` returned the 3 tool
  descriptors; `get_activity` answered (empty on the empty test DB).
- The `.app` copied to a fresh location (`/tmp`) still runs its vendored `llama-server`
  under a clean env AND still passes `codesign --verify --deep --strict` — genuinely
  relocatable (proves the drag-to-/Applications-on-another-Mac path).

### Deferred / follow-ups
- **Developer-ID signing + notarization** for a Gatekeeper-clean download (needs an Apple
  Developer account + `--notarize --notary-profile`). Ad-hoc bundles need the quarantine
  attribute cleared on the target Mac.
- **A `.dmg`** (drag-to-Applications installer) instead of / alongside the zip — a
  `create-dmg` / `hdiutil` step on top of the built `.app`.
- **Universal binary (x86_64 + arm64).** Current bundle is arm64-only (the Homebrew
  `llama-server` + the Zig build target). An Intel build would need a second vendored
  `llama-server` + a `lipo`'d app binary, or a per-arch bundle.
- **llama-server version pinning.** The vendor script grabs whatever `brew` has installed
  (0.4.1 here). Pin/verify a known-good build when locking a release.
- **Login item (SMAppService)** still can't be exercised until run as an installed `.app`
  (the Task 6 note) — verify Start-at-Login registers from the packaged bundle.

## Post-v1 changes (log every change here or in the relevant Task section)

Changes made after the v1 tasks (0-13). Keep this current — see the source-of-truth
note at the top of this file.

### Packaging — distributable macOS `.app`
Added `packaging/` (`package-macos.sh`, `vendor-llama.sh`, `README.md`) + a
`BLOCKS_MCP_SERVER` env override (`resolveMcpBinary` in `main.zig`). Full detail is in
the "Packaging (DONE — distributable macOS `.app`)" section above.

### Materials editor + set-language + delete-confirmation → separate OS windows
The Task 12/13 sections describe the material add/edit editor as an inline `<if>`-gated
"editor sheet" and a separate "set-language modal". That is NO LONGER how it works:
- **Material add/edit editor is now a SEPARATE OS window** (`editor_window_label` /
  `editor_canvas_label`), built in Zig by `editorWindowView` in `main.zig`, opened via
  `windows_fn` when `editor_open`. The "+" FAB (`open_new_snippet`) and the pencil
  (`open_edit_snippet`) declare it. Its Save/Cancel/close + the five `edit_*_edit`
  `on-input` arms are dispatched from that window (not markup) — hence listed under the
  Model's update-only decls.
- **The set-language modal was REMOVED.** A snippet's language is now edited INSIDE the
  editor window (the old `{}`-button modal was duplicate functionality). The sidebar
  language FILTER menu still exists and is unchanged.
- **A delete-confirmation dialog is ALSO a separate OS window** (`confirm_delete_*`),
  built by `confirmDeleteWindowView`; the trash button dispatches `request_delete_snippet`
  on the main canvas, and confirm/cancel come from the dialog window.

All three secondary windows (Settings, material editor, delete-confirmation) are declared
by `blocksWindows` (`windows_fn`) and routed by window label inside `blocksWindowView`
(`window_view`); each open hands the window a FRESH `<base>-canvas-<n>` label to dodge the
reopen-blank-canvas reconcile bug (the same fix Settings uses — see the Task 13 Settings
window section). `app.native` now only `<if>`-gates the onboarding overlay + the Materials
sort/language-filter dropdown menus.
