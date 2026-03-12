const std = @import("std");
const posix = std.posix;
const Terminal = @import("Terminal.zig");
const Pty = @import("Pty.zig");
const input = @import("input.zig");

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
                    .none => {},
                }
            }
        }
    }
}
