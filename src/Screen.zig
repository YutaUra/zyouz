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
    /// True when this cell is the left half of a wide (2-column) character.
    /// The right half is a continuation cell with char = 0.
    wide: bool = false,
    /// Index into Screen.hyperlink_urls (1-based); 0 means no hyperlink.
    hyperlink: u16 = 0,
};

/// Return the display width of a Unicode codepoint: 2 for fullwidth/wide
/// characters (CJK ideographs, Hangul syllables, fullwidth forms, etc.),
/// 1 for everything else.
pub fn charWidth(cp: u21) u2 {
    if (cp < 0x1100) return 1;
    if (cp <= 0x115F) return 2; // Hangul Jamo
    if (cp >= 0x2329 and cp <= 0x232A) return 2; // Angle brackets
    if (cp >= 0x2E80 and cp <= 0x303E) return 2; // CJK Radicals, Kangxi, Symbols
    if (cp >= 0x3040 and cp <= 0x33FF) return 2; // Hiragana, Katakana, Bopomofo, etc.
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2; // CJK Extension A
    if (cp >= 0x4E00 and cp <= 0xA4CF) return 2; // CJK Unified + Yi
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2; // Hangul Syllables
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2; // CJK Compat Ideographs
    if (cp >= 0xFE10 and cp <= 0xFE19) return 2; // Vertical forms
    if (cp >= 0xFE30 and cp <= 0xFE4F) return 2; // CJK Compat Forms
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2; // Fullwidth Forms
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2; // Fullwidth Signs
    if (cp >= 0x20000 and cp <= 0x2FFFD) return 2; // CJK Extensions B-F
    if (cp >= 0x30000 and cp <= 0x3FFFD) return 2; // CJK Extension G
    return 1;
}

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
scrollback: ?[][]Cell,
scrollback_capacity: usize,
scrollback_head: usize,
scrollback_count: usize,
hyperlink_urls: std.ArrayListUnmanaged([]const u8) = .empty,
current_hyperlink: u16 = 0,

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
        .scrollback = null,
        .scrollback_capacity = 0,
        .scrollback_head = 0,
        .scrollback_count = 0,
    };
}

pub fn initWithScrollback(allocator: Allocator, width: u16, height: u16, capacity: usize) !Screen {
    var screen = try Screen.init(allocator, width, height);
    if (capacity > 0) {
        const sb = try allocator.alloc([]Cell, capacity);
        for (sb) |*row| {
            row.* = try allocator.alloc(Cell, width);
            @memset(row.*, Cell{});
        }
        screen.scrollback = sb;
        screen.scrollback_capacity = capacity;
    }
    return screen;
}

pub fn deinit(self: *Screen) void {
    for (self.hyperlink_urls.items) |url| {
        self.allocator.free(url);
    }
    self.hyperlink_urls.deinit(self.allocator);
    if (self.scrollback) |sb| {
        for (sb) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(sb);
    }
    self.allocator.free(self.cells);
}

pub fn scrollbackLen(self: *const Screen) usize {
    return self.scrollback_count;
}

pub fn scrollbackLine(self: *const Screen, index: usize) ?[]const Cell {
    const sb = self.scrollback orelse return null;
    if (index >= self.scrollback_count) return null;
    return sb[(self.scrollback_head + index) % self.scrollback_capacity];
}

pub fn cellAt(self: *const Screen, row: u16, col: u16) *const Cell {
    return &self.cells[@as(usize, row) * @as(usize, self.width) + @as(usize, col)];
}

pub fn cellAtMut(self: *Screen, row: u16, col: u16) *Cell {
    return &self.cells[@as(usize, row) * @as(usize, self.width) + @as(usize, col)];
}

