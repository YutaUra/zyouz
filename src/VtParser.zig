const std = @import("std");
const Screen = @import("Screen.zig");

const VtParser = @This();

const State = enum {
    ground,
    escape,
    csi_entry,
    csi_param,
    csi_intermediate,
    osc_string,
};

const max_params = 16;

screen: *Screen,
state: State,
params: [max_params]u16,
param_count: u8,
private_mode: bool,

pub fn init(screen: *Screen) VtParser {
    return .{
        .screen = screen,
        .state = .ground,
        .params = [_]u16{0} ** max_params,
        .param_count = 0,
        .private_mode = false,
    };
}

pub fn feed(self: *VtParser, data: []const u8) void {
    for (data) |byte| {
        self.processByte(byte);
    }
}

fn processByte(self: *VtParser, byte: u8) void {
    switch (self.state) {
        .ground => self.processGround(byte),
        .escape => self.processEscape(byte),
        .csi_entry, .csi_param => self.processCsi(byte),
        .csi_intermediate => self.processCsiIntermediate(byte),
        .osc_string => self.processOsc(byte),
    }
}

fn processGround(self: *VtParser, byte: u8) void {
    switch (byte) {
        0x1B => self.state = .escape,
        0x0A, 0x0B, 0x0C => self.screen.newline(), // LF, VT, FF
        0x0D => self.screen.carriageReturn(),
        0x08 => self.screen.backspace(),
        0x09 => self.screen.tab(),
        0x07 => {}, // BEL — ignore
        0x00...0x06, 0x0E...0x1A, 0x1C...0x1F => {}, // other C0 — ignore
        0x20...0x7E => self.screen.writeChar(@as(u21, byte)),
        0x7F => {}, // DEL — ignore
        0x80...0xFF => {}, // high bytes — ignore for now
    }
}

fn processEscape(self: *VtParser, byte: u8) void {
    switch (byte) {
        '[' => {
            self.state = .csi_entry;
            self.resetParams();
        },
        ']' => self.state = .osc_string,
        '7' => {
            self.screen.saveCursor();
            self.state = .ground;
        },
        '8' => {
            self.screen.restoreCursor();
            self.state = .ground;
        },
        'M' => {
            self.reverseIndex();
            self.state = .ground;
        },
        'c' => {
            self.fullReset();
            self.state = .ground;
        },
        else => self.state = .ground,
    }
}

fn processCsi(self: *VtParser, byte: u8) void {
    switch (byte) {
        '0'...'9' => {
            if (self.param_count == 0) self.param_count = 1;
            const idx = self.param_count - 1;
            if (idx < max_params) {
                self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
            }
            self.state = .csi_param;
        },
        ';' => {
            if (self.param_count < max_params) {
                self.param_count += 1;
            }
            self.state = .csi_param;
        },
        '?' => {
            self.private_mode = true;
            self.state = .csi_param;
        },
        0x20...0x2F => self.state = .csi_intermediate,
        0x40...0x7E => {
            self.dispatchCsi(byte);
            self.state = .ground;
        },
        0x1B => {
            // ESC interrupts CSI
            self.state = .escape;
            self.resetParams();
        },
        else => self.state = .ground,
    }
}

fn processCsiIntermediate(self: *VtParser, byte: u8) void {
    switch (byte) {
        0x20...0x2F => {}, // accumulate intermediates (ignored)
        0x40...0x7E => {
            // Final byte — ignore intermediate sequences for now
            self.state = .ground;
        },
        else => self.state = .ground,
    }
}

fn processOsc(self: *VtParser, byte: u8) void {
    switch (byte) {
        0x07 => self.state = .ground, // BEL terminates OSC
        0x1B => self.state = .escape, // ESC \ (ST) — escape state will handle
        else => {}, // consume OSC payload
    }
}

