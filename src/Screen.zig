const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Style = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    style: Style = .{},
};

const Screen = @This();

width: u16,
height: u16,
cells: []Cell,
cursor_row: u16,
cursor_col: u16,
scroll_top: u16,
scroll_bottom: u16,
saved_cursor_row: u16,
saved_cursor_col: u16,
current_style: Style,
current_fg: Color,
current_bg: Color,
cursor_visible: bool,
allocator: Allocator,

pub fn init(allocator: Allocator, width: u16, height: u16) !Screen {
    const cells = try allocator.alloc(Cell, @as(usize, width) * @as(usize, height));
    @memset(cells, Cell{});
    return .{
        .width = width,
        .height = height,
        .cells = cells,
        .cursor_row = 0,
        .cursor_col = 0,
        .scroll_top = 0,
        .scroll_bottom = height - 1,
        .saved_cursor_row = 0,
        .saved_cursor_col = 0,
        .current_style = .{},
        .current_fg = .default,
        .current_bg = .default,
        .cursor_visible = true,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Screen) void {
    self.allocator.free(self.cells);
}

pub fn cellAt(self: *const Screen, row: u16, col: u16) *const Cell {
    return &self.cells[@as(usize, row) * @as(usize, self.width) + @as(usize, col)];
}

pub fn cellAtMut(self: *Screen, row: u16, col: u16) *Cell {
    return &self.cells[@as(usize, row) * @as(usize, self.width) + @as(usize, col)];
}

pub fn writeChar(self: *Screen, char: u21) void {
    const cell = self.cellAtMut(self.cursor_row, self.cursor_col);
    cell.* = .{
        .char = char,
        .fg = self.current_fg,
        .bg = self.current_bg,
        .style = self.current_style,
    };
    self.cursor_col += 1;
    if (self.cursor_col >= self.width) {
        self.cursor_col = 0;
        if (self.cursor_row >= self.scroll_bottom) {
            self.scrollUp(1);
        } else {
            self.cursor_row += 1;
        }
    }
}

pub fn newline(self: *Screen) void {
    if (self.cursor_row >= self.scroll_bottom) {
        self.scrollUp(1);
    } else {
        self.cursor_row += 1;
    }
}

pub fn carriageReturn(self: *Screen) void {
    self.cursor_col = 0;
}

pub fn tab(self: *Screen) void {
    self.cursor_col = @min((self.cursor_col / 8 + 1) * 8, self.width - 1);
}

pub fn backspace(self: *Screen) void {
    if (self.cursor_col > 0) {
        self.cursor_col -= 1;
    }
}

pub fn scrollUp(self: *Screen, n: u16) void {
    const count = @min(n, self.scroll_bottom - self.scroll_top + 1);
    const w: usize = self.width;
    const top: usize = self.scroll_top;
    const bottom: usize = self.scroll_bottom;

    if (count > 0 and top + count <= bottom + 1) {
        const dst_start = top * w;
        const src_start = (top + count) * w;
        const src_end = (bottom + 1) * w;
        std.mem.copyForwards(Cell, self.cells[dst_start .. dst_start + (src_end - src_start)], self.cells[src_start..src_end]);
        // Blank new rows at bottom of scroll region
        const blank_start = (bottom + 1 - count) * w;
        const blank_end = (bottom + 1) * w;
        @memset(self.cells[blank_start..blank_end], Cell{});
    }
}

test "Cell default is space with default colors" {
    const cell = Cell{};
    try std.testing.expectEqual(@as(u21, ' '), cell.char);
    try std.testing.expectEqual(Color.default, cell.fg);
    try std.testing.expectEqual(Color.default, cell.bg);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(cell.style)));
}

test "writeChar places character and advances cursor" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.writeChar('H');
    screen.writeChar('i');

    try std.testing.expectEqual(@as(u21, 'H'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), screen.cellAt(0, 1).char);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_col);
}

test "writeChar wraps at end of line" {
    var screen = try Screen.init(std.testing.allocator, 5, 3);
    defer screen.deinit();

    for ("Hello!") |c| screen.writeChar(c);

    try std.testing.expectEqual(@as(u21, '!'), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_col);
}

test "writeChar at bottom-right scrolls screen up" {
    var screen = try Screen.init(std.testing.allocator, 3, 2);
    defer screen.deinit();

    for ("ABCDE") |c| screen.writeChar(c);
    screen.writeChar('F');
    screen.writeChar('G');

    try std.testing.expectEqual(@as(u21, 'D'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'G'), screen.cellAt(1, 0).char);
}

test "newline moves cursor down" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.writeChar('A');
    screen.newline();

    try std.testing.expectEqual(@as(u16, 1), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_col);
}

test "newline at bottom scrolls" {
    var screen = try Screen.init(std.testing.allocator, 5, 2);
    defer screen.deinit();

    screen.writeChar('A');
    screen.cursor_row = 1;
    screen.newline();

    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_row);
}

test "carriageReturn sets cursor col to 0" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.writeChar('A');
    screen.writeChar('B');
    screen.carriageReturn();

    try std.testing.expectEqual(@as(u16, 0), screen.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
}

test "tab advances to next 8-column stop" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.writeChar('A');
    screen.tab();

    try std.testing.expectEqual(@as(u16, 8), screen.cursor_col);
}

test "backspace moves cursor left" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.writeChar('A');
    screen.writeChar('B');
    screen.backspace();

    try std.testing.expectEqual(@as(u16, 1), screen.cursor_col);
}

test "backspace at col 0 stays at col 0" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.backspace();
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_col);
}

test "Screen init creates blank grid" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    try std.testing.expectEqual(@as(u16, 80), screen.width);
    try std.testing.expectEqual(@as(u16, 24), screen.height);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_col);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(23, 79).char);
}
