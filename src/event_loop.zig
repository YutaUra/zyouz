const std = @import("std");
const posix = std.posix;
const Terminal = @import("Terminal.zig");
const Pty = @import("Pty.zig");
const input = @import("input.zig");
const Pane = @import("Pane.zig");
const Renderer = @import("Renderer.zig");
const Layout = @import("Layout.zig");
const Config = @import("Config.zig");
const MouseParser = @import("MouseParser.zig");

/// Signal pipe for SIGWINCH notification.
/// Written from signal handler, read from event loop.
var signal_pipe: [2]posix.fd_t = .{ -1, -1 };

fn sigwinchHandler(_: c_int) callconv(.c) void {
    // Async-signal-safe: write 1 byte to pipe.
    _ = posix.write(signal_pipe[1], "W") catch {};
}

pub fn installSignalHandler() !void {
    const pipe = try posix.pipe();
    signal_pipe = pipe;

    // Make read end non-blocking so poll() works correctly.
    const flags = try posix.fcntl(pipe[0], posix.F.GETFL, 0);
    const o_nonblock: usize = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    _ = try posix.fcntl(pipe[0], posix.F.SETFL, flags | o_nonblock);

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = std.c.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
}

pub fn run(terminal: *Terminal.Terminal, pty: *Pty.Pty) !void {
    try installSignalHandler();
    defer {
        posix.close(signal_pipe[0]);
        posix.close(signal_pipe[1]);
    }

    var handler = input.InputHandler{};
    var buf: [4096]u8 = undefined;

    while (true) {
        // Poll: terminal input, PTY output, signal pipe.
        var fds = [_]posix.pollfd{
            .{ .fd = terminal.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = pty.master_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = signal_pipe[0], .events = posix.POLL.IN, .revents = 0 },
        };

        _ = posix.poll(&fds, -1) catch |err| switch (err) {
            error.NetworkSubsystemFailed => return err,
            else => continue, // retry on EINTR
        };

        // Handle signal pipe (SIGWINCH).
        if (fds[2].revents & posix.POLL.IN != 0) {
            // Drain the pipe.
            _ = posix.read(signal_pipe[0], &buf) catch {};
            // Propagate new terminal size to PTY.
            const size = try terminal.getSize();
            try pty.setSize(size);
        }

        // Handle PTY output → terminal.
        if (fds[1].revents & posix.POLL.IN != 0) {
            const n = pty.read(&buf) catch break; // child exited
            if (n == 0) break;
            try terminal.writeAll(buf[0..n]);
        }

        // Handle PTY hangup (child exited).
        if (fds[1].revents & posix.POLL.HUP != 0) {
            // Read remaining output before exiting.
            while (true) {
                const n = pty.read(&buf) catch break;
                if (n == 0) break;
                try terminal.writeAll(buf[0..n]);
            }
            break;
        }

        // Handle terminal input → PTY.
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = terminal.readInput(&buf) catch continue;
            for (buf[0..n]) |byte| {
                switch (handler.feed(byte)) {
                    .forward => |b| {
                        _ = try pty.writeInput(&.{b});
                    },
                    .quit => return,
                    .focus_up, .focus_down, .focus_left, .focus_right, .none => {},
                }
            }
        }
    }
}

const max_panes = 32;

