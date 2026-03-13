const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const Layout = @import("Layout.zig");

const Renderer = @This();

const BorderDir = struct {
    horizontal: bool = false,
    vertical: bool = false,
};

const Pane = @import("Pane.zig");

const active_color = Screen.Color{ .indexed = 2 }; // green
const command_mode_color = Screen.Color{ .indexed = 3 }; // yellow
const inactive_color = Screen.Color{ .indexed = 8 }; // dark gray
const error_color = Screen.Color{ .indexed = 1 }; // red

width: u16,
height: u16,
border_grid: []BorderDir,
border_cells: []Screen.Cell,
border_colors: []Screen.Color,
allocator: Allocator,

pub fn init(allocator: Allocator, width: u16, height: u16) !Renderer {
    const size = @as(usize, width) * @as(usize, height);
    const border_grid = try allocator.alloc(BorderDir, size);
    @memset(border_grid, BorderDir{});
    const border_cells = try allocator.alloc(Screen.Cell, size);
    @memset(border_cells, Screen.Cell{});
    const border_colors = try allocator.alloc(Screen.Color, size);
    @memset(border_colors, Screen.Color.default);
    return .{
        .width = width,
        .height = height,
        .border_grid = border_grid,
        .border_cells = border_cells,
        .border_colors = border_colors,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Renderer) void {
    self.allocator.free(self.border_grid);
    self.allocator.free(self.border_cells);
    self.allocator.free(self.border_colors);
}

pub fn computeBorders(self: *Renderer, rects: []const Layout.Rect, active_pane: usize, command_mode: bool) void {
    self.computeBordersWithState(rects, active_pane, command_mode, null);
}

pub fn computeBordersWithState(self: *Renderer, rects: []const Layout.Rect, active_pane: usize, command_mode: bool, pane_states: ?[]const Pane.ProcessState) void {
    const active_border_color = if (command_mode) command_mode_color else active_color;
    const w: usize = self.width;
    const h: usize = self.height;

    // Reset
    @memset(self.border_grid, BorderDir{});
    @memset(self.border_cells, Screen.Cell{});
    @memset(self.border_colors, Screen.Color.default);

    // Pass 1: Mark gap cells with direction based on immediate pane neighbors
    for (0..h) |row| {
        for (0..w) |col| {
            if (cellCoveredByAny(rects, row, col)) continue;

            const idx = row * w + col;
            const has_pane_left = col > 0 and cellCoveredByAny(rects, row, col - 1);
            const has_pane_right = col + 1 < w and cellCoveredByAny(rects, row, col + 1);
            const has_pane_up = row > 0 and cellCoveredByAny(rects, row - 1, col);
            const has_pane_down = row + 1 < h and cellCoveredByAny(rects, row + 1, col);

            if (has_pane_left or has_pane_right) self.border_grid[idx].vertical = true;
            if (has_pane_up or has_pane_down) self.border_grid[idx].horizontal = true;
        }
    }

    // Pass 2: Propagate directions through gap cells that neighbor other borders
    // (handles junction cells like T-pieces and crosses)
    for (0..h) |row| {
        for (0..w) |col| {
            const idx = row * w + col;
            if (cellCoveredByAny(rects, row, col)) continue;

            // Inherit vertical from above/below border neighbors
            if (!self.border_grid[idx].vertical) {
                const has_v_up = row > 0 and self.border_grid[(row - 1) * w + col].vertical;
                const has_v_down = row + 1 < h and self.border_grid[(row + 1) * w + col].vertical;
                if (has_v_up or has_v_down) self.border_grid[idx].vertical = true;
            }
            // Inherit horizontal from left/right border neighbors
            if (!self.border_grid[idx].horizontal) {
                const has_h_left = col > 0 and self.border_grid[row * w + (col - 1)].horizontal;
                const has_h_right = col + 1 < w and self.border_grid[row * w + (col + 1)].horizontal;
                if (has_h_left or has_h_right) self.border_grid[idx].horizontal = true;
            }
        }
    }

    // Pass 3: Color assignment — active pane adjacent borders get highlight,
    // exited panes with non-zero exit code get red borders.
    for (0..h) |row| {
        for (0..w) |col| {
            const idx = row * w + col;
            if (!self.border_grid[idx].horizontal and !self.border_grid[idx].vertical) continue;

            var is_active_adjacent = false;
            var has_error_adjacent = false;
            for (rects, 0..) |r, pi| {
                const r_right: usize = @as(usize, r.col) + @as(usize, r.width);
                const r_bottom: usize = @as(usize, r.row) + @as(usize, r.height);
                const adjacent = (col == r_right and row >= r.row and row < r_bottom) or
                    (col + 1 == r.col and row >= r.row and row < r_bottom) or
                    (row == r_bottom and col >= r.col and col < r_right) or
                    (row + 1 == r.row and col >= r.col and col < r_right);
                if (adjacent) {
                    if (pi == active_pane) is_active_adjacent = true;
                    if (pane_states) |states| {
                        if (pi < states.len) {
                            switch (states[pi]) {
                                .exited => |code| if (code != 0) {
                                    has_error_adjacent = true;
                                },
                                .running => {},
                            }
                        }
                    }
                }
            }
            self.border_colors[idx] = if (has_error_adjacent)
                error_color
            else if (is_active_adjacent)
                active_border_color
            else
                inactive_color;
        }
    }

    self.resolveChars();
}

fn cellCoveredByAny(rects: []const Layout.Rect, row: usize, col: usize) bool {
    for (rects) |r| {
        if (col >= r.col and col < @as(usize, r.col) + @as(usize, r.width) and
            row >= r.row and row < @as(usize, r.row) + @as(usize, r.height))
        {
            return true;
        }
    }
    return false;
}

fn resolveChars(self: *Renderer) void {
    const w: usize = self.width;
    const h: usize = self.height;

    for (0..h) |row| {
        for (0..w) |col| {
            const idx = row * w + col;
            const dir = self.border_grid[idx];
            if (!dir.horizontal and !dir.vertical) continue;

            const has_up = row > 0 and self.border_grid[(row - 1) * w + col].vertical;
            const has_down = row + 1 < h and self.border_grid[(row + 1) * w + col].vertical;
            const has_left = col > 0 and self.border_grid[row * w + (col - 1)].horizontal;
            const has_right = col + 1 < w and self.border_grid[row * w + (col + 1)].horizontal;

            const char: u21 = if (dir.horizontal and dir.vertical) blk: {
                // Junction
                const u = has_up or (row > 0 and self.border_grid[(row - 1) * w + col].vertical);
                const d = has_down or (row + 1 < h and self.border_grid[(row + 1) * w + col].vertical);
                const l = has_left or (col > 0 and self.border_grid[row * w + (col - 1)].horizontal);
                const r = has_right or (col + 1 < w and self.border_grid[row * w + (col + 1)].horizontal);

                if (u and d and l and r) break :blk '┼'
                else if (u and d and r and !l) break :blk '├'
                else if (u and d and l and !r) break :blk '┤'
                else if (d and l and r and !u) break :blk '┬'
                else if (u and l and r and !d) break :blk '┴'
                else break :blk '┼';
            } else if (dir.vertical) '│'
            else '─';

            self.border_cells[idx] = .{
                .char = char,
                .fg = self.border_colors[idx],
                .bg = .default,
                .style = .{},
            };
        }
    }
}

pub fn formatExitStatus(buf: []u8, exit_code: u32) []const u8 {
    return std.fmt.bufPrint(buf, "[exit:{d}]", .{exit_code}) catch "";
}

pub fn borderCellAt(self: *const Renderer, row: u16, col: u16) *const Screen.Cell {
    return &self.border_cells[@as(usize, row) * @as(usize, self.width) + @as(usize, col)];
}

pub fn isBorder(self: *const Renderer, row: u16, col: u16) bool {
    const dir = self.border_grid[@as(usize, row) * @as(usize, self.width) + @as(usize, col)];
    return dir.horizontal or dir.vertical;
}

pub fn renderPane(self: *const Renderer, writer: anytype, screen: *const Screen, rect: Layout.Rect) !void {
    _ = self;
    var last_fg: Screen.Color = .default;
    var last_bg: Screen.Color = .default;
    var last_style: Screen.Style = .{};

    var row: u16 = 0;
    while (row < screen.height) : (row += 1) {
        // Position cursor at start of each row in the terminal
        try std.fmt.format(writer, "\x1b[{d};{d}H", .{
            @as(u32, rect.row) + @as(u32, row) + 1,
            @as(u32, rect.col) + 1,
        });

        var col: u16 = 0;
        while (col < screen.width) : (col += 1) {
            const cell = screen.cellAt(row, col);

            // Emit SGR only when attributes change
            if (!std.meta.eql(cell.fg, last_fg) or !std.meta.eql(cell.bg, last_bg) or
                !std.meta.eql(cell.style, last_style))
            {
                try writeSgr(writer, cell, &last_fg, &last_bg, &last_style);
            }

            // Write character as UTF-8
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
            try writer.writeAll(buf[0..len]);
        }
    }
    // Reset attributes after pane
    try writer.writeAll("\x1b[0m");
    last_fg = .default;
    last_bg = .default;
    last_style = .{};
}

const empty_cell = Screen.Cell{};

pub fn renderPaneWithOffset(self: *const Renderer, writer: anytype, screen: *const Screen, rect: Layout.Rect, scroll_offset: usize) !void {
    _ = self;
    var last_fg: Screen.Color = .default;
    var last_bg: Screen.Color = .default;
    var last_style: Screen.Style = .{};

    const sb_count = screen.scrollbackLen();

    var row: u16 = 0;
    while (row < screen.height) : (row += 1) {
        try std.fmt.format(writer, "\x1b[{d};{d}H", .{
            @as(u32, rect.row) + @as(u32, row) + 1,
            @as(u32, rect.col) + 1,
        });

        // Unified line model:
        // total_lines = sb_count + screen.height
        // For visual row R, the unified index is:
        //   (sb_count + screen.height) - scroll_offset - screen.height + row
        //   = sb_count - scroll_offset + row
        const unified: i64 = @as(i64, @intCast(sb_count)) - @as(i64, @intCast(scroll_offset)) + @as(i64, row);

        var col: u16 = 0;
        while (col < screen.width) : (col += 1) {
            const cell: *const Screen.Cell = blk: {
                if (unified < 0) {
                    break :blk &empty_cell;
                }
                const u_idx: usize = @intCast(unified);
                if (u_idx < sb_count) {
                    // Reading from scrollback
                    if (screen.scrollbackLine(u_idx)) |line| {
                        break :blk &line[col];
                    }
                    break :blk &empty_cell;
                } else {
                    // Reading from live screen
                    const screen_row: u16 = @intCast(u_idx - sb_count);
                    break :blk screen.cellAt(screen_row, col);
                }
            };

            if (!std.meta.eql(cell.fg, last_fg) or !std.meta.eql(cell.bg, last_bg) or
                !std.meta.eql(cell.style, last_style))
            {
                try writeSgr(writer, cell, &last_fg, &last_bg, &last_style);
            }

            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
            try writer.writeAll(buf[0..len]);
        }
    }

    // Scroll indicator overlay
    if (scroll_offset > 0) {
        var indicator_buf: [20]u8 = undefined;
        const indicator = std.fmt.bufPrint(&indicator_buf, "[{d}/{d}]", .{
            scroll_offset, sb_count,
        }) catch "";
        if (indicator.len > 0 and indicator.len <= screen.width) {
            const indicator_col = @as(u32, rect.col) + @as(u32, screen.width) - @as(u32, @intCast(indicator.len));
            try std.fmt.format(writer, "\x1b[{d};{d}H", .{
                @as(u32, rect.row) + 1,
                indicator_col + 1,
            });
            try writer.writeAll("\x1b[0;7m"); // inverse for visibility
            try writer.writeAll(indicator);
            last_fg = .default;
            last_bg = .default;
            last_style = .{};
        }
    }

    try writer.writeAll("\x1b[0m");
    last_fg = .default;
    last_bg = .default;
    last_style = .{};
}

pub fn renderBorders(self: *const Renderer, writer: anytype) !void {
    const w: usize = self.width;
    const h: usize = self.height;

    for (0..h) |row| {
        var run_start: ?usize = null;
        for (0..w) |col| {
            const idx = row * w + col;
            if (self.border_grid[idx].horizontal or self.border_grid[idx].vertical) {
                if (run_start == null) {
                    run_start = col;
                    // Position cursor
                    try std.fmt.format(writer, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
                    // Set color
                    const cell = &self.border_cells[idx];
                    try writeCellSgr(writer, cell);
                }
                const cell = &self.border_cells[idx];
                // If color changed from previous border cell, emit new SGR
                if (run_start != null and col > run_start.?) {
                    const prev_idx = row * w + col - 1;
                    if (!std.meta.eql(self.border_cells[prev_idx].fg, cell.fg)) {
                        try writeCellSgr(writer, cell);
                    }
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
                try writer.writeAll(buf[0..len]);
            } else {
                run_start = null;
            }
        }
    }
    try writer.writeAll("\x1b[0m");
}

pub fn renderExitStatuses(self: *const Renderer, writer: anytype, rects: []const Layout.Rect, pane_states: []const Pane.ProcessState) !void {
    _ = self;
    for (rects, 0..) |rect, pi| {
        if (pi >= pane_states.len) break;
        switch (pane_states[pi]) {
            .exited => |code| {
                var status_buf: [16]u8 = undefined;
                const status = formatExitStatus(&status_buf, code);
                if (status.len == 0) continue;
                // Place exit status at top-right corner of the pane
                const status_len: u16 = @intCast(status.len);
                if (status_len > rect.width) continue;
                const col = @as(u32, rect.col) + @as(u32, rect.width) - @as(u32, status_len);
                try std.fmt.format(writer, "\x1b[{d};{d}H", .{
                    @as(u32, rect.row) + 1,
                    col + 1,
                });
                // Use inverse + red for non-zero, inverse + green for zero
                if (code != 0) {
                    try writer.writeAll("\x1b[0;31;7m"); // red inverse
                } else {
                    try writer.writeAll("\x1b[0;32;7m"); // green inverse
                }
                try writer.writeAll(status);
                try writer.writeAll("\x1b[0m");
            },
            .running => {},
        }
    }
}

pub fn renderFrame(
    self: *const Renderer,
    writer: anytype,
    screens: []const *const Screen,
    rects: []const Layout.Rect,
    active_pane: usize,
) !void {
    // Hide cursor
    try writer.writeAll("\x1b[?25l");

    // Render all panes
    for (screens, rects) |screen, rect| {
        try self.renderPane(writer, screen, rect);
    }

    // Render borders
    try self.renderBorders(writer);

    // Position cursor at active pane's cursor
    if (active_pane < screens.len) {
        const screen = screens[active_pane];
        const rect = rects[active_pane];
        try std.fmt.format(writer, "\x1b[{d};{d}H", .{
            @as(u32, rect.row) + @as(u32, screen.cursor_row) + 1,
            @as(u32, rect.col) + @as(u32, screen.cursor_col) + 1,
        });
        // Show cursor if active pane has it visible
        if (screen.cursor_visible) {
            try writer.writeAll("\x1b[?25h");
        }
    }
}

pub fn renderFrameWithScrollback(
    self: *const Renderer,
    writer: anytype,
    screens: []const *const Screen,
    rects: []const Layout.Rect,
    scroll_offsets: []const usize,
    active_pane: usize,
) !void {
    try writer.writeAll("\x1b[?25l");

    for (screens, rects, scroll_offsets) |screen, rect, offset| {
        try self.renderPaneWithOffset(writer, screen, rect, offset);
    }

    try self.renderBorders(writer);

    // Show cursor only if active pane is at bottom (offset=0)
    if (active_pane < screens.len) {
        const screen = screens[active_pane];
        const rect = rects[active_pane];
        const offset = scroll_offsets[active_pane];
        if (offset == 0) {
            try std.fmt.format(writer, "\x1b[{d};{d}H", .{
                @as(u32, rect.row) + @as(u32, screen.cursor_row) + 1,
                @as(u32, rect.col) + @as(u32, screen.cursor_col) + 1,
            });
            if (screen.cursor_visible) {
                try writer.writeAll("\x1b[?25h");
            }
        }
    }
}

fn writeSgr(
    writer: anytype,
    cell: *const Screen.Cell,
    last_fg: *Screen.Color,
    last_bg: *Screen.Color,
    last_style: *Screen.Style,
) !void {
    // Reset first, then set new attributes
    try writer.writeAll("\x1b[0m");
    last_style.* = .{};
    last_fg.* = .default;
    last_bg.* = .default;

    // Style attributes
    if (cell.style.bold) try writer.writeAll("\x1b[1m");
    if (cell.style.dim) try writer.writeAll("\x1b[2m");
    if (cell.style.italic) try writer.writeAll("\x1b[3m");
    if (cell.style.underline) try writer.writeAll("\x1b[4m");
    if (cell.style.blink) try writer.writeAll("\x1b[5m");
    if (cell.style.inverse) try writer.writeAll("\x1b[7m");
    if (cell.style.hidden) try writer.writeAll("\x1b[8m");
    if (cell.style.strikethrough) try writer.writeAll("\x1b[9m");

    // Foreground
    switch (cell.fg) {
        .default => {},
        .indexed => |idx| {
            if (idx < 8) {
                try std.fmt.format(writer, "\x1b[{d}m", .{@as(u16, idx) + 30});
            } else if (idx < 16) {
                try std.fmt.format(writer, "\x1b[{d}m", .{@as(u16, idx) - 8 + 90});
            } else {
                try std.fmt.format(writer, "\x1b[38;5;{d}m", .{idx});
            }
        },
        .rgb => |c| {
            try std.fmt.format(writer, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
    }

    // Background
    switch (cell.bg) {
        .default => {},
        .indexed => |idx| {
            if (idx < 8) {
                try std.fmt.format(writer, "\x1b[{d}m", .{@as(u16, idx) + 40});
            } else if (idx < 16) {
                try std.fmt.format(writer, "\x1b[{d}m", .{@as(u16, idx) - 8 + 100});
            } else {
                try std.fmt.format(writer, "\x1b[48;5;{d}m", .{idx});
            }
        },
        .rgb => |c| {
            try std.fmt.format(writer, "\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
    }

    last_fg.* = cell.fg;
    last_bg.* = cell.bg;
    last_style.* = cell.style;
}

fn writeCellSgr(writer: anytype, cell: *const Screen.Cell) !void {
    try writer.writeAll("\x1b[0m");
    switch (cell.fg) {
        .default => {},
        .indexed => |idx| {
            if (idx < 8) {
                try std.fmt.format(writer, "\x1b[{d}m", .{@as(u16, idx) + 30});
            } else if (idx < 16) {
                try std.fmt.format(writer, "\x1b[{d}m", .{@as(u16, idx) - 8 + 90});
            } else {
                try std.fmt.format(writer, "\x1b[38;5;{d}m", .{idx});
            }
        },
        .rgb => |c| {
            try std.fmt.format(writer, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
    }
}

// --- Tests ---

test "horizontal 2-pane split produces vertical border" {
    const rects = &[_]Layout.Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 81, 24);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(0, 40).char);
    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(23, 40).char);
    try std.testing.expect(!renderer.isBorder(0, 0));
    try std.testing.expect(!renderer.isBorder(0, 41));
}

test "vertical 2-pane split produces horizontal border" {
    const rects = &[_]Layout.Rect{
        .{ .col = 0, .row = 0, .width = 80, .height = 12 },
        .{ .col = 0, .row = 13, .width = 80, .height = 12 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 80, 25);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    try std.testing.expectEqual(@as(u21, '─'), renderer.borderCellAt(12, 0).char);
    try std.testing.expectEqual(@as(u21, '─'), renderer.borderCellAt(12, 79).char);
    try std.testing.expect(!renderer.isBorder(0, 0));
}

test "active pane border has highlight color" {
    const rects = &[_]Layout.Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 81, 24);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);
    const border = renderer.borderCellAt(0, 40);

    try std.testing.expectEqual(Screen.Color{ .indexed = 2 }, border.fg);
}

test "inactive border has dim color" {
    // 3-pane layout: left | top-right / bottom-right
    // Active pane = 0 (left). Border between top-right and bottom-right
    // is NOT adjacent to the active pane → should be dim.
    const rects = &[_]Layout.Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 11 },
        .{ .col = 41, .row = 12, .width = 40, .height = 12 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 81, 24);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);
    // Horizontal border between pane 1 and pane 2 at row 11, col 50
    const border = renderer.borderCellAt(11, 50);

    try std.testing.expectEqual(Screen.Color{ .indexed = 8 }, border.fg);
}

test "cross junction where borders intersect" {
    const rects = &[_]Layout.Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 11 },
        .{ .col = 41, .row = 12, .width = 40, .height = 12 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 81, 24);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    // Vertical border at col 40
    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(0, 40).char);
    // Horizontal border at row 11
    try std.testing.expectEqual(@as(u21, '─'), renderer.borderCellAt(11, 42).char);
    // Junction at (11, 40)
    try std.testing.expectEqual(@as(u21, '├'), renderer.borderCellAt(11, 40).char);
}

// --- Compositing tests ---

test "render produces cursor-positioned output for pane content" {
    var screen = try Screen.init(std.testing.allocator, 3, 2);
    defer screen.deinit();
    var parser = @import("VtParser.zig").init(&screen);
    parser.feed("Hi!");

    const rect = Layout.Rect{ .col = 5, .row = 3, .width = 3, .height = 2 };
    var renderer = try Renderer.init(std.testing.allocator, 20, 10);
    defer renderer.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try renderer.renderPane(buf.writer(std.testing.allocator), &screen, rect);
    const output = buf.items;

    // Should contain cursor positioning to row 4 (1-based), col 6
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[4;6H") != null);
    // Should contain the characters
    try std.testing.expect(std.mem.indexOf(u8, output, "Hi!") != null);
}

test "render output includes SGR for colored cells" {
    var screen = try Screen.init(std.testing.allocator, 5, 1);
    defer screen.deinit();
    var parser = @import("VtParser.zig").init(&screen);
    parser.feed("\x1b[31mR\x1b[0mN");

    const rect = Layout.Rect{ .col = 0, .row = 0, .width = 5, .height = 1 };
    var renderer = try Renderer.init(std.testing.allocator, 5, 1);
    defer renderer.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try renderer.renderPane(buf.writer(std.testing.allocator), &screen, rect);
    const output = buf.items;

    // Should contain SGR for red foreground
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[31m") != null);
    // Should contain SGR reset
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
}

test "command mode changes active border to yellow" {
    const rects = &[_]Layout.Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 81, 24);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, true); // command_mode = true
    const border = renderer.borderCellAt(0, 40);

    // Command mode: active border should be yellow (indexed 3)
    try std.testing.expectEqual(Screen.Color{ .indexed = 3 }, border.fg);
}

test "full render hides cursor at start" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    var renderer = try Renderer.init(std.testing.allocator, 10, 5);
    defer renderer.deinit();

    const screens = &[_]*const Screen{};
    const rects = &[_]Layout.Rect{};

    try renderer.renderFrame(buf.writer(std.testing.allocator), screens, rects, 0);
    const output = buf.items;

    // Starts with hide cursor
    try std.testing.expect(std.mem.startsWith(u8, output, "\x1b[?25l"));
}

