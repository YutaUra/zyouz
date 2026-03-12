const std = @import("std");
const posix = std.posix;
const Terminal = @import("Terminal.zig");
const Pty = @import("Pty.zig");
const input = @import("input.zig");
const Pane = @import("Pane.zig");
const Renderer = @import("Renderer.zig");
const Layout = @import("Layout.zig");
const Config = @import("Config.zig");

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
) !void {
    try installSignalHandler();
    defer {
        posix.close(signal_pipe[0]);
        posix.close(signal_pipe[1]);
    }

    var handler = input.InputHandler{};
    var buf: [4096]u8 = undefined;

    // Initial render
    renderer.computeBorders(rects, active_pane.*, handler.state == .command);
    try renderAll(terminal, renderer, panes, rects, active_pane.*);

    while (true) {
        // Build pollfd array: [terminal, pane0_pty, pane1_pty, ..., signal_pipe]
        var fds: [max_panes + 2]posix.pollfd = undefined;
        fds[0] = .{ .fd = terminal.fd, .events = posix.POLL.IN, .revents = 0 };
        for (panes, 0..) |*pane, i| {
            fds[i + 1] = .{ .fd = pane.pty.master_fd, .events = posix.POLL.IN, .revents = 0 };
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
            const area = Layout.Rect{ .col = 0, .row = 0, .width = size.cols, .height = size.rows };
            const new_rects = try Layout.compute(allocator, config_pane, area);
            defer allocator.free(new_rects);

            // Resize panes and update rects
            for (panes, 0..) |*pane, i| {
                if (i < new_rects.len) {
                    try pane.resize(new_rects[i]);
                    rects[i] = new_rects[i];
                }
            }

            // Resize renderer
            renderer.deinit();
            renderer.* = try Renderer.init(allocator, size.cols, size.rows);
            renderer.computeBorders(rects, active_pane.*, handler.state == .command);
            needs_render = true;
        }

        // Handle PTY output
        var any_exited = false;
        for (panes, 0..) |*pane, i| {
            const fd_idx = i + 1;
            if (fds[fd_idx].revents & posix.POLL.IN != 0) {
                const n = pane.pty.read(&buf) catch {
                    any_exited = true;
                    continue;
                };
                if (n == 0) {
                    any_exited = true;
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
                any_exited = true;
                needs_render = true;
            }
        }

        if (any_exited) {
            // For now, exit if any pane exits
            if (needs_render) {
                try renderAll(terminal, renderer, panes, rects, active_pane.*);
            }
            break;
        }

        // Handle terminal input → active pane
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = terminal.readInput(&buf) catch continue;
            if (active_pane.* < panes.len) {
                for (buf[0..n]) |byte| {
                    const prev_state = handler.state;
                    switch (handler.feed(byte)) {
                        .forward => |b| {
                            _ = try panes[active_pane.*].pty.writeInput(&.{b});
                        },
                        .quit => return,
                        .focus_up => handleFocus(rects, active_pane, renderer, &handler, &needs_render, .up),
                        .focus_down => handleFocus(rects, active_pane, renderer, &handler, &needs_render, .down),
                        .focus_left => handleFocus(rects, active_pane, renderer, &handler, &needs_render, .left),
                        .focus_right => handleFocus(rects, active_pane, renderer, &handler, &needs_render, .right),
                        .none => {},
                    }
                    // Recompute borders when entering/leaving command mode
                    // to show visual indicator.
                    if (handler.state != prev_state and
                        (handler.state == .command or prev_state == .command))
                    {
                        renderer.computeBorders(rects, active_pane.*, handler.state == .command);
                        needs_render = true;
                    }
                }
            }
        }

        if (needs_render) {
            try renderAll(terminal, renderer, panes, rects, active_pane.*);
        }
    }
}

fn handleFocus(
    rects: []const Layout.Rect,
    active_pane: *usize,
    renderer: *Renderer,
    handler: *const input.InputHandler,
    needs_render: *bool,
    dir: Layout.Direction,
) void {
    if (Layout.findNeighbor(rects, active_pane.*, dir)) |neighbor| {
        active_pane.* = neighbor;
        renderer.computeBorders(rects, active_pane.*, handler.state == .command);
        needs_render.* = true;
    }
}

fn renderAll(
    terminal: *Terminal.Terminal,
    renderer: *const Renderer,
    panes: []Pane,
    rects: []const Layout.Rect,
    active_pane: usize,
) !void {
    // Build screen pointer array
    var screens: [max_panes]*const @import("Screen.zig") = undefined;
    for (panes, 0..) |*pane, i| {
        screens[i] = &pane.screen;
    }

    var render_buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&render_buf);
    const writer = fbs.writer();

    renderer.renderFrame(writer, screens[0..panes.len], rects, active_pane) catch {
        // Buffer overflow — render directly without buffering
        return;
    };

    try terminal.writeAll(fbs.getWritten());
}
