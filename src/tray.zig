//! Tray / menu-bar (status item) menu definition — PURE and unit-testable.
//!
//! The tray itself is declarative in the Native SDK: `UiApp.Options` exposes
//! `status_item_fn(model, scratch) StatusItemState`, and the runtime calls
//! the Runtime-level `createStatusItem`/`updateStatusItem*` for us. So the
//! only app-side logic is (a) building the menu item list and (b) mapping the
//! menu `command` strings back to `Msg`s in `on_command`. Both live here as
//! pure functions; the effectful window/quit/login-item calls stay in main.zig.
//!
//! Menu items carry a `command` string; when a row is chosen the runtime
//! routes that string through `Options.on_command(name) ?Msg`.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub const TrayMenuItem = native_sdk.TrayMenuItem;

// Command names routed through `on_command`. Kept here so main.zig's
// `on_command` and this builder can never drift apart.
pub const cmd_open = "blocks.open_window";
pub const cmd_toggle_login = "blocks.toggle_login";
pub const cmd_quit = "blocks.quit";

/// The label for the login-at-launch toggle row, reflecting current state.
/// A leading check mark communicates "on" without relying on native
/// checkbox styling (which varies across the tray backends).
pub fn loginToggleLabel(enabled: bool) []const u8 {
    return if (enabled) "✓ Start at Login" else "Start at Login";
}

/// Number of menu rows `buildMenu` produces (Open, sep, Start-at-Login,
/// sep, Quit). Callers size their item buffer to at least this.
pub const menu_len = 5;

/// Fill `buf` (>= `menu_len`) with the tray menu and return the used slice.
/// `login_enabled` drives the toggle label; `login_supported` disables the
/// toggle on platforms/builds where launch-at-login is unavailable.
pub fn buildMenu(buf: []TrayMenuItem, login_enabled: bool, login_supported: bool) []const TrayMenuItem {
    std.debug.assert(buf.len >= menu_len);
    buf[0] = .{ .id = 1, .label = "Open Blocks", .command = cmd_open };
    buf[1] = .{ .id = 2, .separator = true };
    buf[2] = .{
        .id = 3,
        .label = loginToggleLabel(login_enabled),
        .command = cmd_toggle_login,
        .enabled = login_supported,
    };
    buf[3] = .{ .id = 4, .separator = true };
    buf[4] = .{ .id = 5, .label = "Quit Blocks", .command = cmd_quit };
    return buf[0..menu_len];
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "loginToggleLabel reflects enabled state" {
    try testing.expectEqualStrings("✓ Start at Login", loginToggleLabel(true));
    try testing.expectEqualStrings("Start at Login", loginToggleLabel(false));
}

test "buildMenu lays out the rows with stable commands" {
    var buf: [menu_len]TrayMenuItem = undefined;
    const menu = buildMenu(&buf, false, true);
    try testing.expectEqual(@as(usize, menu_len), menu.len);

    try testing.expectEqualStrings("Open Blocks", menu[0].label);
    try testing.expectEqualStrings(cmd_open, menu[0].command);
    try testing.expect(!menu[0].separator);

    try testing.expect(menu[1].separator);

    try testing.expectEqualStrings("Start at Login", menu[2].label);
    try testing.expectEqualStrings(cmd_toggle_login, menu[2].command);
    try testing.expect(menu[2].enabled);

    try testing.expect(menu[3].separator);

    try testing.expectEqualStrings("Quit Blocks", menu[4].label);
    try testing.expectEqualStrings(cmd_quit, menu[4].command);
}

test "buildMenu shows a check and can disable the toggle" {
    var buf: [menu_len]TrayMenuItem = undefined;
    const menu = buildMenu(&buf, true, false);
    try testing.expectEqualStrings("✓ Start at Login", menu[2].label);
    try testing.expect(!menu[2].enabled); // unsupported -> disabled
}

test "menu ids are unique and non-zero for actionable rows" {
    var buf: [menu_len]TrayMenuItem = undefined;
    const menu = buildMenu(&buf, false, true);
    var seen = [_]bool{false} ** (menu_len + 1);
    for (menu) |item| {
        try testing.expect(item.id != 0);
        try testing.expect(item.id <= menu_len);
        try testing.expect(!seen[item.id]);
        seen[item.id] = true;
    }
}
