//! Local model management + llama.cpp runtime — PURE data layer (Task 9).
//!
//! Blocks runs its chat against a LOCAL model. This module owns everything
//! about that model that can be expressed without touching the OS: the
//! curated download CATALOG, the on-disk file layout under `<data_dir>/
//! models/`, the argv for the two subprocesses we drive (a `curl` download
//! and the `llama-server` runtime), progress parsing, and the tiny bit of
//! `config.json` (de)serialization that records which model the user picked.
//!
//! Why subprocesses (locked decisions, see docs/PROGRESS.md):
//!   - DOWNLOAD: the SDK `fetch` effect buffers at most 256 KiB and its
//!     `.stream` mode is line-framed text, so it cannot pull a multi-hundred-
//!     MB GGUF. We spawn `curl` instead (proven in the spike), writing to a
//!     `.part` file that is renamed into place only on a clean exit.
//!   - RUNTIME: the SDK has no in-process HTTP server, so — exactly like the
//!     MCP child (Task 8) — the llama.cpp runtime is a spawned `llama-server`
//!     that serves an OpenAI-compatible API on loopback; the app reaches it
//!     with `fetch` and health-checks `GET /health`.
//!
//! Everything here is pure and unit-tested; the effect firing lives in
//! main.zig. Path/argv builders use the caller-owned buffer pattern (the
//! same lifetime discipline as repos.zig / git.zig).

const std = @import("std");

// -------------------------------------------------------------- catalog

/// A curated, downloadable chat model. `url` points at a single GGUF file
/// (a quantized build small enough to run comfortably on the 18 GB dev
/// machine). `size_bytes` is the expected on-disk size, used both for a
/// post-download sanity check and to show a total in the progress UI.
/// `sha256` (lowercase hex, or "" when unknown) enables integrity
/// verification when present.
/// A model's quality/resource tier, shown as a badge in the picker cards
/// (mockup: "Premium" / "Balanced" / "Basic"). Independent of the
/// `recommended` flag (a single model is recommended within its tier set).
pub const Tier = enum {
    premium,
    balanced,
    basic,

    /// The badge label shown on the picker card.
    pub fn label(self: Tier) []const u8 {
        return switch (self) {
            .premium => "Premium",
            .balanced => "Balanced",
            .basic => "Basic",
        };
    }
};

pub const CatalogModel = struct {
    /// Stable id persisted in config.json (never shown raw to the user).
    id: []const u8,
    /// Human-friendly name for the model picker.
    display_name: []const u8,
    /// Short one-line description (params / quant / vibe) for the picker.
    blurb: []const u8,
    /// Direct download URL of the GGUF file.
    url: []const u8,
    /// The local filename to store it under (inside `<data_dir>/models/`).
    file_name: []const u8,
    /// Expected file size in bytes (0 = unknown; size check skipped).
    size_bytes: u64,
    /// Expected SHA-256, lowercase hex ("" = unknown; verify skipped).
    sha256: []const u8 = "",
    /// Context length the runtime should be launched with.
    context_length: u32 = 4096,
    /// Quality/resource tier, shown as a badge in the picker.
    tier: Tier = .balanced,
    /// Recommended RAM to run this model comfortably, in bytes. Shown as
    /// "Needs N GB RAM" in the picker card.
    min_ram_bytes: u64 = 0,
    /// True for the single "Recommended" model (mockup: a starred badge).
    /// The onboarding picker defaults its selection to this one.
    recommended: bool = false,
};

