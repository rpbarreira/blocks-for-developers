# Packaging

Build a distributable, self-contained macOS app bundle for **Blocks for Developers**
(Apple Silicon).

## Quick start

```sh
# From the repo root:
packaging/package-macos.sh
```

Produces:

- `dist/Blocks for Developers.app` — the runnable bundle
- `dist/Blocks for Developers.zip` — the distributable archive

Both `dist/` and `vendor/` are gitignored (regenerated build artifacts).

## What gets bundled

The app spawns two child processes at runtime and neither is on a fresh Mac's `PATH`:

- `blocks-mcp` — the MCP memory server (links only the system `libsqlite3`, so it is
  fully portable on its own).
- `llama-server` — the llama.cpp chat runtime, vendored with its full dylib closure
  and rewritten to load via `@loader_path` (no Homebrew dependency on the target Mac).

A small launcher script takes the bundle's `CFBundleExecutable` slot, computes the
bundle directory, exports `BLOCKS_MCP_SERVER` / `BLOCKS_LLAMA_SERVER` pointing at the
vendored binaries, then `exec`s the real app binary. Child processes inherit that
environment, so the app finds its sidecars wherever the `.app` lives.

## Scripts

- `package-macos.sh [--skip-llama]` — the full pipeline (build → vendor → assemble →
  sign → zip). `--skip-llama` produces a smaller bundle that relies on
  `$BLOCKS_LLAMA_SERVER` / `PATH` for the chat runtime instead of vendoring it.
- `vendor-llama.sh [path-to-llama-server]` — collect a relocatable `llama-server` +
  its dylib closure into `vendor/llama/`. Defaults to the `llama-server` on `PATH`
  (`brew install llama.cpp`).

## Prerequisites

- `@native-sdk/cli` (`native`) and the Zig toolchain (auto-installed under `~/.native`).
- `llama.cpp` installed via Homebrew (`brew install llama.cpp`) — only needed at
  PACKAGE time to source `llama-server`; the produced `.app` does not need it.

## Signing / distribution

The bundle is **ad-hoc signed** (`--signing adhoc` + a `codesign --deep` re-sign after
the launcher/sidecars are installed). It runs locally and passes
`codesign --verify --deep --strict`. On another Mac, clear the quarantine attribute if
Gatekeeper blocks it:

```sh
xattr -dr com.apple.quarantine "/Applications/Blocks for Developers.app"
```

For a Gatekeeper-clean download, re-run `native package` with a Developer ID identity
and notarization:

```sh
native package --target macos --binary zig-out/bin/blocks --assets assets \
  --signing identity --identity "Developer ID Application: NAME (TEAMID)" \
  --notarize --notary-profile <profile>
```

(then re-apply the launcher/sidecar install + re-sign — see `package-macos.sh`).
