#!/bin/zsh
# vendor-llama.sh — collect a relocatable copy of llama-server + its dylib
# closure into vendor/llama/ so a packaged .app can ship a self-contained
# local-LLM runtime with no Homebrew dependency on the target Mac.
#
# Strategy: copy llama-server + every non-system dylib it (transitively)
# depends on into vendor/llama/bin + vendor/llama/lib, then rewrite each
# Mach-O's install names + LC_RPATH so every non-system reference resolves
# via @loader_path/../lib (relative to the binary/dylib's own location).
# System libraries (/usr/lib, /System/...) are left untouched — they exist
# on every macOS.
#
# Usage: packaging/vendor-llama.sh [path-to-llama-server]
#   Defaults to `command -v llama-server` (Homebrew install).
set -euo pipefail
setopt sh_word_split 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BIN="${1:-$(command -v llama-server || true)}"

if [[ -z "$SRC_BIN" || ! -x "$SRC_BIN" ]]; then
  echo "error: llama-server not found. Install it (brew install llama.cpp) or pass its path." >&2
  echo "usage: $0 [path-to-llama-server]" >&2
  exit 1
fi
# Resolve symlinks (Homebrew's bin is a symlink into Cellar).
SRC_BIN="$(readlink -f "$SRC_BIN" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$SRC_BIN")"

VENDOR="$REPO_ROOT/vendor/llama"
BIN_DIR="$VENDOR/bin"
LIB_DIR="$VENDOR/lib"

echo "==> Vendoring $SRC_BIN"
rm -rf "$VENDOR"
mkdir -p "$BIN_DIR" "$LIB_DIR"

# --- helpers ---------------------------------------------------------------
is_system_lib() {
  # /usr/lib and /System/... ship with macOS; never vendor those.
  case "$1" in
    /usr/lib/*|/System/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Map an install-name reference to an absolute source path.
#   @rpath/foo.dylib  -> search the binary's own rpaths (Homebrew uses the
#                         Cellar lib dir); we resolve against the known
#                         Homebrew lib prefixes.
#   /abs/path         -> as-is
resolve_ref() {
  local ref="$1" origin_dir="$2"
  case "$ref" in
    @rpath/*)
      local leaf="${ref#@rpath/}"
      # Search the origin dir, its ../lib, and the Homebrew opt/lib trees.
      local candidates=(
        "$origin_dir/$leaf"
        "$origin_dir/../lib/$leaf"
        "/opt/homebrew/lib/$leaf"
      )
      # ggml/llama live under their own Cellar opt dirs.
      for opt in /opt/homebrew/opt/*/lib; do
        candidates+=("$opt/$leaf")
      done
      local c
      for c in "${candidates[@]}"; do
        [[ -f "$c" ]] && { python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$c"; return 0; }
      done
      return 1
      ;;
    @loader_path/*|@executable_path/*)
      local leaf="${ref##*/}"
      local c="$origin_dir/$leaf"
      [[ -f "$c" ]] && { python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$c"; return 0; }
      return 1
      ;;
    /*)
      [[ -f "$ref" ]] && { echo "$ref"; return 0; }
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# Recursively copy a Mach-O's non-system dependency closure into LIB_DIR.
typeset -A COPIED
collect() {
  local src="$1" origin_dir
  origin_dir="$(dirname "$src")"
  local dep
  # otool -L lists deps from line 2 on; take the first field.
  while IFS= read -r dep; do
    dep="$(echo "$dep" | awk '{print $1}')"
    [[ -z "$dep" ]] && continue
    is_system_lib "$dep" && continue
    # Skip a dylib's own id line (matches its leaf).
    local abs
    abs="$(resolve_ref "$dep" "$origin_dir" || true)"
    if [[ -z "$abs" ]]; then
      echo "  warn: could not resolve $dep (from $(basename "$src"))" >&2
      continue
    fi
    local leaf; leaf="$(basename "$abs")"
    if [[ -z "${COPIED[$leaf]:-}" ]]; then
      COPIED[$leaf]=1
      cp -f "$abs" "$LIB_DIR/$leaf"
      chmod u+w "$LIB_DIR/$leaf"
      echo "  + lib/$leaf"
      collect "$abs"
    fi
  done < <(otool -L "$src" | tail -n +2)
}

# --- copy binary + closure -------------------------------------------------
cp -f "$SRC_BIN" "$BIN_DIR/llama-server"
chmod u+w "$BIN_DIR/llama-server"
echo "  + bin/llama-server"
collect "$SRC_BIN"

# --- rewrite install names -------------------------------------------------
# For the binary: change each non-system dep ref to @loader_path/../lib/<leaf>
# and add an rpath of @loader_path/../lib. For each dylib: set its id to
# @rpath/<leaf> and rewrite its deps the same way, with rpath @loader_path
# (siblings live in the same lib dir).
rewrite_refs() {
  local file="$1" rpath="$2"
  local dep abs leaf
  while IFS= read -r dep; do
    dep="$(echo "$dep" | awk '{print $1}')"
    [[ -z "$dep" ]] && continue
    is_system_lib "$dep" && continue
    leaf="$(basename "$dep")"
    # Only rewrite deps we actually vendored.
    if [[ -n "${COPIED[$leaf]:-}" ]]; then
      install_name_tool -change "$dep" "@rpath/$leaf" "$file" 2>/dev/null || true
    fi
  done < <(otool -L "$file" | tail -n +2)
  # Drop any pre-existing rpaths that point into Homebrew, then add ours.
  while IFS= read -r rp; do
    install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || true
  done < <(otool -l "$file" | awk '/LC_RPATH/{getline;getline; if ($1=="path") print $2}')
  install_name_tool -add_rpath "$rpath" "$file" 2>/dev/null || true
}

echo "==> Rewriting install names"
for lib in "$LIB_DIR"/*.dylib; do
  [[ -e "$lib" ]] || continue
  leaf="$(basename "$lib")"
  install_name_tool -id "@rpath/$leaf" "$lib" 2>/dev/null || true
  rewrite_refs "$lib" "@loader_path"
done
rewrite_refs "$BIN_DIR/llama-server" "@loader_path/../lib"

# --- re-sign (ad-hoc) so the rewritten Mach-Os load ------------------------
echo "==> Ad-hoc re-signing vendored binaries"
for f in "$LIB_DIR"/*.dylib "$BIN_DIR/llama-server"; do
  [[ -e "$f" ]] || continue
  codesign --force --sign - "$f" 2>/dev/null || true
done

echo "==> Verifying llama-server runs from vendor tree"
if "$BIN_DIR/llama-server" --version >/dev/null 2>&1; then
  echo "    ok: vendored llama-server --version succeeded"
else
  echo "    warn: vendored llama-server --version failed; check otool -L below" >&2
  otool -L "$BIN_DIR/llama-server" >&2 || true
fi

echo "==> Done. Vendored $(ls "$LIB_DIR" | wc -l | tr -d ' ') dylibs into $VENDOR"
