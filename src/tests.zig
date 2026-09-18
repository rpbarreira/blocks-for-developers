const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

// Pull in the pure module unit tests (config path/username logic and the
// bootstrap content/decisions).
comptime {
    _ = @import("config.zig");
    _ = @import("bootstrap.zig");
    _ = @import("env.zig");
    _ = @import("db.zig");
    _ = @import("repos.zig");
    _ = @import("git.zig");
    _ = @import("snapshots.zig");
    _ = @import("tray.zig");
    _ = @import("embed_core.zig");
    _ = @import("embeddings.zig");
    // Local model management + llama.cpp runtime (Task 9): pure catalog,
    // path/argv builders, progress + config parsing.
    _ = @import("models.zig");
    // Chat data layer + local-LLM protocol shaping (Task 10).
    _ = @import("chat.zig");
    // Snippets ("materials") data layer (Task 12).
    _ = @import("snippets.zig");
    // MCP server core (Task 8): pure protocol + tool builders, plus the
    // real-DB integration tests for each tool's SQL + JSON shaping.
    _ = @import("mcp/protocol.zig");
    _ = @import("mcp/tools.zig");
    _ = @import("mcp/mcp_tools.zig");
}

const canvas = native_sdk.canvas;
const AppMarkup = canvas.MarkupView(main.Model, main.Msg);
const AppUi = main.AppUi;

fn buildTree(arena: std.mem.Allocator, model: *const main.Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

test "the boot shell view builds against the model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.Model{
        .username = "rui",
        .data_dir = "/Users/rui/Library/Application Support/dev.blocks.app",
        .onboarded = true,
    };
    const tree = try buildTree(arena, &model);
    // The username must appear somewhere in the rendered tree.
    var found_username = false;
    const walk = struct {
        fn f(w: canvas.Widget, hit: *bool) void {
            if (std.mem.indexOf(u8, w.text, "rui") != null) hit.* = true;
            for (w.children) |c| f(c, hit);
        }
    };
    walk.f(tree.root, &found_username);
    try std.testing.expect(found_username);
}

test "update: existing config marks the user onboarded" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A successful stat with exists=true = returning user.
    main.update(&m, .{ .stat_config = .{ .key = 100, .op = .stat, .outcome = .ok, .exists = true } }, &fx);
    try std.testing.expect(m.onboarded);
}

test "update: a successful first-run config write leaves the user not onboarded" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .wrote_config = .{ .key = 101, .op = .write, .outcome = .ok } }, &fx);
    try std.testing.expect(!m.onboarded);
}

// ---- Tray + launch-at-login (Task 6) ----

test "update: tray Open reveals the main window" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .open_window, &fx);
    const s = fx.windowActionState();
    try std.testing.expectEqual(@as(u32, 1), s.show_count);
    try std.testing.expectEqualStrings("main", s.lastLabel());
}

test "update: tray Quit asks the app to quit" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .quit_app, &fx);
    try std.testing.expectEqual(@as(u32, 1), fx.windowActionState().quit_count);
}

test "update: login status result 'enabled' turns the toggle on" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .login_status_done = .{ .key = 140, .ok = true, .bytes = "enabled" } }, &fx);
    try std.testing.expect(m.login_enabled);
    try std.testing.expect(m.login_supported);
}

test "update: login result 'disabled' turns the toggle off" {
    var m = main.Model{ .login_enabled = true };
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .login_set_done = .{ .key = 141, .ok = true, .bytes = "disabled" } }, &fx);
    try std.testing.expect(!m.login_enabled);
}

test "update: 'requires_approval' counts as enabled (item registered)" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .login_status_done = .{ .key = 140, .ok = true, .bytes = "requires_approval" } }, &fx);
    try std.testing.expect(m.login_enabled);
}

test "update: an 'unsupported' failure disables the toggle" {
    var m = main.Model{ .login_supported = true };
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .login_set_done = .{ .key = 141, .ok = false, .bytes = "unsupported" } }, &fx);
    try std.testing.expect(!m.login_supported);
}

