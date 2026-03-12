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

    pub fn kill(self: *const Pty) void {
        posix.kill(self.child_pid, posix.SIG.HUP) catch {};
    }

    pub fn deinit(self: *const Pty) void {
        self.kill();
        _ = posix.waitpid(self.child_pid, 0);
        posix.close(self.master_fd);
    }
};

test "spawn runs child and reads output" {
    const argv = [_:null]?[*:0]const u8{ "/bin/echo", "hello" };
    var pty = try Pty.spawn(&argv, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();

    var buf: [256]u8 = undefined;
    const n = try pty.read(&buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "hello") != null);
}
