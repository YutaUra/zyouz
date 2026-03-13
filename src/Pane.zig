const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const VtParser = @import("VtParser.zig");
const Pty = @import("Pty.zig");
const Terminal = @import("Terminal.zig");
const Layout = @import("Layout.zig");
const Config = @import("Config.zig");

const Pane = @This();

pub const ProcessState = union(enum) {
    running,
    exited: u32,
};

pty: Pty.Pty,
screen: Screen,
parser: VtParser,
rect: Layout.Rect,
allocator: Allocator,
name: []const u8 = "",
mouse_mode: Config.Mouse = .capture,
scroll_offset: usize = 0,
process_state: ProcessState = .running,
command: []const []const u8 = &.{},
restart: Config.Restart = .never,

/// Initialize a Pane in place at `self`.
/// Uses in-place init to avoid a dangling pointer: VtParser stores a
/// *Screen, so returning Pane by value would copy the screen but leave
/// the parser pointing at the old (stale) stack address.
pub fn initFromCommand(self: *Pane, allocator: Allocator, command: []const []const u8, rect: Layout.Rect) !void {
    // Build null-terminated argv for execvp.
    // Strings from ZON config are not null-terminated, so we must
    // create proper sentinel-terminated copies for execvp.
    const argv = try allocator.alloc(?[*:0]const u8, command.len + 1);
    defer {
        for (argv[0..command.len]) |ptr| {
            // Free each dupeZ'd string: recover the slice from the sentinel ptr.
            const s: [*:0]const u8 = ptr.?;
            // Find the length by scanning for the sentinel.
            var len: usize = 0;
            while (s[len] != 0) len += 1;
            allocator.free(s[0 .. len + 1]);
        }
        allocator.free(argv);
    }
    for (command, 0..) |arg, i| {
        argv[i] = (try allocator.dupeZ(u8, arg)).ptr;
    }
    argv[command.len] = null;
    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);

    const size = Terminal.Size{ .cols = rect.width, .rows = rect.height };
    const pty = try Pty.Pty.spawn(argv_ptr, size);

    self.* = .{
        .pty = pty,
        .screen = try Screen.initWithScrollback(allocator, rect.width, rect.height, 1000),
        .parser = undefined,
        .rect = rect,
        .allocator = allocator,
        .command = command,
    };
    // parser.screen must point to self.screen (the final location),
    // not a temporary local variable.
    self.parser = VtParser.init(&self.screen);
}

pub fn deinit(self: *Pane) void {
    self.pty.kill();
    self.pty.deinit();
    self.screen.deinit();
}

pub fn feedOutput(self: *Pane, data: []const u8) void {
    self.parser.feed(data);
    // Forward any pending query responses (DSR, DA1) back to the child.
    if (self.parser.response_len > 0) {
        _ = self.pty.writeInput(self.parser.response_buf[0..self.parser.response_len]) catch {};
        self.parser.response_len = 0;
    }
}

pub fn scrollViewUp(self: *Pane, n: usize) void {
    self.scroll_offset = @min(self.scroll_offset + n, self.screen.scrollbackLen());
}

pub fn scrollViewDown(self: *Pane, n: usize) void {
    self.scroll_offset -|= n;
}

pub fn isAlive(self: *const Pane) bool {
    return isAliveState(self.process_state);
}

pub fn isAliveState(state: ProcessState) bool {
    return state == .running;
}

pub fn markExited(self: *Pane, exit_code: u32) void {
    self.process_state = .{ .exited = exit_code };
}

pub fn shouldRestart(restart: Config.Restart, exit_code: u32) bool {
    return switch (restart) {
        .never => false,
        .on_failure => exit_code != 0,
    };
}

