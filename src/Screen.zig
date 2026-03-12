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
wrap_pending: bool,
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
        .wrap_pending = false,
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
    if (self.wrap_pending) {
        self.wrap_pending = false;
        self.cursor_col = 0;
        if (self.cursor_row >= self.scroll_bottom) {
            self.scrollUp(1);
        } else {
            self.cursor_row += 1;
        }
    }

    const cell = self.cellAtMut(self.cursor_row, self.cursor_col);
    cell.* = .{
        .char = char,
        .fg = self.current_fg,
        .bg = self.current_bg,
        .style = self.current_style,
    };

    if (self.cursor_col >= self.width - 1) {
        self.wrap_pending = true;
    } else {
        self.cursor_col += 1;
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

pub const EraseMode = enum { to_end, to_start, all };

pub fn setCursorPos(self: *Screen, row: u16, col: u16) void {
    self.cursor_row = @min(row, self.height - 1);
    self.cursor_col = @min(col, self.width - 1);
    self.wrap_pending = false;
}

pub fn moveCursorUp(self: *Screen, n: u16) void {
    self.cursor_row -|= n;
}

pub fn moveCursorDown(self: *Screen, n: u16) void {
    self.cursor_row = @min(self.cursor_row + n, self.height - 1);
}

pub fn moveCursorForward(self: *Screen, n: u16) void {
    self.cursor_col = @min(self.cursor_col + n, self.width - 1);
}

pub fn moveCursorBack(self: *Screen, n: u16) void {
    self.cursor_col -|= n;
}

pub fn resetAttributes(self: *Screen) void {
    self.current_style = .{};
    self.current_fg = .default;
    self.current_bg = .default;
}

pub fn eraseInDisplay(self: *Screen, mode: EraseMode) void {
    switch (mode) {
        .to_end => {
            // Clear from cursor to end of line
            for (self.cursor_col..self.width) |col| {
                self.cellAtMut(self.cursor_row, @intCast(col)).* = Cell{};
            }
            // Clear all rows below
            var row: u16 = self.cursor_row + 1;
            while (row < self.height) : (row += 1) {
                self.clearRow(row);
            }
        },
        .to_start => {
            // Clear from start to cursor
            for (0..@as(usize, self.cursor_col) + 1) |col| {
                self.cellAtMut(self.cursor_row, @intCast(col)).* = Cell{};
            }
            // Clear all rows above
            var row: u16 = 0;
            while (row < self.cursor_row) : (row += 1) {
                self.clearRow(row);
            }
        },
        .all => {
            @memset(self.cells, Cell{});
        },
    }
}

pub fn eraseInLine(self: *Screen, mode: EraseMode) void {
    switch (mode) {
        .to_end => {
            for (self.cursor_col..self.width) |col| {
                self.cellAtMut(self.cursor_row, @intCast(col)).* = Cell{};
            }
        },
        .to_start => {
            for (0..@as(usize, self.cursor_col) + 1) |col| {
                self.cellAtMut(self.cursor_row, @intCast(col)).* = Cell{};
            }
        },
        .all => {
            self.clearRow(self.cursor_row);
        },
    }
}

pub fn insertLines(self: *Screen, n: u16) void {
    const count = @min(n, self.scroll_bottom - self.cursor_row + 1);
    if (count == 0) return;
    const w: usize = self.width;
    const cur: usize = self.cursor_row;
    const bottom: usize = self.scroll_bottom;

    // Shift rows down within scroll region
    if (cur + count <= bottom) {
        const src_start = cur * w;
        const src_end = (bottom + 1 - count) * w;
        const dst_start = (cur + count) * w;
        std.mem.copyBackwards(Cell, self.cells[dst_start .. dst_start + (src_end - src_start)], self.cells[src_start..src_end]);
    }
    // Blank the inserted rows
    const blank_start = cur * w;
    const blank_end = (cur + count) * w;
    @memset(self.cells[blank_start..blank_end], Cell{});
}

pub fn deleteLines(self: *Screen, n: u16) void {
    const count = @min(n, self.scroll_bottom - self.cursor_row + 1);
    if (count == 0) return;
    const w: usize = self.width;
    const cur: usize = self.cursor_row;
    const bottom: usize = self.scroll_bottom;

    // Shift rows up within scroll region
    if (cur + count <= bottom) {
        const src_start = (cur + count) * w;
        const src_end = (bottom + 1) * w;
        const dst_start = cur * w;
        std.mem.copyForwards(Cell, self.cells[dst_start .. dst_start + (src_end - src_start)], self.cells[src_start..src_end]);
    }
    // Blank the bottom rows
    const blank_start = (bottom + 1 - count) * w;
    const blank_end = (bottom + 1) * w;
    @memset(self.cells[blank_start..blank_end], Cell{});
}

pub fn setScrollRegion(self: *Screen, top: u16, bottom: u16) void {
    self.scroll_top = @min(top, self.height - 1);
    self.scroll_bottom = @min(bottom, self.height - 1);
}

pub fn scrollDown(self: *Screen, n: u16) void {
    const count = @min(n, self.scroll_bottom - self.scroll_top + 1);
    if (count == 0) return;
    const w: usize = self.width;
    const top: usize = self.scroll_top;
    const bottom: usize = self.scroll_bottom;

    // Shift rows down
    if (top + count <= bottom) {
        const src_start = top * w;
        const src_end = (bottom + 1 - count) * w;
        const dst_start = (top + count) * w;
        std.mem.copyBackwards(Cell, self.cells[dst_start .. dst_start + (src_end - src_start)], self.cells[src_start..src_end]);
    }
    // Blank new rows at top
    const blank_start = top * w;
    const blank_end = (top + count) * w;
    @memset(self.cells[blank_start..blank_end], Cell{});
}

pub fn saveCursor(self: *Screen) void {
    self.saved_cursor_row = self.cursor_row;
    self.saved_cursor_col = self.cursor_col;
}

pub fn restoreCursor(self: *Screen) void {
    self.cursor_row = self.saved_cursor_row;
    self.cursor_col = self.saved_cursor_col;
}

fn clearRow(self: *Screen, row: u16) void {
    const start: usize = @as(usize, row) * @as(usize, self.width);
    const end: usize = start + @as(usize, self.width);
    @memset(self.cells[start..end], Cell{});
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

test "eraseInDisplay to_end clears from cursor to end" {
    var screen = try Screen.init(std.testing.allocator, 5, 3);
    defer screen.deinit();

    for ("ABCDEFGHIJKLMNO") |c| screen.writeChar(c);
    screen.setCursorPos(1, 2);
    screen.eraseInDisplay(.to_end);

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'F'), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'G'), screen.cellAt(1, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(1, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(2, 0).char);
}

test "eraseInDisplay all clears entire screen" {
    var screen = try Screen.init(std.testing.allocator, 5, 2);
    defer screen.deinit();

    for ("ABCDEFGHIJ") |c| screen.writeChar(c);
    screen.eraseInDisplay(.all);

    for (0..2) |row| {
        for (0..5) |col| {
            try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(@intCast(row), @intCast(col)).char);
        }
    }
}

