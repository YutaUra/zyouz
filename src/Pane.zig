const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const VtParser = @import("VtParser.zig");
const Pty = @import("Pty.zig");
const Terminal = @import("Terminal.zig");
const Layout = @import("Layout.zig");

const Pane = @This();

pty: Pty.Pty,
screen: Screen,
parser: VtParser,
rect: Layout.Rect,
allocator: Allocator,

pub fn initFromCommand(allocator: Allocator, command: []const []const u8, rect: Layout.Rect) !Pane {
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

    var screen = try Screen.init(allocator, rect.width, rect.height);
    const parser = VtParser.init(&screen);

    return .{
        .pty = pty,
        .screen = screen,
        .parser = parser,
        .rect = rect,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Pane) void {
    self.pty.kill();
    self.pty.deinit();
    self.screen.deinit();
}

pub fn feedOutput(self: *Pane, data: []const u8) void {
    self.parser.feed(data);
}

pub fn resize(self: *Pane, new_rect: Layout.Rect) !void {
    self.rect = new_rect;
    // Reallocate screen if dimensions changed
    if (new_rect.width != self.screen.width or new_rect.height != self.screen.height) {
        self.screen.deinit();
        self.screen = try Screen.init(self.allocator, new_rect.width, new_rect.height);
        self.parser = VtParser.init(&self.screen);
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