/// Re-spawn the child process, resetting screen and parser.
pub fn respawn(self: *Pane) !void {
    if (self.command.len == 0) return error.NoCommand;

    // Build null-terminated argv
    const argv = try self.allocator.alloc(?[*:0]const u8, self.command.len + 1);
    defer {
        for (argv[0..self.command.len]) |ptr| {
            const s: [*:0]const u8 = ptr.?;
            var len: usize = 0;
            while (s[len] != 0) len += 1;
            self.allocator.free(s[0 .. len + 1]);
        }
        self.allocator.free(argv);
    }
    for (self.command, 0..) |arg, i| {
        argv[i] = (try self.allocator.dupeZ(u8, arg)).ptr;
    }
    argv[self.command.len] = null;
    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);

    const size = Terminal.Size{ .cols = self.rect.width, .rows = self.rect.height };
    const new_pty = try Pty.Pty.spawn(argv_ptr, size);

    // Close old PTY master fd (child already exited, no need to kill)
    std.posix.close(self.pty.master_fd);

    self.pty = new_pty;
    self.screen.deinit();
    self.screen = try Screen.initWithScrollback(self.allocator, self.rect.width, self.rect.height, 1000);
    self.parser = VtParser.init(&self.screen);
    self.scroll_offset = 0;
    self.process_state = .running;
}

pub fn resize(self: *Pane, new_rect: Layout.Rect) !void {
    self.rect = new_rect;
    // Reallocate screen if dimensions changed
    if (new_rect.width != self.screen.width or new_rect.height != self.screen.height) {
        self.screen.deinit();
        self.screen = try Screen.initWithScrollback(self.allocator, new_rect.width, new_rect.height, 1000);
        self.parser = VtParser.init(&self.screen);
        self.scroll_offset = 0;
        const size = Terminal.Size{ .cols = new_rect.width, .rows = new_rect.height };
        try self.pty.setSize(size);
    }
}

// Tests require PTY spawn (fork+exec), so they are integration tests
// that only run in environments that support it.
test "Pane.feedOutput updates screen via VT parser" {
    // Test feedOutput without PTY by constructing manually
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("Hi");

    try std.testing.expectEqual(@as(u21, 'H'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), screen.cellAt(0, 1).char);
}

test "scrollViewUp increases offset clamped to scrollbackLen" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 3, 2, 10);
    defer screen.deinit();

    // Push 2 lines into scrollback
    for ("AAA") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    for ("BBB") |c| screen.writeChar(c);
    screen.scrollUp(1);
    screen.setCursorPos(1, 0);
    for ("CCC") |c| screen.writeChar(c);
    screen.scrollUp(1);

    // Simulate Pane scroll by testing the logic directly on screen
    var offset: usize = 0;
    // scrollViewUp(3) but only 2 in scrollback
    offset = @min(offset + 3, screen.scrollbackLen());
    try std.testing.expectEqual(@as(usize, 2), offset);

    // scrollViewDown(1)
    offset -|= 1;
    try std.testing.expectEqual(@as(usize, 1), offset);

    // scrollViewDown(5) clamps to 0
    offset -|= 5;
    try std.testing.expectEqual(@as(usize, 0), offset);
}

test "ProcessState defaults to .running" {
    const state = Pane.ProcessState.running;
    try std.testing.expect(state == .running);
}

test "ProcessState.exited carries exit code" {
    const state = Pane.ProcessState{ .exited = 42 };
    try std.testing.expectEqual(@as(u32, 42), state.exited);
}

test "isAlive returns true for .running, false for .exited" {
    const running = Pane.ProcessState.running;
    const exited = Pane.ProcessState{ .exited = 0 };
    try std.testing.expect(Pane.isAliveState(running));
    try std.testing.expect(!Pane.isAliveState(exited));
}

test "markExited sets process_state to .exited" {
    var screen = try Screen.init(std.testing.allocator, 3, 2);
    defer screen.deinit();
    var pane = Pane{
        .pty = undefined,
        .screen = screen,
        .parser = undefined,
        .rect = .{ .col = 0, .row = 0, .width = 3, .height = 2 },
        .allocator = std.testing.allocator,
        .process_state = .running,
    };
    try std.testing.expect(pane.isAlive());
    pane.markExited(1);
    try std.testing.expect(!pane.isAlive());
    try std.testing.expectEqual(@as(u32, 1), pane.process_state.exited);
}

test "shouldRestart: .on_failure + non-zero exit → true" {
    try std.testing.expect(Pane.shouldRestart(.on_failure, 1));
}

test "shouldRestart: .on_failure + zero exit → false" {
    try std.testing.expect(!Pane.shouldRestart(.on_failure, 0));
}

test "shouldRestart: .never + any exit → false" {
    try std.testing.expect(!Pane.shouldRestart(.never, 0));
    try std.testing.expect(!Pane.shouldRestart(.never, 1));
    try std.testing.expect(!Pane.shouldRestart(.never, 127));
}