test "update: toggling login while unsupported is a no-op" {
    var m = main.Model{ .login_supported = false, .login_enabled = false };
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Should not flip the model or crash; the host is never asked.
    main.update(&m, .toggle_login, &fx);
    try std.testing.expect(!m.login_enabled);
}

// ---- MCP server child process (Task 8) ----

test "update: a 200 tools/list health response marks the MCP server ready" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .mcp_health_done = .{ .key = 161, .outcome = .ok, .status = 200, .body = "{\"jsonrpc\":\"2.0\"}" } }, &fx);
    try std.testing.expect(m.mcp_ready);
    try std.testing.expect(!m.mcp_failed);
}

test "update: a failed health response leaves the MCP server not-ready (non-fatal)" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A connection failure while the child is still binding, under the retry
    // cap: not ready, but not marked failed either — a retry is armed.
    main.update(&m, .{ .mcp_health_done = .{ .key = 161, .outcome = .rejected, .status = 0, .body = "" } }, &fx);
    try std.testing.expect(!m.mcp_ready);
    try std.testing.expect(!m.mcp_failed);
}

test "update: an MCP health tick increments the attempt counter" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try std.testing.expectEqual(@as(u32, 0), m.mcp_health_attempts);
    main.update(&m, .{ .mcp_health_tick = .{ .key = 2, .outcome = .fired } }, &fx);
    try std.testing.expectEqual(@as(u32, 1), m.mcp_health_attempts);
}

test "update: MCP health retries while under the cap, then gives up" {
    var m = main.Model{};
    m.mcp_health_attempts = 1; // one attempt made, well under the cap
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A non-200 under the cap leaves it not-ready + not-failed (a retry is armed).
    main.update(&m, .{ .mcp_health_done = .{ .key = 161, .outcome = .connect_failed, .status = 0, .body = "" } }, &fx);
    try std.testing.expect(!m.mcp_ready);
    try std.testing.expect(!m.mcp_failed);

    // At the cap, give up: mark failed (non-fatal).
    m.mcp_health_attempts = 20; // == mcp_health_max_attempts
    main.update(&m, .{ .mcp_health_done = .{ .key = 161, .outcome = .connect_failed, .status = 0, .body = "" } }, &fx);
    try std.testing.expect(!m.mcp_ready);
    try std.testing.expect(m.mcp_failed);
}

test "update: the MCP child exiting marks it failed but does not crash" {
    var m = main.Model{ .mcp_ready = true };
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .mcp_exit = .{ .key = 160, .code = 1, .reason = .exited } }, &fx);
    try std.testing.expect(!m.mcp_ready);
    try std.testing.expect(m.mcp_failed);
}

test "update: a rejected health-check timer tick is ignored" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A rejected timer must not fire a fetch or change state.
    main.update(&m, .{ .mcp_health_tick = .{ .key = 2, .outcome = .rejected } }, &fx);
    try std.testing.expect(!m.mcp_ready);
    try std.testing.expect(!m.mcp_failed);
}

// ---- Local model management + llama.cpp runtime (Task 9) ----

const models = @import("models.zig");

test "update: config_read_done adopts the selected model id from config" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const cfg =
        \\{ "version": "0.1.0", "username": "rui", "selected_model": "qwen2.5-1.5b-instruct-q4" }
    ;
    main.update(&m, .{ .config_read_done = .{ .key = 170, .op = .read, .outcome = .ok, .bytes = cfg, .exists = true } }, &fx);
    try std.testing.expectEqualStrings("qwen2.5-1.5b-instruct-q4", m.selectedModel());
}

test "update: model_stat_done present=true marks the model present" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .model_stat_done = .{ .key = 171, .op = .stat, .outcome = .ok, .exists = true } }, &fx);
    try std.testing.expect(m.model_present);
}

test "update: model_stat_done absent leaves the model not present" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .model_stat_done = .{ .key = 171, .op = .stat, .outcome = .ok, .exists = false } }, &fx);
    try std.testing.expect(!m.model_present);
}

