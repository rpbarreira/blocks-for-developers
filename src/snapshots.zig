//! Working-tree file-change capture: PURE argv builders, a `git status`
//! parser, content hashing, and `file_snapshots` statement builders.
//!
//! There is no filesystem-watch effect in the SDK (confirmed by scanning
//! the effects surface), so capture is POLL-based: a repeating fx timer is
//! the debounce/coalesce window, and on each tick we ask git which
//! working-tree files changed, read their current content, and store a
//! snapshot — but only when the content hash differs from the last stored
//! snapshot for that path (unchanged saves are skipped).
//!
//! As with `git.zig`, everything here is deterministic and unit-testable;
//! the effectful spawn/readFile/dbExec wiring lives in main.zig.
//!
//! `git status --porcelain=v1 -z` output (verified against a real repo):
//!   Each entry is `XY<space><path>` terminated by a NUL byte, where XY are
//!   the two staged/worktree status codes. A rename/copy entry (X or Y is
//!   'R'/'C') is followed by a SECOND NUL-terminated field holding the
//!   ORIGINAL path; the FIRST path is the current (new) one we snapshot.
//!   '??' marks an untracked file; 'D' in either slot marks a deletion.

const std = @import("std");
const db = @import("db.zig");

// ------------------------------------------------------- argv builders

/// Max argv slots any builder here needs.
pub const max_argv = 8;

/// Build `git -C <path> status --porcelain=v1 -z --untracked-files=all`.
pub fn statusArgv(argv: *[max_argv][]const u8, repo_path: []const u8) [][]const u8 {
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = repo_path;
    argv[3] = "status";
    argv[4] = "--porcelain=v1";
    argv[5] = "-z";
    argv[6] = "--untracked-files=all";
    return argv[0..7];
}

/// Build `git -C <path> diff -- <rel_path>` (worktree diff vs the index).
/// Untracked files produce no diff here (git diff ignores them); the
/// snapshot's `diff` is then just empty, which the schema allows.
pub fn diffArgv(argv: *[max_argv][]const u8, repo_path: []const u8, rel_path: []const u8) [][]const u8 {
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = repo_path;
    argv[3] = "diff";
    argv[4] = "--";
    argv[5] = rel_path;
    return argv[0..6];
}

// ------------------------------------------------------- status parser

/// One changed working-tree entry from `git status --porcelain -z`.
pub const Change = struct {
    /// Staged (index) status code, e.g. 'M', 'A', 'R', ' ', '?'.
    x: u8,
    /// Worktree status code.
    y: u8,
    /// Current path relative to the repo root (the NEW path for renames).
    rel_path: []const u8,

    /// A deletion — the file no longer exists in the working tree, so
    /// there is no content to snapshot. (Recording deletions is a
    /// follow-up; for now we skip them.)
    pub fn isDelete(self: Change) bool {
        return self.x == 'D' or self.y == 'D';
    }

    /// Untracked (never added). Its content is snapshot-worthy; its diff
    /// is empty (git diff ignores untracked files).
    pub fn isUntracked(self: Change) bool {
        return self.x == '?' and self.y == '?';
    }

    /// Whether X/Y denote a rename or copy, which carries a second
    /// (original) path field in the -z stream.
    pub fn isRenameOrCopy(self: Change) bool {
        return self.x == 'R' or self.x == 'C' or self.y == 'R' or self.y == 'C';
    }
};

pub const ParseError = error{Malformed};

/// Streaming parser over `git status --porcelain=v1 -z` output. Each call
/// yields the next changed entry (borrowing paths from the input), or null
/// at end of input.
pub const StatusParser = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn init(bytes: []const u8) StatusParser {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *StatusParser) ParseError!?Change {
        if (self.at >= self.bytes.len) return null;
        // A record: 2 status chars, a space, the path, then NUL.
        const rec = self.readField() orelse return null;
        if (rec.len < 4) return error.Malformed; // "XY p" minimum
        const x = rec[0];
        const y = rec[1];
        // rec[2] is the separating space; the path is the remainder.
        const rel_path = rec[3..];
        var change = Change{ .x = x, .y = y, .rel_path = rel_path };
        // Renames/copies carry a trailing original-path field we consume
        // and discard (we snapshot the current path).
        if (change.isRenameOrCopy()) {
            _ = self.readField();
        }
        return change;
    }

    /// Read up to (not including) the next NUL, advancing past it. Returns
    /// null when there is nothing left.
    fn readField(self: *StatusParser) ?[]const u8 {
        if (self.at >= self.bytes.len) return null;
        const nul = std.mem.indexOfScalarPos(u8, self.bytes, self.at, 0);
        if (nul) |end| {
            const field = self.bytes[self.at..end];
            self.at = end + 1;
            return field;
        }
        // No terminating NUL (shouldn't happen with -z) — take the rest.
        const field = self.bytes[self.at..];
        self.at = self.bytes.len;
        return field;
    }
};