test "eraseInLine to_end clears from cursor to end of line" {
    var screen = try Screen.init(std.testing.allocator, 5, 2);
    defer screen.deinit();

    for ("ABCDE") |c| screen.writeChar(c);
    screen.setCursorPos(0, 2);
    screen.eraseInLine(.to_end);

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 4).char);
}

test "setCursorPos clamps to screen bounds" {
    var screen = try Screen.init(std.testing.allocator, 5, 3);
    defer screen.deinit();

    screen.setCursorPos(100, 100);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 4), screen.cursor_col);
}

test "moveCursorUp moves cursor up by n" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursorPos(5, 10);
    screen.moveCursorUp(3);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 10), screen.cursor_col);
}

test "moveCursorUp clamps at row 0" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursorPos(2, 0);
    screen.moveCursorUp(10);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
}

test "moveCursorDown moves cursor down by n" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursorPos(5, 10);
    screen.moveCursorDown(3);
    try std.testing.expectEqual(@as(u16, 8), screen.cursor_row);
}

test "moveCursorForward and moveCursorBack" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursorPos(0, 10);
    screen.moveCursorForward(5);
    try std.testing.expectEqual(@as(u16, 15), screen.cursor_col);
    screen.moveCursorBack(3);
    try std.testing.expectEqual(@as(u16, 12), screen.cursor_col);
}

test "insertLines pushes lines down within scroll region" {
    var screen = try Screen.init(std.testing.allocator, 3, 4);
    defer screen.deinit();

    for ("AAABBBCCCDDD") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    screen.insertLines(1);

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cellAt(3, 0).char);
}

test "deleteLines removes lines and shifts up" {
    var screen = try Screen.init(std.testing.allocator, 3, 4);
    defer screen.deinit();

    for ("AAABBBCCCDDD") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    screen.deleteLines(1);

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), screen.cellAt(2, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(3, 0).char);
}

test "setScrollRegion limits scrolling" {
    var screen = try Screen.init(std.testing.allocator, 3, 5);
    defer screen.deinit();

    for ("AAABBBCCCDDDEEE") |c| screen.writeChar(c);
    screen.setScrollRegion(1, 3);
    screen.setCursorPos(3, 0);
    screen.scrollUp(1);

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), screen.cellAt(2, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'E'), screen.cellAt(4, 0).char);
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