// --- Scrollback render tests ---

test "renderPaneWithOffset offset=0 matches renderPane output" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 3, 2, 10);
    defer screen.deinit();
    var parser = @import("VtParser.zig").init(&screen);
    parser.feed("Hi!");

    const rect = Layout.Rect{ .col = 0, .row = 0, .width = 3, .height = 2 };
    var renderer = try Renderer.init(std.testing.allocator, 10, 10);
    defer renderer.deinit();

    var buf1: std.ArrayListUnmanaged(u8) = .empty;
    defer buf1.deinit(std.testing.allocator);
    try renderer.renderPane(buf1.writer(std.testing.allocator), &screen, rect);

    var buf2: std.ArrayListUnmanaged(u8) = .empty;
    defer buf2.deinit(std.testing.allocator);
    try renderer.renderPaneWithOffset(buf2.writer(std.testing.allocator), &screen, rect, 0);

    try std.testing.expectEqualStrings(buf1.items, buf2.items);
}

test "renderPaneWithOffset shows scrollback lines when offset > 0" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 3, 2, 10);
    defer screen.deinit();

    // Write "AAA" on row 0, "BBB" on row 1
    for ("AAA") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    for ("BBB") |c| screen.writeChar(c);
    // Scroll up — "AAA" goes to scrollback, screen now: "BBB", blank
    screen.scrollUp(1);

    const rect = Layout.Rect{ .col = 0, .row = 0, .width = 3, .height = 2 };
    var renderer = try Renderer.init(std.testing.allocator, 10, 10);
    defer renderer.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try renderer.renderPaneWithOffset(buf.writer(std.testing.allocator), &screen, rect, 1);
    const output = buf.items;

    // With offset=1, row 0 should show scrollback line "AAA"
    try std.testing.expect(std.mem.indexOf(u8, output, "AAA") != null);
    // Row 1 should show screen row 0 which is "BBB"
    try std.testing.expect(std.mem.indexOf(u8, output, "BBB") != null);
}