test "update: select_model switches the selection and marks it not present" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Pick a different catalog entry by index.
    var target: usize = 0;
    for (models.catalog, 0..) |c, i| {
        if (!std.mem.eql(u8, c.id, m.selectedModel())) {
            target = i;
            break;
        }
    }
    main.update(&m, .{ .select_model = target }, &fx);
    try std.testing.expectEqualStrings(models.catalog[target].id, m.selectedModel());
    try std.testing.expect(!m.model_present);
}

test "update: out-of-range select_model is ignored" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const before = m.selectedModel();
    main.update(&m, .{ .select_model = 9999 }, &fx);
    try std.testing.expectEqualStrings(before, m.selectedModel());
}

test "update: a curl progress line updates download_progress" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // key 172 is the download spawn key; a 40% bar line -> 0.40.
    main.update(&m, .{ .download_progress_line = .{ .key = 172, .line = "########            40.0%" } }, &fx);
    try std.testing.expectApproxEqAbs(@as(f32, 0.40), m.download_progress, 0.0001);
    try std.testing.expectEqual(@as(i64, 40), m.downloadPercent());
}

test "update: a failed download marks download_failed and clears downloading" {
    var m = main.initialModel();
    m.downloading = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .download_done = .{ .key = 172, .code = 22, .reason = .exited } }, &fx);
    try std.testing.expect(!m.downloading);
    try std.testing.expect(m.download_failed);
}

test "update: a failed rename marks the download failed" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .model_renamed = .{ .key = 173, .code = 1, .reason = .exited } }, &fx);
    try std.testing.expect(m.download_failed);
    try std.testing.expect(!m.model_present);
}

test "update: a 200 llama /health response marks the runtime ready" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .llama_health_done = .{ .key = 175, .outcome = .ok, .status = 200, .body = "ok" } }, &fx);
    try std.testing.expect(m.llama_ready);
    try std.testing.expect(!m.llama_failed);
}

test "update: the llama child exiting marks the runtime failed (non-fatal)" {
    var m = main.initialModel();
    m.llama_ready = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .llama_exit = .{ .key = 174, .code = 127, .reason = .spawn_failed } }, &fx);
    try std.testing.expect(!m.llama_ready);
    try std.testing.expect(m.llama_failed);
}

test "update: a rejected llama health tick is ignored" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .llama_health_tick = .{ .key = 3, .outcome = .rejected } }, &fx);
    try std.testing.expect(!m.llama_ready);
    try std.testing.expect(!m.llama_failed);
}

test "update: a non-200 llama health response retries while under the cap" {
    var m = main.initialModel();
    m.llama_health_attempts = 1; // one attempt made, far below the cap
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Connection refused while the model is still loading: not ready, not
    // failed — a retry timer should be armed (still under the attempt cap).
    main.update(&m, .{ .llama_health_done = .{ .key = 175, .outcome = .connect_failed, .status = 0, .body = "" } }, &fx);
    try std.testing.expect(!m.llama_ready);
    try std.testing.expect(!m.llama_failed);
}

test "update: llama health gives up (failed) once the attempt cap is reached" {
    var m = main.initialModel();
    m.llama_health_attempts = 40; // == llama_health_max_attempts
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .llama_health_done = .{ .key = 175, .outcome = .connect_failed, .status = 0, .body = "" } }, &fx);
    try std.testing.expect(!m.llama_ready);
    try std.testing.expect(m.llama_failed);
}

test "update: a health tick increments the attempt counter" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try std.testing.expectEqual(@as(u32, 0), m.llama_health_attempts);
    main.update(&m, .{ .llama_health_tick = .{ .key = 3, .outcome = .fired } }, &fx);
    try std.testing.expectEqual(@as(u32, 1), m.llama_health_attempts);
}

// ---- Chat experience (Task 10) ----

const chat = @import("chat.zig");

test "update: send_chat is a no-op when the runtime is not ready" {
    var m = main.initialModel();
    m.llama_ready = false;
    m.chat_input.set("hello");
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .send_chat, &fx);
    // Nothing sent, no optimistic message, an error surfaced.
    try std.testing.expect(!m.sending);
    try std.testing.expectEqual(@as(usize, 0), m.message_count);
}