fn dispatchCsi(self: *VtParser, final: u8) void {
    if (self.private_mode) {
        self.dispatchPrivateMode(final);
        return;
    }
    switch (final) {
        'H', 'f' => { // CUP — Cursor Position
            const row = self.getParam(0, 1);
            const col = self.getParam(1, 1);
            self.screen.setCursorPos(row -| 1, col -| 1);
        },
        'A' => self.screen.moveCursorUp(self.getParam(0, 1)), // CUU
        'B' => self.screen.moveCursorDown(self.getParam(0, 1)), // CUD
        'C' => self.screen.moveCursorForward(self.getParam(0, 1)), // CUF
        'D' => self.screen.moveCursorBack(self.getParam(0, 1)), // CUB
        'G' => { // CHA — Cursor Horizontal Absolute
            const col = self.getParam(0, 1);
            self.screen.cursor_col = @min(col -| 1, self.screen.width - 1);
        },
        'd' => { // VPA — Vertical Position Absolute
            const row = self.getParam(0, 1);
            self.screen.cursor_row = @min(row -| 1, self.screen.height - 1);
        },
        'J' => { // ED — Erase in Display
            const mode = self.getParam(0, 0);
            switch (mode) {
                0 => self.screen.eraseInDisplay(.to_end),
                1 => self.screen.eraseInDisplay(.to_start),
                2, 3 => self.screen.eraseInDisplay(.all),
                else => {},
            }
        },
        'K' => { // EL — Erase in Line
            const mode = self.getParam(0, 0);
            switch (mode) {
                0 => self.screen.eraseInLine(.to_end),
                1 => self.screen.eraseInLine(.to_start),
                2 => self.screen.eraseInLine(.all),
                else => {},
            }
        },
        'L' => self.screen.insertLines(self.getParam(0, 1)), // IL
        'M' => self.screen.deleteLines(self.getParam(0, 1)), // DL
        'm' => self.handleSgr(), // SGR
        'r' => { // DECSTBM — Set Scrolling Region
            const top = self.getParam(0, 1);
            const bottom = self.getParam(1, self.screen.height);
            self.screen.setScrollRegion(top -| 1, bottom -| 1);
            self.screen.setCursorPos(0, 0);
        },
        's' => self.screen.saveCursor(),
        'u' => self.screen.restoreCursor(),
        'P' => { // DCH — Delete Character
            const n = self.getParam(0, 1);
            self.deleteChars(n);
        },
        '@' => { // ICH — Insert Character
            const n = self.getParam(0, 1);
            self.insertChars(n);
        },
        'X' => { // ECH — Erase Character
            const n = self.getParam(0, 1);
            self.eraseChars(n);
        },
        else => {}, // Unknown CSI — ignore
    }
}

fn dispatchPrivateMode(self: *VtParser, final: u8) void {
    const param = self.getParam(0, 0);
    switch (final) {
        'h' => { // DECSET
            switch (param) {
                25 => self.screen.cursor_visible = true,
                else => {},
            }
        },
        'l' => { // DECRST
            switch (param) {
                25 => self.screen.cursor_visible = false,
                else => {},
            }
        },
        else => {},
    }
}

fn handleSgr(self: *VtParser) void {
    if (self.param_count == 0) {
        self.screen.resetAttributes();
        return;
    }
    var i: u8 = 0;
    while (i < self.param_count) {
        const p = self.params[i];
        switch (p) {
            0 => self.screen.resetAttributes(),
            1 => self.screen.current_style.bold = true,
            2 => self.screen.current_style.dim = true,
            3 => self.screen.current_style.italic = true,
            4 => self.screen.current_style.underline = true,
            5 => self.screen.current_style.blink = true,
            7 => self.screen.current_style.inverse = true,
            8 => self.screen.current_style.hidden = true,
            9 => self.screen.current_style.strikethrough = true,
            22 => {
                self.screen.current_style.bold = false;
                self.screen.current_style.dim = false;
            },
            23 => self.screen.current_style.italic = false,
            24 => self.screen.current_style.underline = false,
            25 => self.screen.current_style.blink = false,
            27 => self.screen.current_style.inverse = false,
            28 => self.screen.current_style.hidden = false,
            29 => self.screen.current_style.strikethrough = false,
            30...37 => self.screen.current_fg = .{ .indexed = @intCast(p - 30) },
            38 => {
                i += 1;
                if (i < self.param_count) {
                    switch (self.params[i]) {
                        5 => { // 256-color
                            i += 1;
                            if (i < self.param_count) {
                                self.screen.current_fg = .{ .indexed = @intCast(self.params[i]) };
                            }
                        },
                        2 => { // RGB
                            if (i + 3 < self.param_count) {
                                self.screen.current_fg = .{ .rgb = .{
                                    .r = @intCast(self.params[i + 1]),
                                    .g = @intCast(self.params[i + 2]),
                                    .b = @intCast(self.params[i + 3]),
                                } };
                                i += 3;
                            }
                        },
                        else => {},
                    }
                }
            },
            39 => self.screen.current_fg = .default,
            40...47 => self.screen.current_bg = .{ .indexed = @intCast(p - 40) },
            48 => {
                i += 1;
                if (i < self.param_count) {
                    switch (self.params[i]) {
                        5 => { // 256-color
                            i += 1;
                            if (i < self.param_count) {
                                self.screen.current_bg = .{ .indexed = @intCast(self.params[i]) };
                            }
                        },
                        2 => { // RGB
                            if (i + 3 < self.param_count) {
                                self.screen.current_bg = .{ .rgb = .{
                                    .r = @intCast(self.params[i + 1]),
                                    .g = @intCast(self.params[i + 2]),
                                    .b = @intCast(self.params[i + 3]),
                                } };
                                i += 3;
                            }
                        },
                        else => {},
                    }
                }
            },
            49 => self.screen.current_bg = .default,
            90...97 => self.screen.current_fg = .{ .indexed = @intCast(p - 90 + 8) },
            100...107 => self.screen.current_bg = .{ .indexed = @intCast(p - 100 + 8) },
            else => {},
        }
        i += 1;
    }
}