pub fn writeChar(self: *Screen, char: u21) void {
    const w: u2 = charWidth(char);

    if (self.wrap_pending) {
        self.wrap_pending = false;
        self.cursor_col = 0;
        if (self.cursor_row >= self.scroll_bottom) {
            self.scrollUp(1);
        } else {
            self.cursor_row += 1;
        }
    }

    // Wide character at the last column: can't fit both halves.
    // Leave the column blank and move to the next line.
    if (w == 2 and self.cursor_col + 1 >= self.width) {
        self.cellAtMut(self.cursor_row, self.cursor_col).* = .{};
        self.cursor_col = 0;
        if (self.cursor_row >= self.scroll_bottom) {
            self.scrollUp(1);
        } else {
            self.cursor_row += 1;
        }
    }

    // Clean up if overwriting part of a previous wide character.
    {
        const cur = self.cellAtMut(self.cursor_row, self.cursor_col);
        if (cur.wide and self.cursor_col + 1 < self.width) {
            self.cellAtMut(self.cursor_row, self.cursor_col + 1).* = .{};
        }
        if (cur.char == 0 and self.cursor_col > 0) {
            const prev = self.cellAtMut(self.cursor_row, self.cursor_col - 1);
            if (prev.wide) prev.* = .{};
        }
    }

    const cell = self.cellAtMut(self.cursor_row, self.cursor_col);
    cell.* = .{
        .char = char,
        .fg = self.current_fg,
        .bg = self.current_bg,
        .style = self.current_style,
        .wide = (w == 2),
        .hyperlink = self.current_hyperlink,
    };

    if (w == 2) {
        // Write continuation marker in the next column.
        if (self.cursor_col + 1 < self.width) {
            const next = self.cellAtMut(self.cursor_row, self.cursor_col + 1);
            // If the next cell was itself the left half of a wide char, clean up.
            if (next.wide and self.cursor_col + 2 < self.width) {
                self.cellAtMut(self.cursor_row, self.cursor_col + 2).* = .{};
            }
            next.* = .{
                .char = 0,
                .fg = self.current_fg,
                .bg = self.current_bg,
                .style = self.current_style,
            };
        }
        if (self.cursor_col + 2 >= self.width) {
            self.wrap_pending = true;
        } else {
            self.cursor_col += 2;
        }
    } else {
        if (self.cursor_col >= self.width - 1) {
            self.wrap_pending = true;
        } else {
            self.cursor_col += 1;
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
    self.wrap_pending = false;
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
    self.current_hyperlink = 0;
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

pub fn internHyperlink(self: *Screen, url: []const u8) !u16 {
    for (self.hyperlink_urls.items, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, url)) return @intCast(i + 1);
    }
    const duped = try self.allocator.dupe(u8, url);
    try self.hyperlink_urls.append(self.allocator, duped);
    return @intCast(self.hyperlink_urls.items.len);
}

pub fn hyperlinkUrl(self: *const Screen, idx: u16) ?[]const u8 {
    if (idx == 0) return null;
    const i = idx - 1;
    if (i >= self.hyperlink_urls.items.len) return null;
    return self.hyperlink_urls.items[i];
}

/// Extract text from a single row, columns start_col to end_col inclusive.
/// Returns the slice of buf that was written.
pub fn extractLineText(self: *const Screen, row: u16, start_col: u16, end_col: u16, buf: []u8) []const u8 {
    var pos: usize = 0;
    var col = start_col;
    while (col <= end_col and col < self.width) : (col += 1) {
        const cell = self.cellAt(row, col);
        if (cell.char == 0) continue; // skip wide char continuation
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cell.char, &utf8_buf) catch continue;
        if (pos + len > buf.len) break;
        @memcpy(buf[pos..][0..len], utf8_buf[0..len]);
        pos += len;
    }
    // Trim trailing spaces
    while (pos > 0 and buf[pos - 1] == ' ') pos -= 1;
    return buf[0..pos];
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

    // Save lines pushed off screen into scrollback buffer.
    // Only when scrolling the full screen (scroll_top == 0),
    // not within a scroll region set by the application.
    if (self.scrollback) |sb| {
        if (self.scroll_top == 0) {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const sb_idx = if (self.scrollback_count < self.scrollback_capacity)
                    self.scrollback_count
                else
                    (self.scrollback_head + self.scrollback_count) % self.scrollback_capacity;

                const src_start = (top + i) * w;
                @memcpy(sb[sb_idx], self.cells[src_start .. src_start + w]);

                if (self.scrollback_count < self.scrollback_capacity) {
                    self.scrollback_count += 1;
                } else {
                    self.scrollback_head = (self.scrollback_head + 1) % self.scrollback_capacity;
                }
            }
        }
    }

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

// --- Scrollback buffer tests ---

test "initWithScrollback creates screen with empty scrollback" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 10, 5, 100);
    defer screen.deinit();

    try std.testing.expectEqual(@as(usize, 0), screen.scrollbackLen());
    try std.testing.expect(screen.scrollback != null);
    try std.testing.expectEqual(@as(usize, 100), screen.scrollback_capacity);
}

test "Screen.init has no scrollback (backward compat)" {
    var screen = try Screen.init(std.testing.allocator, 10, 5);
    defer screen.deinit();

    try std.testing.expectEqual(@as(usize, 0), screen.scrollbackLen());
    try std.testing.expect(screen.scrollback == null);
}

test "scrollUp saves pushed line to scrollback" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 3, 2, 10);
    defer screen.deinit();

    // Write "ABC" on row 0, "DEF" on row 1
    for ("ABC") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    for ("DEF") |c| screen.writeChar(c);

    // Scroll up 1 — row 0 ("ABC") should be saved to scrollback
    screen.scrollUp(1);

    try std.testing.expectEqual(@as(usize, 1), screen.scrollbackLen());
    const line = screen.scrollbackLine(0).?;
    try std.testing.expectEqual(@as(u21, 'A'), line[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), line[1].char);
    try std.testing.expectEqual(@as(u21, 'C'), line[2].char);
}