test "update: send_chat shows the user message and begins the turn" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.mcp_ready = false; // skip MCP search -> go straight to completion
    m.chat_input.set("what did I do?");
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .send_chat, &fx);
    try std.testing.expect(m.sending);
    // The user message is shown immediately, input cleared.
    try std.testing.expectEqual(@as(usize, 1), m.message_count);
    try std.testing.expect(m.messagesSlice()[0].isUser());
    try std.testing.expectEqualStrings("what did I do?", m.messagesSlice()[0].content());
    try std.testing.expect(m.chat_input.isEmpty());
    // With MCP not ready we go straight to a streamed completion.
    try std.testing.expect(m.isStreaming());
}

test "update: send_chat ignores empty/whitespace input" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.chat_input.set("   ");
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .send_chat, &fx);
    try std.testing.expect(!m.sending);
    try std.testing.expectEqual(@as(usize, 0), m.message_count);
}

test "update: a streamed chat line appends a token to the reply" {
    var m = main.initialModel();
    m.streaming = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // key 181 is the llama chat stream key.
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}" } }, &fx);
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}" } }, &fx);
    try std.testing.expectEqualStrings("Hello there", m.streamingText());
}

test "update: chat lines are ignored when not streaming" {
    var m = main.initialModel();
    m.streaming = false;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}" } }, &fx);
    try std.testing.expectEqualStrings("", m.streamingText());
}

test "update: chat_done finalizes the streamed reply into a message" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.sending = true;
    m.streaming = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Accumulate a streamed reply, then end the stream cleanly.
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: {\"choices\":[{\"delta\":{\"content\":\"A commit is a snapshot.\"}}]}" } }, &fx);
    main.update(&m, .{ .chat_done = .{ .key = 181, .outcome = .ok, .status = 200, .body = "" } }, &fx);

    // The reply becomes an assistant message; streaming ends.
    try std.testing.expect(!m.isStreaming());
    try std.testing.expectEqual(@as(usize, 1), m.message_count);
    try std.testing.expect(m.messagesSlice()[0].isAssistant());
    try std.testing.expectEqualStrings("A commit is a snapshot.", m.messagesSlice()[0].content());
}

test "update: the [DONE] sentinel finalizes the streamed reply into a message" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.sending = true;
    m.streaming = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A token arrives, then the `[DONE]` sentinel line ends the turn (the
    // runtime keeps the socket open, so the terminal response would lag).
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: {\"choices\":[{\"delta\":{\"content\":\"Done reply.\"}}]}" } }, &fx);
    try std.testing.expect(m.isStreaming());
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: [DONE]" } }, &fx);
    try std.testing.expect(!m.isStreaming());
    try std.testing.expect(m.messagesSlice()[m.message_count - 1].isAssistant());
    try std.testing.expectEqualStrings("Done reply.", m.messagesSlice()[m.message_count - 1].content());
}

test "update: sending stays gated through persistence until chat_write_done" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.sending = true;
    m.streaming = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Finish the stream. The turn is NOT done yet — the async persist chain
    // (INSERT chat -> MAX(id) -> write) is still pending, so `sending` must
    // remain set to keep a second turn from overlapping the id recovery.
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: {\"choices\":[{\"delta\":{\"content\":\"Reply.\"}}]}" } }, &fx);
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: [DONE]" } }, &fx);
    try std.testing.expect(!m.isStreaming());
    try std.testing.expect(m.sending); // still gated
    try std.testing.expect(!m.canSend());

    // A second send while gated is a no-op (no extra user message).
    const before = m.message_count;
    m.chat_input.set("second question");
    main.update(&m, .send_chat, &fx);
    try std.testing.expectEqual(before, m.message_count);

    // Only once the write commits does the turn end and input re-enable.
    main.update(&m, .{ .chat_write_done = .{ .key = 184, .kind = .exec, .outcome = .ok } }, &fx);
    try std.testing.expect(!m.sending);
    try std.testing.expect(m.canSend());
}