fn reverseIndex(self: *VtParser) void {
    if (self.screen.cursor_row <= self.screen.scroll_top) {
        self.screen.scrollDown(1);
    } else {
        self.screen.cursor_row -= 1;
    }
}

fn fullReset(self: *VtParser) void {
    self.screen.cursor_row = 0;
    self.screen.cursor_col = 0;
    self.screen.scroll_top = 0;
    self.screen.scroll_bottom = self.screen.height - 1;
    self.screen.current_style = .{};
    self.screen.current_fg = .default;
    self.screen.current_bg = .default;
    self.screen.cursor_visible = true;
    self.screen.wrap_pending = false;
    @memset(self.screen.cells, Screen.Cell{});
}

fn deleteChars(self: *VtParser, n: u16) void {
    const row = self.screen.cursor_row;
    const col = self.screen.cursor_col;
    const w = self.screen.width;
    const count = @min(n, w - col);
    const row_start: usize = @as(usize, row) * @as(usize, w);

    if (col + count < w) {
        const src_start = row_start + col + count;
        const src_end = row_start + w;
        const dst_start = row_start + col;
        std.mem.copyForwards(Screen.Cell, self.screen.cells[dst_start .. dst_start + (src_end - src_start)], self.screen.cells[src_start..src_end]);
    }
    const blank_start = row_start + w - count;
    const blank_end = row_start + w;
    @memset(self.screen.cells[blank_start..blank_end], Screen.Cell{});
}

fn insertChars(self: *VtParser, n: u16) void {
    const row = self.screen.cursor_row;
    const col = self.screen.cursor_col;
    const w = self.screen.width;
    const count = @min(n, w - col);
    const row_start: usize = @as(usize, row) * @as(usize, w);

    if (col + count < w) {
        const src_start = row_start + col;
        const src_end = row_start + w - count;
        const dst_start = row_start + col + count;
        std.mem.copyBackwards(Screen.Cell, self.screen.cells[dst_start .. dst_start + (src_end - src_start)], self.screen.cells[src_start..src_end]);
    }
    const blank_start = row_start + col;
    const blank_end = row_start + col + count;
    @memset(self.screen.cells[blank_start..blank_end], Screen.Cell{});
}

fn eraseChars(self: *VtParser, n: u16) void {
    const row = self.screen.cursor_row;
    const col = self.screen.cursor_col;
    const w = self.screen.width;
    const count = @min(n, w - col);
    const row_start: usize = @as(usize, row) * @as(usize, w);
    const start = row_start + col;
    @memset(self.screen.cells[start .. start + count], Screen.Cell{});
}

fn getParam(self: *const VtParser, idx: u8, default: u16) u16 {
    if (idx < self.param_count and self.params[idx] != 0) {
        return self.params[idx];
    }
    return default;
}

fn resetParams(self: *VtParser) void {
    self.params = [_]u16{0} ** max_params;
    self.param_count = 0;
    self.private_mode = false;
}

test "printable ASCII writes to screen" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("Hi");

    try std.testing.expectEqual(@as(u21, 'H'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), screen.cellAt(0, 1).char);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_col);
}

test "CR and LF control characters" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("AB\r\nCD");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), screen.cellAt(1, 1).char);
}

test "backspace control character" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("AB\x08C");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cellAt(0, 1).char);
}

test "tab control character" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("A\tB");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(0, 8).char);
}

test "BEL is ignored without crash" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("A\x07B");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(0, 1).char);
}

// --- CSI tests ---

test "CSI H (CUP) moves cursor to home" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("ABC");
    parser.feed("\x1b[H");

    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_col);
}

test "CSI row;col H moves cursor to position (1-based)" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[5;10H");

    try std.testing.expectEqual(@as(u16, 4), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), screen.cursor_col);
}

test "CSI A moves cursor up" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    screen.setCursorPos(5, 10);
    parser.feed("\x1b[3A");

    try std.testing.expectEqual(@as(u16, 2), screen.cursor_row);
}

test "CSI B moves cursor down" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[3B");
    try std.testing.expectEqual(@as(u16, 3), screen.cursor_row);
}