test "scroll region scroll does not save to scrollback" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 3, 5, 10);
    defer screen.deinit();

    for ("AAABBBCCCDDDEEE") |c| screen.writeChar(c);
    screen.setScrollRegion(1, 3);
    screen.scrollUp(1);

    try std.testing.expectEqual(@as(usize, 0), screen.scrollbackLen());
}

test "scrollback wraps around when capacity exceeded" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 3, 2, 3);
    defer screen.deinit();

    // Push 5 lines through a 2-row screen with capacity=3
    // Lines: "111", "222", "333", "444", "555"
    // After all scrolls, scrollback should have last 3: "333", "444", "555"

    for ("111") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    for ("222") |c| screen.writeChar(c);
    screen.scrollUp(1); // saves "111", screen now: "222", blank

    screen.setCursorPos(1, 0);
    for ("333") |c| screen.writeChar(c);
    screen.scrollUp(1); // saves "222", screen now: "333", blank

    screen.setCursorPos(1, 0);
    for ("444") |c| screen.writeChar(c);
    screen.scrollUp(1); // saves "333", screen now: "444", blank (count=3, full)

    screen.setCursorPos(1, 0);
    for ("555") |c| screen.writeChar(c);
    screen.scrollUp(1); // saves "444", wraps, overwrites "111"

    screen.setCursorPos(1, 0);
    for ("666") |c| screen.writeChar(c);
    screen.scrollUp(1); // saves "555", wraps, overwrites "222"

    try std.testing.expectEqual(@as(usize, 3), screen.scrollbackLen());

    // Oldest should be "333"
    const line0 = screen.scrollbackLine(0).?;
    try std.testing.expectEqual(@as(u21, '3'), line0[0].char);

    // Middle should be "444"
    const line1 = screen.scrollbackLine(1).?;
    try std.testing.expectEqual(@as(u21, '4'), line1[0].char);

    // Newest should be "555"
    const line2 = screen.scrollbackLine(2).?;
    try std.testing.expectEqual(@as(u21, '5'), line2[0].char);
}

test "scrollback preserves cell styles" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 3, 2, 10);
    defer screen.deinit();

    screen.current_fg = .{ .indexed = 1 };
    screen.current_style.bold = true;
    for ("ABC") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    screen.resetAttributes();
    for ("DEF") |c| screen.writeChar(c);

    screen.scrollUp(1);

    const line = screen.scrollbackLine(0).?;
    try std.testing.expectEqual(Screen.Color{ .indexed = 1 }, line[0].fg);
    try std.testing.expect(line[0].style.bold);
}

test "scrollbackLine returns null for out-of-range index" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 3, 2, 10);
    defer screen.deinit();

    try std.testing.expect(screen.scrollbackLine(0) == null);

    for ("ABC") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    for ("DEF") |c| screen.writeChar(c);
    screen.scrollUp(1);

    try std.testing.expect(screen.scrollbackLine(0) != null);
    try std.testing.expect(screen.scrollbackLine(1) == null);
}

test "cell stores hyperlink index" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    const url = "https://example.com";
    const idx = try screen.internHyperlink(url);
    try std.testing.expect(idx > 0);

    screen.current_hyperlink = idx;
    screen.writeChar('A');

    const cell = screen.cellAt(0, 0);
    try std.testing.expectEqual(idx, cell.hyperlink);
    try std.testing.expectEqualStrings(url, screen.hyperlinkUrl(idx).?);
}

test "internHyperlink deduplicates same URL" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    const idx1 = try screen.internHyperlink("https://example.com");
    const idx2 = try screen.internHyperlink("https://example.com");
    const idx3 = try screen.internHyperlink("https://other.com");

    try std.testing.expectEqual(idx1, idx2);
    try std.testing.expect(idx3 != idx1);
}

test "resetAttributes clears current hyperlink" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    const idx = try screen.internHyperlink("https://example.com");
    screen.current_hyperlink = idx;
    screen.resetAttributes();

    try std.testing.expectEqual(@as(u16, 0), screen.current_hyperlink);
}

test "extractLineText returns cell characters as UTF-8" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.writeChar('H');
    screen.writeChar('i');
    screen.writeChar('!');

    var buf: [64]u8 = undefined;
    const text = screen.extractLineText(0, 0, 2, &buf);
    try std.testing.expectEqualStrings("Hi!", text);
}

test "carriageReturn clears wrap_pending" {
    var screen = try Screen.init(std.testing.allocator, 5, 2);
    defer screen.deinit();

    // Fill the line to trigger wrap_pending.
    for ("ABCDE") |c| screen.writeChar(c);
    try std.testing.expect(screen.wrap_pending);

    // CR should go back to column 0 on the SAME line and clear wrap_pending.
    screen.carriageReturn();
    try std.testing.expect(!screen.wrap_pending);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);

    // Writing after CR overwrites on the same line, not the next.
    screen.writeChar('X');
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(u21, 'X'), screen.cellAt(0, 0).char);
}