/// The v1 model catalog. Kept intentionally small and curated: a couple of
/// well-known instruct GGUFs that run locally with good latency. The URLs
/// are stable Hugging Face `resolve` links to single-file quantized builds.
/// (Sizes are the published file sizes; sha256 left empty for v1 — the
/// size check + curl's own `-f` failure handling are the integrity guard,
/// and a real digest can be pinned later without touching call sites.)
pub const catalog = [_]CatalogModel{
    .{
        .id = "qwen2.5-3b-instruct-q4",
        .display_name = "Qwen2.5 3B Instruct",
        .blurb = "Best quality. Recommended. A capable 3B model quantized to Q4_K_M for fast local answers.",
        .url = "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf",
        .file_name = "qwen2.5-3b-instruct-q4_k_m.gguf",
        .size_bytes = 1_929_903_104,
        .context_length = 8192,
        .tier = .premium,
        .min_ram_bytes = 8 * 1024 * 1024 * 1024,
        .recommended = true,
    },
    .{
        .id = "llama-3.2-3b-instruct-q4",
        .display_name = "Llama 3.2 3B Instruct",
        .blurb = "Balanced size and quality. A solid alternative if you prefer the Llama family.",
        .url = "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        .file_name = "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        .size_bytes = 2_019_377_696,
        .context_length = 8192,
        .tier = .balanced,
        .min_ram_bytes = 8 * 1024 * 1024 * 1024,
    },
    .{
        .id = "qwen2.5-1.5b-instruct-q4",
        .display_name = "Qwen2.5 1.5B Instruct",
        .blurb = "Smallest and fastest. A lighter choice if disk or memory is tight.",
        .url = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
        .file_name = "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        .size_bytes = 1_117_320_736, // verified against the real download
        .context_length = 8192,
        .tier = .basic,
        .min_ram_bytes = 4 * 1024 * 1024 * 1024,
    },
};

/// The catalog id chosen as the default selection on first run.
pub const default_model_id = "qwen2.5-3b-instruct-q4";

/// Look up a catalog model by id, or null if the id is unknown (e.g. a
/// stale config from a previous catalog).
pub fn findModel(id: []const u8) ?*const CatalogModel {
    for (&catalog) |*m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

/// The catalog id of the recommended model (falls back to the default).
pub fn recommendedModelId() []const u8 {
    for (&catalog) |*m| {
        if (m.recommended) return m.id;
    }
    return default_model_id;
}

// ----------------------------------------------------- display helpers

const gib: u64 = 1024 * 1024 * 1024;
const mib: u64 = 1024 * 1024;

/// Format a byte size as a compact human string ("3.1 GB" / "769 MB") into
/// `buf`, returning the slice. GB for >= 1 GiB (one decimal), else whole MB.
/// Pure + allocation-free (caller owns `buf`, needs ~16 bytes).
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes == 0) return std.fmt.bufPrint(buf, "—", .{}) catch "—";
    if (bytes >= gib) {
        const whole = bytes / gib;
        const frac = ((bytes % gib) * 10) / gib; // one decimal digit
        return std.fmt.bufPrint(buf, "{d}.{d} GB", .{ whole, frac }) catch "—";
    }
    const mb = (bytes + mib - 1) / mib; // round up to whole MB
    return std.fmt.bufPrint(buf, "{d} MB", .{mb}) catch "—";
}

/// Format the RAM recommendation as "Needs N GB RAM" into `buf`, rounding
/// up to whole GB. Returns "" when unknown (0). Caller owns `buf` (~24 bytes).
pub fn formatRam(buf: []u8, min_ram_bytes: u64) []const u8 {
    if (min_ram_bytes == 0) return "";
    const gb = (min_ram_bytes + gib - 1) / gib; // round up to whole GB
    return std.fmt.bufPrint(buf, "Needs {d} GB RAM", .{gb}) catch "";
}

// ------------------------------------------------------- on-disk layout

/// Max bytes we allow for any single joined path we build here.
pub const max_path_bytes = 1024;

/// Join `<models_dir>/<file_name>` into `buf` and return the slice. The
/// caller owns `buf`; the returned slice points into it. Errors if the
/// join would overflow the buffer.
pub fn modelFilePath(buf: []u8, models_dir: []const u8, file_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ trimTrailingSlash(models_dir), file_name });
}

/// The in-progress download path: the final path with a `.part` suffix.
/// curl writes here and we rename to the final name only on a clean exit,
/// so a crashed/aborted download never looks like a complete model.
pub fn partFilePath(buf: []u8, models_dir: []const u8, file_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}.part", .{ trimTrailingSlash(models_dir), file_name });
}

fn trimTrailingSlash(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') end -= 1;
    return p[0..end];
}

// ----------------------------------------------------------- curl argv

/// Number of argv slots `downloadArgv` needs (fixed).
pub const download_argv_len = 10;

