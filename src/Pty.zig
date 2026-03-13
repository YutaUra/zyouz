const std = @import("std");
const posix = std.posix;
const Terminal = @import("Terminal.zig");

// libc openpty() — not in Zig stdlib.
// On macOS: defined in <util.h>, linked from libutil.
extern "c" fn openpty(
    amaster: *posix.fd_t,
    aslave: *posix.fd_t,
    name: ?[*:0]u8,
    termp: ?*const anyopaque,
    winp: ?*const posix.winsize,
) c_int;

// macOS: TIOCSCTTY = _IO('t', 97) = 0x20007461
const TIOCSCTTY: c_int = 0x20007461;

// macOS: TIOCSWINSZ = _IOW('t', 103, struct winsize) = 0x80087467
// Not defined in Zig 0.15 std.c.T for macOS, unlike TIOCGWINSZ.
const TIOCSWINSZ: c_int = @bitCast(@as(c_uint, 0x80087467));

// libc execvp() — using C binding directly because Zig's execvpeZ returns
// an error set that cannot be discarded in the forked child process.
extern "c" fn execvp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) c_int;

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    cached_exit_code: ?u32 = null,

    pub fn spawn(
        argv: [*:null]const ?[*:0]const u8,
        size: Terminal.Size,
    ) !Pty {
        var master: posix.fd_t = undefined;
        var slave: posix.fd_t = undefined;
        const ws = posix.winsize{
            .row = size.rows,
            .col = size.cols,
            .xpixel = 0,
            .ypixel = 0,
        };

        if (openpty(&master, &slave, null, null, &ws) < 0) {
            return error.OpenPtyFailed;
        }

        const pid = try posix.fork();

        if (pid == 0) {
            // Child process.
            posix.close(master);

            // New session — detach from parent's controlling terminal.
            _ = posix.setsid() catch {};

            // Set slave PTY as controlling terminal.
            _ = std.c.ioctl(slave, TIOCSCTTY, @as(c_ulong, 0));

            // Redirect stdin/stdout/stderr to slave PTY.
            posix.dup2(slave, posix.STDIN_FILENO) catch posix.exit(1);
            posix.dup2(slave, posix.STDOUT_FILENO) catch posix.exit(1);
            posix.dup2(slave, posix.STDERR_FILENO) catch posix.exit(1);
            if (slave > 2) posix.close(slave);

            // Execute the command. On success, this replaces the process image.
            _ = execvp(argv[0].?, argv);
            posix.exit(127);
        }

        // Parent process.
        posix.close(slave);
        return .{ .master_fd = master, .child_pid = pid };
    }

    pub fn setSize(self: *const Pty, size: Terminal.Size) !void {
        const ws = posix.winsize{
            .row = size.rows,
            .col = size.cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (std.c.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }
    }

    pub fn read(self: *const Pty, buf: []u8) !usize {
        return posix.read(self.master_fd, buf);
    }

    pub fn writeInput(self: *const Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    pub fn checkExited(self: *Pty) ?u32 {
        if (self.cached_exit_code) |code| return code;

        const result = posix.waitpid(self.child_pid, std.c.W.NOHANG);
        if (result.pid == 0) return null; // still running

        const status = result.status;
        const code: u32 = if (std.c.W.IFEXITED(status))
            std.c.W.EXITSTATUS(status)
        else
            128 + std.c.W.TERMSIG(status);
        self.cached_exit_code = code;
        return code;
    }

    pub fn sendSignal(self: *const Pty, sig: u6) !void {
        posix.kill(self.child_pid, sig) catch |err| switch (err) {
            error.ProcessNotFound => return, // already dead
            else => return err,
        };
    }

    pub fn kill(self: *const Pty) void {
        self.sendSignal(posix.SIG.HUP) catch {};
    }

    pub fn deinit(self: *Pty) void {
        self.kill();
        // If checkExited already reaped the child, skip waitpid to
        // avoid blocking on an already-reaped PID.
        if (self.cached_exit_code == null) {
            _ = posix.waitpid(self.child_pid, 0);
        }
        posix.close(self.master_fd);
    }
};

test "checkExited returns null for still-running child" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sleep", "10" };
    var pty = try Pty.spawn(&argv, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();

    const result = pty.checkExited();
    try std.testing.expect(result == null);
}

test "checkExited returns exit code after child exits" {
    const argv = [_:null]?[*:0]const u8{"/usr/bin/true"};
    var pty = try Pty.spawn(&argv, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();

    // Poll for child exit instead of blocking read
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (pty.checkExited()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const result = pty.checkExited();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?);
}

test "checkExited caches result on subsequent calls" {
    const argv = [_:null]?[*:0]const u8{"/usr/bin/true"};
    var pty = try Pty.spawn(&argv, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();

    // Poll for child exit
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (pty.checkExited()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const first = pty.checkExited();
    const second = pty.checkExited();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?, second.?);
}

test "sendSignal sends SIGTERM to child" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sleep", "30" };
    var pty = try Pty.spawn(&argv, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();

    // Child should be running
    try std.testing.expect(pty.checkExited() == null);

    // Send SIGTERM
    try pty.sendSignal(posix.SIG.TERM);

    // Wait for child to exit
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        if (pty.checkExited()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Child should have exited (128 + SIGTERM)
    const code = pty.checkExited();
    try std.testing.expect(code != null);
    try std.testing.expectEqual(@as(u32, 128 + 15), code.?); // SIGTERM = 15
}

test "sendSignal sends SIGKILL to child" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sleep", "30" };
    var pty = try Pty.spawn(&argv, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();

    try pty.sendSignal(posix.SIG.KILL);

    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        if (pty.checkExited()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const code = pty.checkExited();
    try std.testing.expect(code != null);
    try std.testing.expectEqual(@as(u32, 128 + 9), code.?); // SIGKILL = 9
}

test "spawn runs child and reads output" {
    const argv = [_:null]?[*:0]const u8{ "/bin/echo", "hello" };
    var pty = try Pty.spawn(&argv, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();

    var buf: [256]u8 = undefined;
    const n = try pty.read(&buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "hello") != null);
}
