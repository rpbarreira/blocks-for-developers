//! Environment variable access via libc's `environ` block. The app links
//! libc (the build passes `-lc`), and the SDK itself reads `std.c.environ`
//! for the same reason (see effects.zig `fallbackEnviron`), so this is the
//! stable seam rather than the moving `std.process` env API in Zig 0.16.
//!
//! `get` returns a slice that borrows directly from the process
//! environment block; it is valid for the life of the process and must
//! not be freed.

const std = @import("std");
const builtin = @import("builtin");

/// Look up an environment variable by name. Returns null if unset.
/// The returned slice borrows from the process environment block.
pub fn get(name: []const u8) ?[]const u8 {
    if (comptime !builtin.link_libc) return null;
    const envp = std.c.environ;
    var i: usize = 0;
    while (envp[i]) |entry_ptr| : (i += 1) {
        const entry = std.mem.span(entry_ptr);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            return entry[eq + 1 ..];
        }
    }
    return null;
}

/// Function-pointer wrapper matching the `lookup` signature used by the
/// pure helpers in config.zig, so the real environment can be injected
/// into `detectUsername` / `detectHome`.
pub fn lookup(name: []const u8) ?[]const u8 {
    return get(name);
}