test "update: a second finalize for the same turn is a no-op" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.sending = true;
    m.streaming = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: {\"choices\":[{\"delta\":{\"content\":\"Once.\"}}]}" } }, &fx);
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: [DONE]" } }, &fx); // finalize
    const count = m.message_count;
    // The terminal chat_done (arrives .cancelled after our fx.cancel) must not
    // finalize again — no duplicate assistant message.
    main.update(&m, .{ .chat_done = .{ .key = 181, .outcome = .cancelled, .status = 0, .body = "" } }, &fx);
    try std.testing.expectEqual(count, m.message_count);
}

test "update: a failed chat_done keeps the user message and clears sending" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.sending = true;
    m.streaming = true;
    m.pushMessage(.user, "hi");
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A connection failure mid-stream with nothing accumulated.
    main.update(&m, .{ .chat_done = .{ .key = 181, .outcome = .connect_failed, .status = 0, .body = "" } }, &fx);
    try std.testing.expect(!m.isStreaming());
    try std.testing.expect(!m.sending);
    // The user's message stays visible so they can retry.
    try std.testing.expectEqual(@as(usize, 1), m.message_count);
}

test "update: mcp_search_done builds context then starts the completion" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.sending = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A well-formed search result should not crash and should proceed to
    // stream a completion (RAG best-effort: even 200 with hits -> streaming).
    // The MCP envelope wraps the tool JSON as result.content[0].text, with the
    // inner JSON's quotes escaped (hand-escaped here).
    const envelope =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":" ++
        "\"{\\\"query\\\":\\\"x\\\",\\\"results\\\":[{\\\"repo\\\":\\\"blocks\\\",\\\"title\\\":\\\"t\\\",\\\"snippet\\\":\\\"s\\\"}]}\"" ++
        "}],\"isError\":false}}";

    main.update(&m, .{ .mcp_search_done = .{ .key = 180, .outcome = .ok, .status = 200, .body = envelope } }, &fx);
    try std.testing.expect(m.isStreaming());
}

// ---- Single-click summaries (Task 11) ----

test "update: start_summary is a no-op when the runtime is not ready" {
    var m = main.initialModel();
    m.llama_ready = false;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .start_summary = .day_recap }, &fx);
    try std.testing.expect(!m.sending);
    try std.testing.expectEqual(@as(usize, 0), m.message_count);
    try std.testing.expect(m.pending_summary_kind == null);
}

test "update: start_summary begins a canned turn and shows the prompt" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.mcp_ready = false; // skip get_activity -> straight to completion
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .start_summary = .standup }, &fx);
    try std.testing.expect(m.sending);
    try std.testing.expect(m.pending_summary_kind.? == .standup);
    // The canned prompt is shown immediately as the user message, and we
    // stream a completion (MCP not ready -> no activity retrieval step).
    try std.testing.expectEqual(@as(usize, 1), m.message_count);
    try std.testing.expect(m.messagesSlice()[0].isUser());
    try std.testing.expectEqualStrings(chat.SummaryKind.standup.prompt(), m.messagesSlice()[0].content());
    try std.testing.expect(m.isStreaming());
}

test "update: start_summary resets any prior conversation (fresh chat)" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.mcp_ready = false;
    // Seed a prior conversation.
    m.current_chat_id = 7;
    m.next_seq = 4;
    m.pushMessage(.user, "old question");
    m.pushMessage(.assistant, "old answer");
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .start_summary = .day_recap }, &fx);
    // A summary is a NEW conversation: chat id + seq reset, only the prompt shown.
    try std.testing.expectEqual(@as(i64, 0), m.current_chat_id);
    try std.testing.expectEqual(@as(usize, 1), m.message_count);
    try std.testing.expect(m.pending_summary_kind.? == .day_recap);
}

test "update: a summary turn stays gated while another summary is in flight" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.mcp_ready = false;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .start_summary = .day_recap }, &fx);
    try std.testing.expect(m.sending);
    const before = m.message_count;
    // A second card tap while the first is in flight must be ignored.
    main.update(&m, .{ .start_summary = .top_of_mind }, &fx);
    try std.testing.expectEqual(before, m.message_count);
    try std.testing.expect(m.pending_summary_kind.? == .day_recap); // unchanged
}

