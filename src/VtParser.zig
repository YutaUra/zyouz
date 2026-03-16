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
    utf8,
};

const max_params = 16;

screen: *Screen,
state: State,
params: [max_params]u16,
param_count: u8,
/// Leading CSI prefix byte: '?' for DEC private, '>' / '<' / '=' for
/// Kitty keyboard protocol and similar extensions, 0 for standard CSI.
csi_prefix: u8,
utf8_buf: [4]u8 = undefined,
utf8_len: u3 = 0,
utf8_expected: u3 = 0,
/// Buffer for responses to terminal queries (DSR, DA1).
/// Caller should forward these bytes back to the child PTY.
response_buf: [64]u8 = undefined,
response_len: u8 = 0,
osc_buf: [2048]u8 = undefined,
osc_len: u16 = 0,

pub fn init(screen: *Screen) VtParser {
    return .{
        .screen = screen,
        .state = .ground,
        .params = [_]u16{0} ** max_params,
        .param_count = 0,
        .csi_prefix = 0,
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
        .utf8 => self.processUtf8(byte),
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
        0x80...0xBF => {}, // stray continuation bytes — ignore
        0xC0...0xDF => self.startUtf8(byte, 2),
        0xE0...0xEF => self.startUtf8(byte, 3),
        0xF0...0xF7 => self.startUtf8(byte, 4),
        0xF8...0xFF => {}, // invalid UTF-8 leading bytes — ignore
    }
}

fn startUtf8(self: *VtParser, byte: u8, expected: u3) void {
    self.utf8_buf[0] = byte;
    self.utf8_len = 1;
    self.utf8_expected = expected;
    self.state = .utf8;
}

fn processUtf8(self: *VtParser, byte: u8) void {
    // C0 controls and ESC interrupt UTF-8 sequence
    if (byte <= 0x1F or byte == 0x7F) {
        self.state = .ground;
        self.processGround(byte);
        return;
    }
    // Must be a continuation byte (0x80-0xBF)
    if (byte & 0xC0 != 0x80) {
        // Not a continuation byte — abort sequence, reprocess as ground
        self.state = .ground;
        self.processGround(byte);
        return;
    }
    self.utf8_buf[self.utf8_len] = byte;
    self.utf8_len += 1;
    if (self.utf8_len == self.utf8_expected) {
        const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch {
            self.state = .ground;
            return;
        };
        self.screen.writeChar(cp);
        self.state = .ground;
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
        '\\' => {
            // ST (String Terminator) — dispatch buffered OSC if any
            if (self.osc_len > 0) {
                self.dispatchOsc();
            }
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
        '?', '<', '=', '>' => {
            self.csi_prefix = byte;
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
        0x07 => {
            self.dispatchOsc();
            self.state = .ground;
        },
        0x1B => self.state = .escape,
        else => {
            if (self.osc_len < self.osc_buf.len) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
        },
    }
}

fn dispatchCsi(self: *VtParser, final: u8) void {
    if (self.csi_prefix == '?') {
        self.dispatchDecPrivate(final);
        return;
    }
    // CSI sequences with '>', '<', '=' prefixes (e.g. Kitty keyboard
    // protocol) are silently consumed — we don't support them yet.
    if (self.csi_prefix != 0) return;
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
        'S' => self.screen.scrollUp(self.getParam(0, 1)), // SU — Scroll Up
        'T' => self.screen.scrollDown(self.getParam(0, 1)), // SD — Scroll Down
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
        'n' => { // DSR — Device Status Report
            const mode = self.getParam(0, 0);
            if (mode == 6) {
                // CPR — Cursor Position Report (1-based)
                const row = self.screen.cursor_row + 1;
                const col = self.screen.cursor_col + 1;
                const resp = std.fmt.bufPrint(&self.response_buf, "\x1b[{d};{d}R", .{ row, col }) catch return;
                self.response_len = @intCast(resp.len);
            }
        },
        'c' => { // DA1 — Device Attributes
            // Respond as VT100 with Advanced Video Option.
            const resp = "\x1b[?1;2c";
            @memcpy(self.response_buf[0..resp.len], resp);
            self.response_len = @intCast(resp.len);
        },
        else => {}, // Unknown CSI — ignore
    }
}

fn dispatchDecPrivate(self: *VtParser, final: u8) void {
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
    self.csi_prefix = 0;
    self.osc_len = 0;
}

fn dispatchOsc(self: *VtParser) void {
    const payload = self.osc_buf[0..self.osc_len];
    self.osc_len = 0;

    // Check for "8;" prefix (OSC 8)
    if (payload.len >= 2 and payload[0] == '8' and payload[1] == ';') {
        self.handleOsc8(payload[2..]);
        return;
    }
}

fn handleOsc8(self: *VtParser, data: []const u8) void {
    // Format: params;url
    const sep = std.mem.indexOfScalar(u8, data, ';') orelse return;
    const url = data[sep + 1 ..];

    if (url.len == 0) {
        self.screen.current_hyperlink = 0;
    } else {
        self.screen.current_hyperlink = self.screen.internHyperlink(url) catch 0;
    }
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

// --- ESC / OSC tests ---

test "ESC 7 saves cursor and ESC 8 restores" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    screen.setCursorPos(5, 10);
    parser.feed("\x1b7");
    screen.setCursorPos(0, 0);
    parser.feed("\x1b8");

    try std.testing.expectEqual(@as(u16, 5), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 10), screen.cursor_col);
}

