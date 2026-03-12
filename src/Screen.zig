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

test "Cell default is space with default colors" {
    const cell = Cell{};
    try std.testing.expectEqual(@as(u21, ' '), cell.char);
    try std.testing.expectEqual(Color.default, cell.fg);
    try std.testing.expectEqual(Color.default, cell.bg);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(cell.style)));
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