test "update: mcp_activity_done builds context then starts the completion" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.sending = true;
    m.pending_summary_kind = .day_recap;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // The MCP envelope wraps the get_activity tool JSON as result.content[0].text.
    const envelope =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":" ++
        "\"{\\\"activity\\\":[{\\\"kind\\\":\\\"commit\\\",\\\"ref_id\\\":1,\\\"repo_id\\\":1,\\\"repo\\\":\\\"blocks\\\",\\\"title\\\":\\\"Add tray\\\",\\\"occurred_at\\\":2000}]}\"" ++
        "}],\"isError\":false}}";

    main.update(&m, .{ .mcp_activity_done = .{ .key = 186, .outcome = .ok, .status = 200, .body = envelope } }, &fx);
    try std.testing.expect(m.isStreaming());
}

test "update: a summary finalizes and stays gated until the write commits" {
    var m = main.initialModel();
    m.llama_ready = true;
    m.mcp_ready = false;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Start the summary, stream a reply, and end it with [DONE].
    main.update(&m, .{ .start_summary = .standup }, &fx);
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: {\"choices\":[{\"delta\":{\"content\":\"Yesterday: shipped the tray.\"}}]}" } }, &fx);
    main.update(&m, .{ .chat_line = .{ .key = 181, .line = "data: [DONE]" } }, &fx);

    // The assistant summary is now a message; the turn stays gated (the
    // create-chat/persist chain is pending) and the kind is still held.
    try std.testing.expect(!m.isStreaming());
    try std.testing.expect(m.sending);
    try std.testing.expect(m.pending_summary_kind.? == .standup);
    try std.testing.expect(m.messagesSlice()[m.message_count - 1].isAssistant());

    // Once the write commits, the turn ends: sending clears and the summary
    // kind is released (ready for the next turn/summary).
    main.update(&m, .{ .chat_write_done = .{ .key = 184, .kind = .exec, .outcome = .ok } }, &fx);
    try std.testing.expect(!m.sending);
    try std.testing.expect(m.pending_summary_kind == null);
    try std.testing.expect(m.canSend());
}

// ---- Materials / snippets (Task 12) ----

const snippets = @import("snippets.zig");

test "update: select_snippet sets the selection id" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .select_snippet = 42 }, &fx);
    try std.testing.expectEqual(@as(i64, 42), m.selected_snippet_id);
}

test "update: toggle_sort_menu / set_sort switches the sort and closes the menu" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .toggle_sort_menu, &fx);
    try std.testing.expect(m.sortMenuOpen());
    main.update(&m, .sort_alphabetical, &fx);
    try std.testing.expect(!m.sortMenuOpen());
    try std.testing.expectEqualStrings("Alphabetical", m.sortLabel());
    main.update(&m, .sort_recent, &fx);
    try std.testing.expectEqualStrings("Recent", m.sortLabel());
}

test "update: set_lang_filter selects a language and All clears it" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    // Seed two known languages (as a distinct-languages load would).
    m.languages[0] = snippets.LanguageEntry.set("python");
    m.languages[1] = snippets.LanguageEntry.set("zig");
    m.language_count = 2;

    // filterIndex 1 => languages[0] = python.
    main.update(&m, .{ .set_lang_filter = 1 }, &fx);
    try std.testing.expectEqualStrings("python", m.langFilterLabel());
    // clear_lang_filter => All.
    main.update(&m, .clear_lang_filter, &fx);
    try std.testing.expectEqualStrings("All", m.langFilterLabel());
}

test "update: open_new_snippet opens a blank editor" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .open_new_snippet, &fx);
    try std.testing.expect(m.editorOpen());
    try std.testing.expectEqualStrings("New material", m.editorTitleLabel());
    try std.testing.expect(m.edit_title.isEmpty());
}