/// Collect the snapshot-worthy changed paths (skips deletions) into a
/// caller-owned buffer of `Change`, returning the filled slice.
pub fn parseStatus(out: []Change, bytes: []const u8) ParseError![]Change {
    var parser = StatusParser.init(bytes);
    var n: usize = 0;
    while (n < out.len) {
        const c = (try parser.next()) orelse break;
        if (c.isDelete()) continue;
        if (c.rel_path.len == 0) continue;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

// ------------------------------------------------------- content hashing

/// Length of a SHA-256 hex digest.
pub const hash_hex_len = 64;

/// Write the lowercase SHA-256 hex digest of `content` into `out`.
pub fn sha256Hex(content: []const u8, out: *[hash_hex_len]u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

// ---------------------------------------------- file_snapshots statements

pub const insert_sql =
    "INSERT INTO file_snapshots(repo_id, rel_path, content, diff, content_hash, byte_len, captured_at) " ++
    "VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7);";

pub const insert_param_count = 7;

/// Fill a caller-owned param buffer for one snapshot insert. The buffer
/// (and all borrowed slices) MUST outlive the `dbExec` call — params are
/// copied at call time.
pub fn insertStatement(
    buf: *[insert_param_count]db.Value,
    repo_id: i64,
    rel_path: []const u8,
    content: []const u8,
    diff: []const u8,
    content_hash: []const u8,
    now_ms: i64,
) db.Statement {
    buf.* = .{
        db.val.int(repo_id),
        db.val.text(rel_path),
        db.val.text(content),
        db.val.text(diff),
        db.val.text(content_hash),
        db.val.int(@intCast(content.len)),
        db.val.int(now_ms),
    };
    return .{ .sql = insert_sql, .params = buf };
}

/// The most recent stored content hash for a (repo, path), so an unchanged
/// save can be skipped. Returns 0 or 1 rows.
pub const select_last_hash_sql =
    "SELECT content_hash FROM file_snapshots WHERE repo_id = ?1 AND rel_path = ?2 " ++
    "ORDER BY captured_at DESC LIMIT 1;";

pub fn lastHashParams(buf: *[2]db.Value, repo_id: i64, rel_path: []const u8) []const db.Value {
    buf.* = .{ db.val.int(repo_id), db.val.text(rel_path) };
    return buf;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "statusArgv builds the porcelain -z command" {
    var argv: [max_argv][]const u8 = undefined;
    const cmd = statusArgv(&argv, "/Users/rui/repo");
    try testing.expectEqual(@as(usize, 7), cmd.len);
    try testing.expectEqualStrings("git", cmd[0]);
    try testing.expectEqualStrings("/Users/rui/repo", cmd[2]);
    try testing.expectEqualStrings("status", cmd[3]);
    try testing.expectEqualStrings("--porcelain=v1", cmd[4]);
    try testing.expectEqualStrings("-z", cmd[5]);
    try testing.expectEqualStrings("--untracked-files=all", cmd[6]);
}

test "diffArgv builds a scoped worktree diff" {
    var argv: [max_argv][]const u8 = undefined;
    const cmd = diffArgv(&argv, "/r", "src/a.zig");
    try testing.expectEqual(@as(usize, 6), cmd.len);
    try testing.expectEqualStrings("diff", cmd[3]);
    try testing.expectEqualStrings("--", cmd[4]);
    try testing.expectEqualStrings("src/a.zig", cmd[5]);
}

test "parseStatus reads modified + untracked entries" {
    // " M README.md\0?? scratch.txt\0"  (verified real format)
    const out = " M README.md\x00?? scratch.txt\x00";
    var buf: [8]Change = undefined;
    const changes = try parseStatus(&buf, out);
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqual(@as(u8, ' '), changes[0].x);
    try testing.expectEqual(@as(u8, 'M'), changes[0].y);
    try testing.expectEqualStrings("README.md", changes[0].rel_path);
    try testing.expect(changes[1].isUntracked());
    try testing.expectEqualStrings("scratch.txt", changes[1].rel_path);
}

test "parseStatus consumes the original path of a rename entry" {
    // "R  new.md\0old.md\0M  other.zig\0" — rename carries a 2nd field.
    const out = "R  new.md\x00old.md\x00M  other.zig\x00";
    var buf: [8]Change = undefined;
    const changes = try parseStatus(&buf, out);
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("new.md", changes[0].rel_path);
    try testing.expect(changes[0].isRenameOrCopy());
    // The original path field must have been skipped, not parsed as a row.
    try testing.expectEqualStrings("other.zig", changes[1].rel_path);
}

test "parseStatus skips deletions (no content to snapshot)" {
    const out = " D gone.txt\x00 M kept.txt\x00";
    var buf: [8]Change = undefined;
    const changes = try parseStatus(&buf, out);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("kept.txt", changes[0].rel_path);
}

test "parseStatus on empty output yields nothing" {
    var buf: [4]Change = undefined;
    const changes = try parseStatus(&buf, "");
    try testing.expectEqual(@as(usize, 0), changes.len);
}

test "sha256Hex matches a known digest" {
    var out: [hash_hex_len]u8 = undefined;
    sha256Hex("abc", &out);
    // SHA-256("abc")
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &out,
    );
    // Empty input digest.
    sha256Hex("", &out);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &out,
    );
}

test "sha256Hex differs for different content (change detection)" {
    var a: [hash_hex_len]u8 = undefined;
    var b: [hash_hex_len]u8 = undefined;
    sha256Hex("version one\n", &a);
    sha256Hex("version two\n", &b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "insertStatement carries snapshot fields incl. byte_len" {
    var buf: [insert_param_count]db.Value = undefined;
    const stmt = insertStatement(&buf, 3, "src/a.zig", "hello", "@@ diff @@", "abc123", 777);
    try testing.expectEqual(@as(usize, insert_param_count), stmt.params.len);
    try testing.expectEqual(@as(i64, 3), stmt.params[0].integer);
    try testing.expectEqualStrings("src/a.zig", stmt.params[1].text);
    try testing.expectEqualStrings("hello", stmt.params[2].text);
    try testing.expectEqualStrings("@@ diff @@", stmt.params[3].text);
    try testing.expectEqualStrings("abc123", stmt.params[4].text);
    try testing.expectEqual(@as(i64, 5), stmt.params[5].integer); // byte_len
    try testing.expectEqual(@as(i64, 777), stmt.params[6].integer);
}

// ---- Real-database integration tests ----

const native_sdk = @import("native_sdk");
const relational_store = native_sdk.runtime.relational_store;
const IntMsg = union(enum) { db: native_sdk.EffectDbResult };
const IntFx = native_sdk.Effects(IntMsg);

test "snapshot inserts and the last-hash query reflects the newest content" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = IntFx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    // A repo to attach snapshots to.
    fx.dbExec(.{ .key = 1, .statements = &.{
        .{ .sql = "INSERT INTO repos(id, path, name, added_at) VALUES(1, '/r', 'r', 1);" },
    }, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // Two snapshots of the same file (older then newer content).
    var h1: [hash_hex_len]u8 = undefined;
    var h2: [hash_hex_len]u8 = undefined;
    sha256Hex("one", &h1);
    sha256Hex("two", &h2);
    var p1: [insert_param_count]db.Value = undefined;
    fx.dbExec(.{ .key = 2, .statements = &.{insertStatement(&p1, 1, "a.txt", "one", "", &h1, 100)}, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);
    var p2: [insert_param_count]db.Value = undefined;
    fx.dbExec(.{ .key = 3, .statements = &.{insertStatement(&p2, 1, "a.txt", "two", "@@ @@", &h2, 200)}, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // The last-hash query returns the newest (captured_at DESC) hash.
    var hbuf: [2]db.Value = undefined;
    fx.dbQuery(.{ .key = 4, .sql = select_last_hash_sql, .params = lastHashParams(&hbuf, 1, "a.txt"), .on_result = IntFx.dbMsg(.db) });
    const page = fx.takeMsg().?.db;
    try testing.expectEqual(native_sdk.EffectDbResultKind.page, page.kind);
    var reader = try db.PageReader.init(page.bytes);
    try testing.expectEqual(@as(usize, 1), reader.rowCount());
    var row: [1]db.ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;
    try testing.expectEqualStrings(&h2, cols[0].asText().?);
    _ = fx.takeMsg(); // .done

    // Both snapshots are retained (history), and byte_len was stored.
    fx.dbQuery(.{ .key = 5, .sql = "SELECT COUNT(*), MAX(byte_len) FROM file_snapshots WHERE repo_id=1 AND rel_path='a.txt';", .on_result = IntFx.dbMsg(.db) });
    const cpage = fx.takeMsg().?.db;
    var creader = try db.PageReader.init(cpage.bytes);
    var crow: [2]db.ColumnValue = undefined;
    const ccols = (try creader.next(&crow)).?;
    try testing.expectEqual(@as(i64, 2), ccols[0].asInt().?);
    try testing.expectEqual(@as(i64, 3), ccols[1].asInt().?); // len("two")
    _ = fx.takeMsg(); // .done
}
