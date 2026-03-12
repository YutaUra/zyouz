const std = @import("std");
const posix = std.posix;

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Terminal = struct {
    fd: posix.fd_t,
    original_termios: posix.termios,

    pub fn init() !Terminal {
        const fd = blk: {
            // Prefer dup(STDIN) when stdin is a TTY — the dup'd fd is
            // pollable on macOS, unlike /dev/tty which can return POLLNVAL.
            if (posix.isatty(posix.STDIN_FILENO)) {
                break :blk try posix.dup(posix.STDIN_FILENO);
            }
            // Fallback: open /dev/tty directly (e.g. when invoked via
            // `zig build run` where stdin is an IPC pipe).
            break :blk posix.open(
                "/dev/tty",
                .{ .ACCMODE = .RDWR, .NOCTTY = true },
                0,
            ) catch return error.NotATerminal;
        };
        const original_termios = try posix.tcgetattr(fd);
        return .{
            .fd = fd,
            .original_termios = original_termios,
        };
    }

    pub fn deinit(self: *const Terminal) void {
        posix.close(self.fd);
    }

    pub fn enableRawMode(self: *Terminal) !void {
        const raw = makeRaw(self.original_termios);
        try posix.tcsetattr(self.fd, .NOW, raw);
    }

    pub fn disableRawMode(self: *Terminal) void {
        posix.tcsetattr(self.fd, .NOW, self.original_termios) catch {};
    }

    pub fn enterAlternateScreen(self: *const Terminal) !void {
        try self.writeAll("\x1b[?1049h");
    }

    pub fn leaveAlternateScreen(self: *const Terminal) !void {
        try self.writeAll("\x1b[?1049l");
    }

    pub fn getSize(self: *const Terminal) !Size {
        var ws: posix.winsize = undefined;
        const rc = std.c.ioctl(self.fd, std.c.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0) return error.IoctlFailed;
        return .{ .rows = ws.row, .cols = ws.col };
    }

    pub fn readInput(self: *const Terminal, buf: []u8) !usize {
        return posix.read(self.fd, buf);
    }

    pub fn writeAll(self: *const Terminal, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += try posix.write(self.fd, data[written..]);
        }
    }
};

/// Apply raw mode settings to a termios struct.
/// Pure function — does not interact with any file descriptor.
pub fn makeRaw(termios: posix.termios) posix.termios {
    var raw = termios;
    // Local flags: disable echo, canonical mode, signals, extended input.
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    // Input flags: disable flow control, CR translation, break/parity/strip.
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;

    // Output flags: disable post-processing (ANSI passthrough).
    raw.oflag.OPOST = false;

    // Control flags: 8-bit characters.
    raw.cflag.CSIZE = .CS8;

    // Read returns after 1 byte, no timeout.
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

    return raw;
}

// --- Tests ---

test "makeRaw disables ECHO, ICANON, ISIG, IEXTEN in local flags" {
    var original: posix.termios = std.mem.zeroes(posix.termios);
    original.lflag.ECHO = true;
    original.lflag.ICANON = true;
    original.lflag.ISIG = true;
    original.lflag.IEXTEN = true;
    original.lflag.TOSTOP = true;

    const raw = makeRaw(original);

    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.ISIG);
    try std.testing.expect(!raw.lflag.IEXTEN);
    try std.testing.expect(raw.lflag.TOSTOP);
}

test "makeRaw disables IXON, ICRNL, BRKINT, INPCK, ISTRIP in input flags" {
    var original: posix.termios = std.mem.zeroes(posix.termios);
    original.iflag.IXON = true;
    original.iflag.ICRNL = true;
    original.iflag.BRKINT = true;
    original.iflag.INPCK = true;
    original.iflag.ISTRIP = true;
    original.iflag.IGNBRK = true;

    const raw = makeRaw(original);

    try std.testing.expect(!raw.iflag.IXON);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.iflag.BRKINT);
    try std.testing.expect(!raw.iflag.INPCK);
    try std.testing.expect(!raw.iflag.ISTRIP);
    try std.testing.expect(raw.iflag.IGNBRK);
}

test "makeRaw disables OPOST and sets CS8" {
    var original: posix.termios = std.mem.zeroes(posix.termios);
    original.oflag.OPOST = true;

    const raw = makeRaw(original);

    try std.testing.expect(!raw.oflag.OPOST);
    try std.testing.expectEqual(std.c.CSIZE.CS8, raw.cflag.CSIZE);
}

test "makeRaw sets VMIN=1 and VTIME=0" {
    const original: posix.termios = std.mem.zeroes(posix.termios);
    const raw = makeRaw(original);

    const VMIN = @intFromEnum(std.c.V.MIN);
    const VTIME = @intFromEnum(std.c.V.TIME);
    try std.testing.expectEqual(@as(u8, 1), raw.cc[VMIN]);
    try std.testing.expectEqual(@as(u8, 0), raw.cc[VTIME]);
}

test "init dups stdin and saves original termios" {
    // zig build test may not have a controlling terminal.
    const term = Terminal.init() catch return;
    defer term.deinit();

    try std.testing.expect(term.fd >= 0);
}

test "enableRawMode and disableRawMode round-trip" {
    var term = Terminal.init() catch return;
    defer term.deinit();

    const before = try posix.tcgetattr(term.fd);
    try term.enableRawMode();
    term.disableRawMode();
    const after = try posix.tcgetattr(term.fd);

    // After round-trip, lflag should match the original.
    try std.testing.expectEqual(before.lflag, after.lflag);
    try std.testing.expectEqual(before.iflag, after.iflag);
    try std.testing.expectEqual(before.oflag, after.oflag);
}

test "getSize returns non-zero dimensions" {
    const term = Terminal.init() catch return;
    defer term.deinit();

    const size = term.getSize() catch return;
    try std.testing.expect(size.rows > 0);
    try std.testing.expect(size.cols > 0);
}