test "update: save_snippet (new) inserts and gates the write" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .open_new_snippet, &fx);
    m.edit_title.set("My Snippet");
    m.edit_content.set("print(1)");
    m.edit_language.set("python");
    main.update(&m, .save_snippet, &fx);
    // The editor closes and a write is in flight.
    try std.testing.expect(!m.editorOpen());
    try std.testing.expect(m.snippet_writing);

    // The insert result triggers a MAX(id) recovery; feeding that id + done
    // clears the write gate.
    main.update(&m, .{ .snippet_inserted = .{ .key = 192, .kind = .exec, .outcome = .ok } }, &fx);
    try std.testing.expect(m.snippet_writing); // still gated until rowid .done
}

test "update: selecting a snippet with no detail loaded leaves the detail empty" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Selecting sets the id and fires a detail query; until the result lands,
    // the detail accessors read empty (they gate on selected_detail.id).
    main.update(&m, .{ .select_snippet = 5 }, &fx);
    try std.testing.expectEqual(@as(i64, 5), m.selected_snippet_id);
    try std.testing.expectEqualStrings("", m.selectedContent());
}

test "update: save_to_snippets inserts from a chat message and gates the write" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    // Seed a loaded conversation (indices set by pushMessage).
    m.current_chat_id = 2;
    m.pushMessage(.user, "a question");
    m.pushMessage(.assistant, "an answer with code");

    // Save the assistant message (index 1) to snippets.
    main.update(&m, .{ .save_to_snippets = 1 }, &fx);
    try std.testing.expect(m.snippet_writing);
    try std.testing.expectEqualStrings("Saved to Materials.", m.snippetStatus());
}

test "update: save_to_snippets ignores an out-of-range index" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    m.pushMessage(.user, "only one");

    main.update(&m, .{ .save_to_snippets = 5 }, &fx); // no such message
    try std.testing.expect(!m.snippet_writing);
}

test "update: start_copilot_chat is a no-op when the runtime isn't ready" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    m.llama_ready = false;
    m.selected_snippet_id = 1;
    m.selected_detail = snippets.SnippetDetail.fromSnippet(.{
        .id = 1, .title = "T", .content = "code", .language = "zig", .annotation = "",
        .text_expander = "", .origin_chat_id = 0, .origin_message_id = 0, .updated_at = 1,
    });

    main.update(&m, .start_copilot_chat, &fx);
    try std.testing.expect(!m.sending);
}

test "update: start_copilot_chat seeds and sends a chat when ready" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    m.llama_ready = true;
    m.mcp_ready = false; // straight to completion
    m.selected_snippet_id = 1;
    m.selected_detail = snippets.SnippetDetail.fromSnippet(.{
        .id = 1, .title = "Deploy", .content = "def deploy(): pass", .language = "python",
        .annotation = "", .text_expander = "", .origin_chat_id = 0, .origin_message_id = 0, .updated_at = 1,
    });

    main.update(&m, .start_copilot_chat, &fx);
    // A chat turn began: the seeded prompt is the shown user message + streaming.
    try std.testing.expect(m.sending);
    try std.testing.expectEqual(@as(usize, 1), m.message_count);
    try std.testing.expect(std.mem.indexOf(u8, m.messagesSlice()[0].content(), "Deploy") != null);
}

test "update: snippet_clip_done reports a copy status" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .snippet_clip_done = .{ .key = 197, .op = .write, .outcome = .ok } }, &fx);
    try std.testing.expectEqualStrings("Copied to clipboard.", m.snippetStatus());
}

test "update: lang modal opens from a loaded detail, typeahead pick fills it" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    // Seed a selected detail + a suggestion.
    m.selected_snippet_id = 3;
    m.selected_detail = snippets.SnippetDetail.fromSnippet(.{
        .id = 3, .title = "T", .content = "c", .language = "", .annotation = "",
        .text_expander = "", .origin_chat_id = 0, .origin_message_id = 0, .updated_at = 1,
    });
    m.languages[0] = snippets.LanguageEntry.set("rust");
    m.language_count = 1;

    main.update(&m, .open_lang_modal, &fx);
    try std.testing.expect(m.langModalOpen());
    main.update(&m, .{ .pick_lang_suggestion = 0 }, &fx);
    try std.testing.expectEqualStrings("rust", m.lang_modal_input.text());
    main.update(&m, .cancel_lang_modal, &fx);
    try std.testing.expect(!m.langModalOpen());
}