test "CSI C moves cursor forward" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[5C");
    try std.testing.expectEqual(@as(u16, 5), screen.cursor_col);
}

test "CSI D moves cursor backward" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    screen.setCursorPos(0, 10);
    parser.feed("\x1b[3D");
    try std.testing.expectEqual(@as(u16, 7), screen.cursor_col);
}

test "CSI J erases display below cursor" {
    var screen = try Screen.init(std.testing.allocator, 5, 3);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("ABCDEFGHIJKLMNO");
    screen.setCursorPos(1, 2);
    parser.feed("\x1b[J");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'G'), screen.cellAt(1, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(1, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(2, 0).char);
}

test "CSI 2J erases entire display" {
    var screen = try Screen.init(std.testing.allocator, 5, 2);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("ABCDEFGHIJ");
    parser.feed("\x1b[2J");

    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(1, 4).char);
}

test "CSI K erases to end of line" {
    var screen = try Screen.init(std.testing.allocator, 5, 2);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("ABCDE");
    screen.setCursorPos(0, 2);
    parser.feed("\x1b[K");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 2).char);
}

test "CSI with default param (no number means 1)" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    screen.setCursorPos(5, 0);
    parser.feed("\x1b[A");

    try std.testing.expectEqual(@as(u16, 4), screen.cursor_row);
}

test "CSI L inserts lines" {
    var screen = try Screen.init(std.testing.allocator, 3, 3);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("AAABBBCCC");
    screen.setCursorPos(1, 0);
    parser.feed("\x1b[1L");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(2, 0).char);
}

test "CSI M deletes lines" {
    var screen = try Screen.init(std.testing.allocator, 3, 3);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("AAABBBCCC");
    screen.setCursorPos(1, 0);
    parser.feed("\x1b[1M");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(2, 0).char);
}

test "CSI r sets scroll region" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[5;20r");

    try std.testing.expectEqual(@as(u16, 4), screen.scroll_top);
    try std.testing.expectEqual(@as(u16, 19), screen.scroll_bottom);
}

test "incomplete CSI buffered across feed calls" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b");
    parser.feed("[5;10H");

    try std.testing.expectEqual(@as(u16, 4), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), screen.cursor_col);
}

test "unknown CSI final byte is consumed without crash" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[99z");
    parser.feed("A");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
}

// --- SGR tests ---

test "SGR 0 resets all attributes" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[1m");
    parser.feed("\x1b[0m");

    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(screen.current_style)));
    try std.testing.expectEqual(Screen.Color.default, screen.current_fg);
    try std.testing.expectEqual(Screen.Color.default, screen.current_bg);
}

test "SGR 1 sets bold" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[1m");
    try std.testing.expect(screen.current_style.bold);
}

test "SGR 31 sets foreground to red" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[31m");
    try std.testing.expectEqual(Screen.Color{ .indexed = 1 }, screen.current_fg);
}

test "SGR 42 sets background to green" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[42m");
    try std.testing.expectEqual(Screen.Color{ .indexed = 2 }, screen.current_bg);
}

test "SGR 91 sets bright red foreground" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[91m");
    try std.testing.expectEqual(Screen.Color{ .indexed = 9 }, screen.current_fg);
}

test "SGR 38;5;200 sets 256-color foreground" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[38;5;200m");
    try std.testing.expectEqual(Screen.Color{ .indexed = 200 }, screen.current_fg);
}

test "SGR 38;2;255;128;0 sets RGB foreground" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[38;2;255;128;0m");
    try std.testing.expectEqual(Screen.Color{ .rgb = .{ .r = 255, .g = 128, .b = 0 } }, screen.current_fg);
}

test "SGR 39 resets foreground to default" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[31m");
    parser.feed("\x1b[39m");

    try std.testing.expectEqual(Screen.Color.default, screen.current_fg);
}

test "multiple SGR params in one sequence" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[1;31;42m");

    try std.testing.expect(screen.current_style.bold);
    try std.testing.expectEqual(Screen.Color{ .indexed = 1 }, screen.current_fg);
    try std.testing.expectEqual(Screen.Color{ .indexed = 2 }, screen.current_bg);
}

test "SGR applies to subsequently written chars" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[1;31mA\x1b[0mB");

    const cell_a = screen.cellAt(0, 0);
    try std.testing.expect(cell_a.style.bold);
    try std.testing.expectEqual(Screen.Color{ .indexed = 1 }, cell_a.fg);

    const cell_b = screen.cellAt(0, 1);
    try std.testing.expect(!cell_b.style.bold);
    try std.testing.expectEqual(Screen.Color.default, cell_b.fg);
}