/// Build the `curl` argv that downloads `url` to `out_part_path`.
///   curl -fL --silent --show-error --progress-bar -o <out> <url>
/// Flags: `-f` fail on HTTP errors (so a 404 is a non-zero exit, not a
/// saved error page), `-L` follow redirects (HF `resolve` links redirect),
/// `--progress-bar` emits a compact meter on stderr, `--show-error` keeps
/// the error message on failure while `--silent` drops the noisy default
/// meter. The caller owns `buf`; the returned slice points into it.
pub fn downloadArgv(buf: *[download_argv_len][]const u8, url: []const u8, out_part_path: []const u8) []const []const u8 {
    buf.* = .{
        "curl",
        "-fL",
        "--silent",
        "--show-error",
        "--progress-bar",
        "--output",
        out_part_path,
        "--url",
        url,
        "--no-buffer",
    };
    return buf[0..];
}

/// Parse a fractional download progress value (0.0–1.0) out of a curl
/// `--progress-bar` line, or null if the line carries no percentage.
///
/// curl's progress bar redraws a single line with a trailing percentage,
/// e.g. `##########                        42.7%`. We scan for the last
/// run of `digits[.digits]` immediately followed by `%` and divide by 100.
/// Best-effort: any unrecognized line yields null and is simply ignored.
pub fn parseProgress(line: []const u8) ?f32 {
    // Find a '%' and walk left over an optional number.
    var i: usize = 0;
    var last: ?f32 = null;
    while (i < line.len) : (i += 1) {
        if (line[i] != '%') continue;
        // Walk backwards over digits and at most one dot.
        var start = i;
        var seen_dot = false;
        while (start > 0) {
            const c = line[start - 1];
            if (c >= '0' and c <= '9') {
                start -= 1;
            } else if (c == '.' and !seen_dot) {
                seen_dot = true;
                start -= 1;
            } else break;
        }
        if (start == i) continue; // a '%' with no number before it
        const num = std.fmt.parseFloat(f32, line[start..i]) catch continue;
        last = std.math.clamp(num / 100.0, 0.0, 1.0);
    }
    return last;
}

/// Number of argv slots `renameArgv` needs (fixed).
pub const rename_argv_len = 4;

/// Build the `mv` argv that moves the finished `.part` file to its final
/// name. The SDK file effects have NO rename/move op (read/write/append/
/// stat/delete only), so we do the atomic-into-place move with a spawned
/// `/bin/mv` — universally present, and a same-directory `mv` is a rename
/// (atomic on the same filesystem). Only run after curl exits cleanly, so
/// an aborted download never becomes a visible model. Caller owns `buf`.
pub fn renameArgv(buf: *[rename_argv_len][]const u8, from_part: []const u8, to_final: []const u8) []const []const u8 {
    buf.* = .{ "mv", "-f", from_part, to_final };
    return buf[0..];
}

// -------------------------------------------------- llama-server argv

/// Number of argv slots `serverArgv` needs (fixed).
pub const server_argv_len = 10;

/// Build the `llama-server` argv that serves `model_path` on
/// `127.0.0.1:<port>` with the given context length.
///   <bin> -m <model> --host 127.0.0.1 --port <port> -c <ctx> --no-ui
/// `binary` is the resolved path to the llama.cpp server executable.
/// `port_str`/`ctx_str` are caller-formatted decimal strings (so this stays
/// allocation-free and pure). The caller owns `buf`.
pub fn serverArgv(
    buf: *[server_argv_len][]const u8,
    binary: []const u8,
    model_path: []const u8,
    port_str: []const u8,
    ctx_str: []const u8,
) []const []const u8 {
    buf.* = .{
        binary,
        "-m",         model_path,
        "--host",     "127.0.0.1",
        "--port",     port_str,
        "-c",         ctx_str,
        "--no-ui",
    };
    return buf[0..];
}

/// Resolve the llama-server binary path: an explicit env override wins,
/// otherwise the packaged default (relative to the app cwd, matching how
/// the MCP child is located under `native dev`). `env_value` is the value
/// of `BLOCKS_LLAMA_SERVER` (or null when unset).
pub const default_server_binary = "vendor/llama/bin/llama-server";
pub const server_binary_env = "BLOCKS_LLAMA_SERVER";

pub fn resolveServerBinary(env_value: ?[]const u8) []const u8 {
    if (env_value) |v| {
        if (v.len > 0) return v;
    }
    return default_server_binary;
}