test "ESC M reverse index scrolls down" {
    var screen = try Screen.init(std.testing.allocator, 3, 3);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("AAABBBCCC");
    screen.setCursorPos(0, 0);
    parser.feed("\x1bM");

    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(2, 0).char);
}

test "CSI ?25l hides cursor" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b[?25l");
    try std.testing.expect(!screen.cursor_visible);
}

test "CSI ?25h shows cursor" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    screen.cursor_visible = false;
    parser.feed("\x1b[?25h");
    try std.testing.expect(screen.cursor_visible);
}

test "OSC string consumed and ignored" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b]0;my title\x07");
    parser.feed("A");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
}

test "OSC terminated by ST (ESC backslash)" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b]0;title\x1b\\");
    parser.feed("B");

    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(0, 0).char);
}

test "CSI S scrolls content up" {
    var screen = try Screen.init(std.testing.allocator, 3, 3);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("AAABBBCCC");
    parser.feed("\x1b[1S");

    // Row 0 should now be "BBB" (shifted up)
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(0, 0).char);
    // Row 1 should now be "CCC"
    try std.testing.expectEqual(@as(u21, 'C'), screen.cellAt(1, 0).char);
    // Row 2 should be blank
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(2, 0).char);
}

test "CSI T scrolls content down" {
    var screen = try Screen.init(std.testing.allocator, 3, 3);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("AAABBBCCC");
    parser.feed("\x1b[1T");

    // Row 0 should be blank (new)
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 0).char);
    // Row 1 should now be "AAA"
    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(1, 0).char);
    // Row 2 should now be "BBB"
    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(2, 0).char);
}

test "CSI with > prefix is silently consumed (Kitty keyboard push)" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    // \e[>1u (push keyboard mode) must not print "1u"
    parser.feed("\x1b[>1u");
    parser.feed("A");

    try std.testing.expectEqual(@as(u21, 'A'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_col);
}

test "CSI with < prefix is silently consumed (Kitty keyboard pop)" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    // \e[<u (pop keyboard mode) must not print "u"
    parser.feed("\x1b[<u");
    parser.feed("B");

    try std.testing.expectEqual(@as(u21, 'B'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_col);
}

