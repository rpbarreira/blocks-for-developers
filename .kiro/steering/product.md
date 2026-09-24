# Product — Blocks for Developers

A macOS desktop app that runs in the background, indexes the user's watched local
git repositories (commit history + working-tree file changes) into a searchable
"developer memory," and exposes that memory to a locally-run LLM via an MCP server.

The user chats with the model to recall past work and generate summaries (Day Recap,
What's Top of Mind, Standup Update), and manages code snippets ("materials"). Nothing
leaves the machine: capture, retrieval, the MCP server, and the LLM all run locally.

## Core capabilities

- **Memory capture** — git commits (incremental) + working-tree file-change snapshots
  (debounced, content-hash-deduped). Scope is git-tracked content only; no
  terminal/window/clipboard capture.
- **Retrieval** — local embeddings + vector search plus FTS5 keyword search, exposed
  through an MCP server as `search_memory` / `get_activity` / `get_commits` tools.
- **Chat** — a local llama.cpp runtime (OpenAI-compatible API on loopback). Chat uses
  retrieval-augmented generation: the app queries `search_memory` first and injects
  hits as context (NOT native tool-calling, which small models do unreliably).
- **Single-click summaries** — Day Recap / What's Top of Mind / Standup Update, each a
  canned turn that pulls recent activity via `get_activity` and asks the model to write it.
- **Materials** — saved code snippets with a language tag, annotation, and text-expander
  note; searchable/sortable/filterable, copy-to-clipboard, save-from-chat cross-linking.
- **Always-on** — menu-bar tray + auto-start on login; the app stays running so capture,
  the MCP server, and the UI live in one process.

## Locked decisions (do not relitigate without a reason)

- **macOS-only for v1**, Apple Silicon focus.
- **Native SDK + Zig, ZERO TypeScript.** The user dislikes JS; the Zig-only path was
  proven viable by the Task 0 spike. Fallback was Tauri+Rust but the spike PASSED, so
  we are committed to Native SDK.
- **One data folder:** everything lives in the macOS app-data dir
  `~/Library/Application Support/dev.blocks.app/` — `app.db`, `config.json`, `models/`.
  No `~/blocks`. Settings shows this path (under the app version) for backup.
- **Process model:** single tray app, auto-start on login, always running (capture + MCP
  + UI in one process).
- **MCP-first LLM access.** The MCP server runs as a SPAWNED CHILD PROCESS (the SDK has a
  `fetch` client but no in-process socket listener). The app's LLM reaches it over HTTP.
- **LLM runtime:** bundled llama.cpp (`llama-server`), spawned as a subprocess, reached
  over loopback HTTP.
- **Embeddings:** ONE fixed dedicated embedding model for all users so the index never
  needs re-embedding. v1 uses a deterministic in-process hashing embedder (`hash-v1`);
  a neural embedder can be added later under a NEW model id (schema allows coexistence).
- **Repo watching:** manual add via a Watched Repositories settings section.

## UI

Modeled on 5 provided mockups: welcome/onboarding, model picker, chat, materials,
settings — plus a Watched Repositories settings section and a repo-watching welcome
step. Onboarding is gated on a persisted `onboarded` flag read from config CONTENTS.
Settings is a SEPARATE OS window (not an in-canvas overlay).

## Status

All 14 v1 tasks (0-13) are implemented, committed, and verified end-to-end. The app is
packaged into a distributable, self-contained `.app` (see `packaging/` and the
"Packaging" section of `docs/PROGRESS.md`). `docs/PROGRESS.md` is the authoritative,
detailed resumption log — read it first when picking up work.