test "scroll indicator shown when offset > 0" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 10, 2, 10);
    defer screen.deinit();

    for ("AAAAAAAAAA") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    for ("BBBBBBBBBB") |c| screen.writeChar(c);
    screen.scrollUp(1);

    const rect = Layout.Rect{ .col = 0, .row = 0, .width = 10, .height = 2 };
    var renderer = try Renderer.init(std.testing.allocator, 20, 10);
    defer renderer.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try renderer.renderPaneWithOffset(buf.writer(std.testing.allocator), &screen, rect, 1);
    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "[1/1]") != null);
}

test "no scroll indicator when offset = 0" {
    var screen = try Screen.initWithScrollback(std.testing.allocator, 10, 2, 10);
    defer screen.deinit();

    for ("AAAAAAAAAA") |c| screen.writeChar(c);
    screen.setCursorPos(1, 0);
    for ("BBBBBBBBBB") |c| screen.writeChar(c);
    screen.scrollUp(1);

    const rect = Layout.Rect{ .col = 0, .row = 0, .width = 10, .height = 2 };
    var renderer = try Renderer.init(std.testing.allocator, 20, 10);
    defer renderer.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try renderer.renderPaneWithOffset(buf.writer(std.testing.allocator), &screen, rect, 0);
    const output = buf.items;

    // Scroll indicator format is "[N/M]" — should not appear at offset=0
    try std.testing.expect(std.mem.indexOf(u8, output, "[0/") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[0;7m") == null);
}

test "formatExitStatus produces correct string" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("[exit:0]", Renderer.formatExitStatus(&buf, 0));
    try std.testing.expectEqualStrings("[exit:1]", Renderer.formatExitStatus(&buf, 1));
    try std.testing.expectEqualStrings("[exit:127]", Renderer.formatExitStatus(&buf, 127));
}

test "exited pane with exit code 0 gets green border" {
    const rects = &[_]Layout.Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    const pane_states = &[_]Pane.ProcessState{ .running, .{ .exited = 0 } };

    var renderer = try Renderer.init(std.testing.allocator, 81, 24);
    defer renderer.deinit();

    renderer.computeBordersWithState(rects, 0, false, pane_states);
    // Border at col 40 adjacent to pane 1 (exited 0): should be green (active color)
    const border = renderer.borderCellAt(0, 40);
    try std.testing.expectEqual(Screen.Color{ .indexed = 2 }, border.fg);
}

test "exited pane with non-zero exit code gets red border" {
    const rects = &[_]Layout.Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    const pane_states = &[_]Pane.ProcessState{ .running, .{ .exited = 1 } };

    var renderer = try Renderer.init(std.testing.allocator, 81, 24);
    defer renderer.deinit();

    renderer.computeBordersWithState(rects, 1, false, pane_states);
    // Border at col 40 adjacent to pane 1 (exited non-zero): should be red
    const border = renderer.borderCellAt(0, 40);
    try std.testing.expectEqual(Screen.Color{ .indexed = 1 }, border.fg);
}