// ---------------------------------------------------- config selection

/// Extract the `selected_model` string value from a `config.json` blob,
/// or null if the key is absent/malformed. A tiny hand parser (the SDK
/// config file is small and we already hand-write it in bootstrap.zig, so
/// we avoid pulling a JSON parser into this pure module). Returns a slice
/// borrowing `json`.
pub fn parseSelectedModel(json: []const u8) ?[]const u8 {
    return jsonStringField(json, "selected_model");
}

/// Read the boolean `onboarded` flag from a `config.json` blob. Returns
/// null when the key is absent/malformed (caller decides the default —
/// a config that predates the flag is treated as NOT onboarded, so the
/// welcome flow re-runs once and then persists `true`). Sibling of
/// `parseSelectedModel`; scans for `"onboarded"`, skips `:` + whitespace,
/// and reads a `true`/`false` literal.
pub fn parseOnboarded(json: []const u8) ?bool {
    return jsonBoolField(json, "onboarded");
}

fn jsonBoolField(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [128]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    const needle = needle_buf[0 .. key.len + 2];

    const key_at = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = key_at + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (std.mem.startsWith(u8, json[i..], "true")) return true;
    if (std.mem.startsWith(u8, json[i..], "false")) return false;
    return null;
}

/// Minimal extractor for a top-level `"key": "value"` string field. Finds
/// `"<key>"`, skips `:` and whitespace, and reads the following quoted
/// string (honoring `\"` escapes by scanning to the first unescaped `"`).
/// Sufficient for our own flat, hand-written config file.
fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    const needle = needle_buf[0 .. key.len + 2];

    const key_at = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = key_at + needle.len;
    // skip whitespace + a single ':'
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const val_start = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1; // skip the escaped char
            continue;
        }
        if (json[i] == '"') return json[val_start..i];
    }
    return null;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "findModel resolves known ids and rejects unknown" {
    try testing.expect(findModel(default_model_id) != null);
    try testing.expectEqualStrings("Qwen2.5 3B Instruct", findModel(default_model_id).?.display_name);
    try testing.expect(findModel("no-such-model") == null);
}

test "catalog default id is present in the catalog" {
    try testing.expect(findModel(default_model_id) != null);
}

test "exactly one catalog model is recommended and it is the default" {
    var count: usize = 0;
    for (&catalog) |*m| {
        if (m.recommended) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings(default_model_id, recommendedModelId());
}

test "every catalog model carries a tier and a RAM recommendation" {
    for (&catalog) |*m| {
        try testing.expect(m.min_ram_bytes > 0);
        try testing.expect(m.tier.label().len > 0);
    }
}

test "formatSize renders GB with one decimal and whole MB" {
    var buf: [16]u8 = undefined;
    // 3.5 GiB -> "3.5 GB" (frac digit is (bytes%gib)*10/gib).
    try testing.expectEqualStrings("3.5 GB", formatSize(&buf, 3 * gib + gib / 2));
    try testing.expectEqualStrings("1.7 GB", formatSize(&buf, 1_929_903_104));
    try testing.expectEqualStrings("769 MB", formatSize(&buf, 769 * mib));
    try testing.expectEqualStrings("—", formatSize(&buf, 0));
}

test "formatRam rounds up to whole GB and is empty when unknown" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("Needs 8 GB RAM", formatRam(&buf, 8 * gib));
    try testing.expectEqualStrings("Needs 4 GB RAM", formatRam(&buf, 4 * gib));
    try testing.expectEqualStrings("", formatRam(&buf, 0));
}

test "Tier labels match the mockup badges" {
    try testing.expectEqualStrings("Premium", Tier.premium.label());
    try testing.expectEqualStrings("Balanced", Tier.balanced.label());
    try testing.expectEqualStrings("Basic", Tier.basic.label());
}

test "modelFilePath and partFilePath join under the models dir" {
    var buf: [max_path_bytes]u8 = undefined;
    const p = try modelFilePath(&buf, "/data/models", "m.gguf");
    try testing.expectEqualStrings("/data/models/m.gguf", p);

    var buf2: [max_path_bytes]u8 = undefined;
    const part = try partFilePath(&buf2, "/data/models/", "m.gguf");
    try testing.expectEqualStrings("/data/models/m.gguf.part", part);
}