pub fn runMultiPane(
    allocator: std.mem.Allocator,
    terminal: *Terminal.Terminal,
    panes: []Pane,
    renderer: *Renderer,
    rects: []Layout.Rect,
    config_pane: Config.Pane,
    active_pane: *usize,
    prefix_key: u8,
    pane_gap: u16,
) !void {
    try installSignalHandler();
    defer {
        posix.close(signal_pipe[0]);
        posix.close(signal_pipe[1]);
    }

    // Enable mouse tracking (SGR mode for extended coordinates)
    try terminal.enableMouseTracking();
    defer terminal.disableMouseTracking() catch {};

    var handler = input.InputHandler.initWithPrefix(prefix_key);
    var mouse_parser = MouseParser{};
    var drag_state: ?DragState = null;
    var buf: [4096]u8 = undefined;

    // Initial render
    recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
    try renderAll(terminal, renderer, panes, rects, active_pane.*);

    while (true) {
        // Build pollfd array: [terminal, pane0_pty, pane1_pty, ..., signal_pipe]
        // Exited panes get fd=-1 so poll() ignores them.
        var fds: [max_panes + 2]posix.pollfd = undefined;
        fds[0] = .{ .fd = terminal.fd, .events = posix.POLL.IN, .revents = 0 };
        for (panes, 0..) |*pane, i| {
            fds[i + 1] = .{
                .fd = if (pane.isAlive()) pane.pty.master_fd else -1,
                .events = posix.POLL.IN,
                .revents = 0,
            };
        }
        const sig_idx = panes.len + 1;
        fds[sig_idx] = .{ .fd = signal_pipe[0], .events = posix.POLL.IN, .revents = 0 };

        _ = posix.poll(fds[0 .. sig_idx + 1], -1) catch |err| switch (err) {
            error.NetworkSubsystemFailed => return err,
            else => continue,
        };

        var needs_render = false;

        // Handle signal pipe (SIGWINCH)
        if (fds[sig_idx].revents & posix.POLL.IN != 0) {
            _ = posix.read(signal_pipe[0], &buf) catch {};
            const size = try terminal.getSize();

            // Recompute layout
            const area = Layout.Rect{ .col = 1, .row = 1, .width = size.cols -| 2, .height = size.rows -| 2 };
            const new_rects = try Layout.compute(allocator, config_pane, area, pane_gap);
            defer allocator.free(new_rects);

            // Resize panes and update rects
            for (panes, 0..) |*pane, i| {
                if (i < new_rects.len) {
                    rects[i] = new_rects[i];
                    if (pane.isAlive()) {
                        try pane.resize(new_rects[i]);
                    }
                }
            }

            // Resize renderer
            renderer.deinit();
            renderer.* = try Renderer.init(allocator, size.cols, size.rows);
            recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
            needs_render = true;
        }

        // Handle PTY output for alive panes
        for (panes, 0..) |*pane, i| {
            if (!pane.isAlive()) continue;
            const fd_idx = i + 1;
            if (fds[fd_idx].revents & posix.POLL.IN != 0) {
                const n = pane.pty.read(&buf) catch {
                    handlePaneExit(pane);
                    needs_render = true;
                    continue;
                };
                if (n == 0) {
                    handlePaneExit(pane);
                    needs_render = true;
                    continue;
                }
                pane.feedOutput(buf[0..n]);
                needs_render = true;
            }
            if (fds[fd_idx].revents & posix.POLL.HUP != 0) {
                // Drain remaining output
                while (true) {
                    const n = pane.pty.read(&buf) catch break;
                    if (n == 0) break;
                    pane.feedOutput(buf[0..n]);
                }
                handlePaneExit(pane);
                needs_render = true;
            }
        }

        // Handle terminal input → active pane
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = terminal.readInput(&buf) catch continue;
            if (active_pane.* < panes.len) {
                for (buf[0..n]) |byte| {
                    // Mouse parser intercepts SGR mouse sequences before
                    // they reach the keyboard input handler.
                    switch (mouse_parser.feed(byte)) {
                        .passthrough => |b| {
                            processKeyByte(b, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                        },
                        .consumed => {},
                        .event => |ev| {
                            handleMouseEvent(ev, panes, rects, active_pane, renderer, &handler, &drag_state, &needs_render, pane_gap);
                        },
                        .escape_passthrough => |b| {
                            processKeyByte(0x1B, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                            processKeyByte(b, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                        },
                        .csi_passthrough => |b| {
                            processKeyByte(0x1B, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                            processKeyByte('[', &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                            processKeyByte(b, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                        },
                    }
                }
            }
        }

        if (needs_render) {
            try renderAll(terminal, renderer, panes, rects, active_pane.*);
        }
    }
}

fn processKeyByte(
    byte: u8,
    handler: *input.InputHandler,
    panes: []Pane,
    rects: []const Layout.Rect,
    active_pane: *usize,
    renderer: *Renderer,
    needs_render: *bool,
) !void {
    const prev_state = handler.state;
    switch (handler.feed(byte)) {
        .forward => |b| {
            if (active_pane.* < panes.len and panes[active_pane.*].isAlive()) {
                _ = try panes[active_pane.*].pty.writeInput(&.{b});
            }
        },
        .quit => return error.Quit,
        .focus_up => handleFocus(rects, active_pane, renderer, handler, needs_render, .up, panes),
        .focus_down => handleFocus(rects, active_pane, renderer, handler, needs_render, .down, panes),
        .focus_left => handleFocus(rects, active_pane, renderer, handler, needs_render, .left, panes),
        .focus_right => handleFocus(rects, active_pane, renderer, handler, needs_render, .right, panes),
        .none => {},
    }
    if (handler.state != prev_state and
        (handler.state == .command or prev_state == .command))
    {
        recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
        needs_render.* = true;
    }
}

const DragState = struct {
    border: Layout.BorderInfo,
    last_col: u16,
    last_row: u16,
};

const min_pane_size: u16 = 2;

/// Check for a resizable border at the exact position or on the pane edge.
/// When the click lands inside a pane near its edge, uses findNeighbor to
/// locate the adjacent pane. This avoids the junction problem where
/// borderAt fails at the intersection of vertical and horizontal dividers
/// (e.g., in a layout with a left pane and a vertically-split right pane,
/// borderAt cannot find panes across the junction row).
fn findBorderNear(rects: []const Layout.Rect, row: u16, col: u16) ?Layout.BorderInfo {
    // Direct hit on a border cell — works for most positions except junctions.
    if (Layout.borderAt(rects, row, col)) |b| return b;

    // Click is inside a pane — check if we're on the pane edge.
    const pane_idx = Layout.paneAt(rects, row, col) orelse return null;
    const r = rects[pane_idx];

    // Right edge of pane (last content column)
    if (col + 1 >= r.col + r.width) {
        if (Layout.findNeighbor(rects, pane_idx, .right)) |neighbor| {
            return .{ .pane_before = pane_idx, .pane_after = neighbor, .is_vertical = true };
        }
    }
    // Left edge of pane (first content column)
    if (col == r.col) {
        if (Layout.findNeighbor(rects, pane_idx, .left)) |neighbor| {
            return .{ .pane_before = neighbor, .pane_after = pane_idx, .is_vertical = true };
        }
    }
    // Bottom edge of pane (last content row)
    if (row + 1 >= r.row + r.height) {
        if (Layout.findNeighbor(rects, pane_idx, .down)) |neighbor| {
            return .{ .pane_before = pane_idx, .pane_after = neighbor, .is_vertical = false };
        }
    }
    // Top edge of pane (first content row)
    if (row == r.row) {
        if (Layout.findNeighbor(rects, pane_idx, .up)) |neighbor| {
            return .{ .pane_before = neighbor, .pane_after = pane_idx, .is_vertical = false };
        }
    }
    return null;
}

fn handleMouseEvent(
    ev: MouseParser.MouseEvent,
    panes: []Pane,
    rects: []Layout.Rect,
    active_pane: *usize,
    renderer: *Renderer,
    handler: *const input.InputHandler,
    drag_state: *?DragState,
    needs_render: *bool,
    pane_gap: u16,
) void {
    switch (ev.kind) {
        .press => {
            if (ev.button == .scroll_up or ev.button == .scroll_down or
                ev.button == .scroll_left or ev.button == .scroll_right)
            {
                if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                    if (panes[target_pane].mouse_mode == .passthrough) {
                        var sgr_buf: [32]u8 = undefined;
                        const sgr = ev.formatSgr(&sgr_buf, rects[target_pane].col, rects[target_pane].row);
                        if (sgr.len > 0) {
                            _ = panes[target_pane].pty.writeInput(sgr) catch {};
                        }
                    } else {
                        // Horizontal scroll: no-op for non-passthrough
                        // (content wraps at screen width)
                        if (ev.button == .scroll_up) {
                            panes[target_pane].scrollViewUp(3);
                        } else if (ev.button == .scroll_down) {
                            panes[target_pane].scrollViewDown(3);
                        }
                        needs_render.* = true;
                    }
                }
                return;
            }
            if (ev.button == .left) {
                // Check if clicking on or near a border to start drag
                if (findBorderNear(rects, ev.row, ev.col)) |border| {
                    drag_state.* = .{
                        .border = border,
                        .last_col = ev.col,
                        .last_row = ev.row,
                    };
                    return;
                }
                // Click on pane to focus
                if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                    if (panes[target_pane].mouse_mode == .passthrough) {
                        var sgr_buf: [32]u8 = undefined;
                        const sgr = ev.formatSgr(&sgr_buf, rects[target_pane].col, rects[target_pane].row);
                        if (sgr.len > 0) {
                            _ = panes[target_pane].pty.writeInput(sgr) catch {};
                        }
                    }
                    if (target_pane != active_pane.*) {
                        active_pane.* = target_pane;
                        recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
                        needs_render.* = true;
                    }
                }
            }
        },
        .drag => {
            if (ev.button == .left) {
                if (drag_state.*) |*ds| {
                    applyDrag(ds, ev, panes, rects, renderer, active_pane, handler, needs_render, pane_gap);
                } else {
                    // Drag on a passthrough pane → forward
                    if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                        if (panes[target_pane].mouse_mode == .passthrough) {
                            var sgr_buf: [32]u8 = undefined;
                            const sgr = ev.formatSgr(&sgr_buf, rects[target_pane].col, rects[target_pane].row);
                            if (sgr.len > 0) {
                                _ = panes[target_pane].pty.writeInput(sgr) catch {};
                            }
                        }
                    }
                }
            }
        },
        .release => {
            drag_state.* = null;
            // Forward release to passthrough panes
            if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                if (panes[target_pane].mouse_mode == .passthrough) {
                    var sgr_buf: [32]u8 = undefined;
                    const sgr = ev.formatSgr(&sgr_buf, rects[target_pane].col, rects[target_pane].row);
                    if (sgr.len > 0) {
                        _ = panes[target_pane].pty.writeInput(sgr) catch {};
                    }
                }
            }
        },
    }
}

fn applyDrag(
    ds: *DragState,
    ev: MouseParser.MouseEvent,
    panes: []Pane,
    rects: []Layout.Rect,
    renderer: *Renderer,
    active_pane: *const usize,
    handler: *const input.InputHandler,
    needs_render: *bool,
    pane_gap: u16,
) void {
    // Must match Layout.computeSplit divider_width formula.
    const divider_width: u16 = 1 + pane_gap;

    if (ds.border.is_vertical) {
        const delta: i32 = @as(i32, ev.col) - @as(i32, ds.last_col);
        if (delta == 0) return;

        // Current border column: right edge of the "before" reference pane.
        const border_col: u16 = rects[ds.border.pane_before].col + rects[ds.border.pane_before].width;
        // Pane after the divider starts at border_col + divider_width.
        const after_col: u16 = border_col + divider_width;

        // Check all panes sharing this border can accommodate the resize.
        for (rects) |r| {
            if (r.col + r.width == border_col) {
                if (@as(i32, r.width) + delta < min_pane_size) return;
            } else if (r.col == after_col) {
                if (@as(i32, r.width) - delta < min_pane_size) return;
            }
        }

        // Apply to ALL panes sharing the border.
        for (rects, 0..) |*r, i| {
            if (r.col + r.width == border_col) {
                r.width = @intCast(@as(i32, r.width) + delta);
                panes[i].resize(r.*) catch {};
            } else if (r.col == after_col) {
                r.col = @intCast(@as(i32, r.col) + delta);
                r.width = @intCast(@as(i32, r.width) - delta);
                panes[i].resize(r.*) catch {};
            }
        }
    } else {
        const delta: i32 = @as(i32, ev.row) - @as(i32, ds.last_row);
        if (delta == 0) return;

        // Current border row: bottom edge of the "before" reference pane.
        const border_row: u16 = rects[ds.border.pane_before].row + rects[ds.border.pane_before].height;
        // Pane after the divider starts at border_row + divider_width.
        const after_row: u16 = border_row + divider_width;

        for (rects) |r| {
            if (r.row + r.height == border_row) {
                if (@as(i32, r.height) + delta < min_pane_size) return;
            } else if (r.row == after_row) {
                if (@as(i32, r.height) - delta < min_pane_size) return;
            }
        }

        for (rects, 0..) |*r, i| {
            if (r.row + r.height == border_row) {
                r.height = @intCast(@as(i32, r.height) + delta);
                panes[i].resize(r.*) catch {};
            } else if (r.row == after_row) {
                r.row = @intCast(@as(i32, r.row) + delta);
                r.height = @intCast(@as(i32, r.height) - delta);
                panes[i].resize(r.*) catch {};
            }
        }
    }

    ds.last_col = ev.col;
    ds.last_row = ev.row;

    recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
    needs_render.* = true;
}

fn handleFocus(
    rects: []const Layout.Rect,
    active_pane: *usize,
    renderer: *Renderer,
    handler: *const input.InputHandler,
    needs_render: *bool,
    dir: Layout.Direction,
    panes: []const Pane,
) void {
    if (Layout.findNeighbor(rects, active_pane.*, dir)) |neighbor| {
        active_pane.* = neighbor;
        recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
        needs_render.* = true;
    }
}

const shutdown_timeout_ns = 2 * std.time.ns_per_s;

fn gracefulShutdown(panes: []Pane) void {
    // Phase 1: Send SIGTERM to all alive panes
    for (panes) |*pane| {
        if (pane.isAlive()) {
            pane.pty.sendSignal(posix.SIG.TERM) catch {};
        }
    }

    // Phase 2: Poll for exit with timeout (2 seconds)
    const poll_interval: u64 = 50 * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    while (elapsed < shutdown_timeout_ns) {
        var all_exited = true;
        for (panes) |*pane| {
            if (pane.isAlive()) {
                if (pane.pty.checkExited()) |code| {
                    pane.markExited(code);
                } else {
                    all_exited = false;
                }
            }
        }
        if (all_exited) return;
        std.Thread.sleep(poll_interval);
        elapsed += poll_interval;
    }

    // Phase 3: SIGKILL remaining alive panes
    for (panes) |*pane| {
        if (pane.isAlive()) {
            pane.pty.sendSignal(posix.SIG.KILL) catch {};
        }
    }

    // Wait for them to actually die
    for (panes) |*pane| {
        if (pane.isAlive()) {
            if (pane.pty.checkExited()) |code| {
                pane.markExited(code);
            }
        }
    }
}

fn handlePaneExit(pane: *Pane) void {
    const exit_code = pane.pty.checkExited() orelse 255;
    pane.markExited(exit_code);

    if (Pane.shouldRestart(pane.restart, exit_code)) {
        pane.respawn() catch {};
    }
}

fn buildPaneStates(panes: []const Pane) [max_panes]Pane.ProcessState {
    var states: [max_panes]Pane.ProcessState = undefined;
    for (panes, 0..) |*pane, i| {
        states[i] = pane.process_state;
    }
    return states;
}

fn buildPaneNames(panes: []const Pane) [max_panes][]const u8 {
    var names: [max_panes][]const u8 = undefined;
    for (panes, 0..) |*pane, i| {
        names[i] = pane.name;
    }
    return names;
}

fn recomputeBorders(renderer: *Renderer, panes: []const Pane, rects: []const Layout.Rect, active_pane: usize, command_mode: bool) void {
    const states = buildPaneStates(panes);
    renderer.computeBordersWithState(rects, active_pane, command_mode, states[0..panes.len]);
    const names = buildPaneNames(panes);
    renderer.renderPaneNames(rects, names[0..panes.len]);
}

fn renderAll(
    terminal: *Terminal.Terminal,
    renderer: *const Renderer,
    panes: []Pane,
    rects: []const Layout.Rect,
    active_pane: usize,
) !void {
    const Screen = @import("Screen.zig");
    // Build screen pointer and scroll offset arrays
    var screens: [max_panes]*const Screen = undefined;
    var scroll_offsets: [max_panes]usize = undefined;
    for (panes, 0..) |*pane, i| {
        screens[i] = &pane.screen;
        scroll_offsets[i] = pane.scroll_offset;
    }

    var render_buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&render_buf);
    const writer = fbs.writer();

    renderer.renderFrameWithScrollback(
        writer,
        screens[0..panes.len],
        rects,
        scroll_offsets[0..panes.len],
        active_pane,
    ) catch {
        return;
    };

    // Render exit status overlays for exited panes
    const states = buildPaneStates(panes);
    renderer.renderExitStatuses(writer, rects, states[0..panes.len]) catch {};

    try terminal.writeAll(fbs.getWritten());
}
