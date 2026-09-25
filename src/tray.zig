//! Tray / menu-bar (status item) menu definition — PURE and unit-testable.
//!
//! The tray itself is declarative in the Native SDK: `UiApp.Options` exposes
//! `status_item_fn(model, scratch) StatusItemState`, and the runtime calls
//! the Runtime-level `createStatusItem`/`updateStatusItem*` for us. So the
//! only app-side logic is (a) building the menu item list and (b) mapping the
//! menu `command` strings back to `Msg`s in `on_command`. Both live here as
//! pure functions; the effectful window/quit calls stay in main.zig.
//!
//! Menu items carry a `command` string; when a row is chosen the runtime
//! routes that string through `Options.on_command(name) ?Msg`.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub const TrayMenuItem = native_sdk.TrayMenuItem;

// Command names routed through `on_command`. Kept here so main.zig's
// `on_command` and this builder can never drift apart.
pub const cmd_open = "blocks.open_window";
pub const cmd_quit = "blocks.quit";

/// Number of menu rows `buildMenu` produces (Open, sep, Quit). Callers size
/// their item buffer to at least this.
pub const menu_len = 3;

/// Fill `buf` (>= `menu_len`) with the tray menu and return the used slice.
pub fn buildMenu(buf: []TrayMenuItem) []const TrayMenuItem {
    std.debug.assert(buf.len >= menu_len);
    buf[0] = .{ .id = 1, .label = "Open Blocks", .command = cmd_open };
    buf[1] = .{ .id = 2, .separator = true };
    buf[2] = .{ .id = 3, .label = "Quit Blocks", .command = cmd_quit };
    return buf[0..menu_len];
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "buildMenu lays out the rows with stable commands" {
    var buf: [menu_len]TrayMenuItem = undefined;
    const menu = buildMenu(&buf);
    try testing.expectEqual(@as(usize, menu_len), menu.len);

    try testing.expectEqualStrings("Open Blocks", menu[0].label);
    try testing.expectEqualStrings(cmd_open, menu[0].command);
    try testing.expect(!menu[0].separator);

    try testing.expect(menu[1].separator);

    try testing.expectEqualStrings("Quit Blocks", menu[2].label);
    try testing.expectEqualStrings(cmd_quit, menu[2].command);
}

test "menu ids are unique and non-zero for actionable rows" {
    var buf: [menu_len]TrayMenuItem = undefined;
    const menu = buildMenu(&buf);
    var seen = [_]bool{false} ** (menu_len + 1);
    for (menu) |item| {
        try testing.expect(item.id != 0);
        try testing.expect(item.id <= menu_len);
        try testing.expect(!seen[item.id]);
        seen[item.id] = true;
    }
}