test "OSC 8 hyperlink sets current hyperlink on screen" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    // ESC ] 8 ; ; https://example.com ESC \ A ESC ] 8 ; ; ESC \ B
    parser.feed("\x1b]8;;https://example.com\x1b\\");
    parser.feed("A");
    parser.feed("\x1b]8;;\x1b\\");
    parser.feed("B");

    const cell_a = screen.cellAt(0, 0);
    try std.testing.expect(cell_a.hyperlink > 0);
    try std.testing.expectEqualStrings(
        "https://example.com",
        screen.hyperlinkUrl(cell_a.hyperlink).?,
    );

    const cell_b = screen.cellAt(0, 1);
    try std.testing.expectEqual(@as(u16, 0), cell_b.hyperlink);
}

test "OSC 8 hyperlink with BEL terminator" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b]8;;https://zig.dev\x07");
    parser.feed("Z");
    parser.feed("\x1b]8;;\x07");

    const cell = screen.cellAt(0, 0);
    try std.testing.expect(cell.hyperlink > 0);
    try std.testing.expectEqualStrings(
        "https://zig.dev",
        screen.hyperlinkUrl(cell.hyperlink).?,
    );
}

test "OSC 8 pipeline trace - cells have hyperlink after feed" {
    var screen = try Screen.init(std.testing.allocator, 40, 5);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    // Feed: open hyperlink, text, close hyperlink
    parser.feed("\x1b]8;;https://example.com\x1b\\");

    // After opening hyperlink, current_hyperlink should be non-zero
    try std.testing.expect(screen.current_hyperlink > 0);
    const link_idx = screen.current_hyperlink;

    parser.feed("Click me");

    // Check each cell of "Click me"
    const expected = "Click me";
    for (expected, 0..) |ch, i| {
        const cell = screen.cellAt(0, @intCast(i));
        try std.testing.expectEqual(@as(u21, ch), cell.char);
        try std.testing.expectEqual(link_idx, cell.hyperlink);
    }

    // Close hyperlink
    parser.feed("\x1b]8;;\x1b\\");
    try std.testing.expectEqual(@as(u16, 0), screen.current_hyperlink);

    // Next char should have no hyperlink
    parser.feed("X");
    const cell_x = screen.cellAt(0, 8);
    try std.testing.expectEqual(@as(u16, 0), cell_x.hyperlink);
}

test "OSC 8 with id parameter" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    // id=foo:https://example.com
    parser.feed("\x1b]8;id=foo;https://example.com\x1b\\");
    parser.feed("X");

    const cell = screen.cellAt(0, 0);
    try std.testing.expect(cell.hyperlink > 0);
    try std.testing.expectEqualStrings(
        "https://example.com",
        screen.hyperlinkUrl(cell.hyperlink).?,
    );
}

test "OSC 8 switching links without explicit close" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    parser.feed("\x1b]8;;https://a.com\x1b\\");
    parser.feed("A");
    parser.feed("\x1b]8;;https://b.com\x1b\\");
    parser.feed("B");
    parser.feed("\x1b]8;;\x1b\\");

    const cell_a = screen.cellAt(0, 0);
    const cell_b = screen.cellAt(0, 1);

    try std.testing.expectEqualStrings("https://a.com", screen.hyperlinkUrl(cell_a.hyperlink).?);
    try std.testing.expectEqualStrings("https://b.com", screen.hyperlinkUrl(cell_b.hyperlink).?);
}

test "Kitty keyboard push + pop produces no visible output" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = VtParser.init(&screen);

    // Simulate Claude Code startup: query + push + pop
    parser.feed("\x1b[?u"); // query keyboard mode
    parser.feed("\x1b[>1u"); // push keyboard mode
    parser.feed("\x1b[<u"); // pop keyboard mode
    parser.feed("X");

    // Only 'X' should be visible — no "1uu" or any other leaked chars
    try std.testing.expectEqual(@as(u21, 'X'), screen.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cellAt(0, 1).char);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_col);
}