test "downloadArgv builds a curl invocation to the part file" {
    var buf: [download_argv_len][]const u8 = undefined;
    const argv = downloadArgv(&buf, "https://example.com/m.gguf", "/data/models/m.gguf.part");
    try testing.expectEqualStrings("curl", argv[0]);
    try testing.expectEqualStrings("-fL", argv[1]);
    // The output path and url must both appear.
    var saw_out = false;
    var saw_url = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "/data/models/m.gguf.part")) saw_out = true;
        if (std.mem.eql(u8, a, "https://example.com/m.gguf")) saw_url = true;
    }
    try testing.expect(saw_out and saw_url);
}

test "parseProgress reads the trailing percentage from a curl bar line" {
    try testing.expectEqual(@as(?f32, null), parseProgress("connecting..."));
    const p1 = parseProgress("######                          12.5%").?;
    try testing.expectApproxEqAbs(@as(f32, 0.125), p1, 0.0001);
    const p2 = parseProgress("################################ 100.0%").?;
    try testing.expectApproxEqAbs(@as(f32, 1.0), p2, 0.0001);
    // Clamps above 100 and ignores a bare '%'.
    try testing.expectEqual(@as(?f32, null), parseProgress("just a % sign"));
}

test "parseProgress takes the last percentage when several appear" {
    const p = parseProgress("5.0% ... later 80.0%").?;
    try testing.expectApproxEqAbs(@as(f32, 0.80), p, 0.0001);
}

test "renameArgv moves the part file into place" {
    var buf: [rename_argv_len][]const u8 = undefined;
    const argv = renameArgv(&buf, "/data/models/m.gguf.part", "/data/models/m.gguf");
    try testing.expectEqualStrings("mv", argv[0]);
    try testing.expectEqualStrings("/data/models/m.gguf.part", argv[2]);
    try testing.expectEqualStrings("/data/models/m.gguf", argv[3]);
}

test "serverArgv wires the model path, host, port and context" {
    var buf: [server_argv_len][]const u8 = undefined;
    const argv = serverArgv(&buf, "/bin/llama-server", "/data/models/m.gguf", "8080", "8192");
    try testing.expectEqualStrings("/bin/llama-server", argv[0]);
    var saw_model = false;
    var saw_port = false;
    var saw_ctx = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "/data/models/m.gguf")) saw_model = true;
        if (std.mem.eql(u8, a, "8080")) saw_port = true;
        if (std.mem.eql(u8, a, "8192")) saw_ctx = true;
    }
    try testing.expect(saw_model and saw_port and saw_ctx);
}

test "resolveServerBinary prefers a non-empty env override" {
    try testing.expectEqualStrings(default_server_binary, resolveServerBinary(null));
    try testing.expectEqualStrings(default_server_binary, resolveServerBinary(""));
    try testing.expectEqualStrings("/opt/llama/llama-server", resolveServerBinary("/opt/llama/llama-server"));
}

test "parseSelectedModel extracts the id, tolerating whitespace" {
    const cfg =
        \\{
        \\  "version": "0.1.0",
        \\  "username": "rui",
        \\  "onboarded": false,
        \\  "selected_model": "qwen2.5-3b-instruct-q4"
        \\}
    ;
    try testing.expectEqualStrings("qwen2.5-3b-instruct-q4", parseSelectedModel(cfg).?);
}

test "parseSelectedModel returns null when the key is absent" {
    const cfg =
        \\{ "version": "0.1.0", "username": "rui" }
    ;
    try testing.expect(parseSelectedModel(cfg) == null);
}

test "parseOnboarded reads the boolean flag" {
    const yes =
        \\{ "onboarded": true, "selected_model": "x" }
    ;
    const no =
        \\{ "onboarded": false, "selected_model": "x" }
    ;
    try testing.expectEqual(@as(?bool, true), parseOnboarded(yes));
    try testing.expectEqual(@as(?bool, false), parseOnboarded(no));
    // Absent -> null (caller defaults to not-onboarded so the flow re-runs).
    try testing.expectEqual(@as(?bool, null), parseOnboarded("{ \"version\": \"0.1.0\" }"));
}
