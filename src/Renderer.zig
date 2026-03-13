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
pane_adjacency: []u32,
allocator: Allocator,

pub fn init(allocator: Allocator, width: u16, height: u16) !Renderer {
    const size = @as(usize, width) * @as(usize, height);
    const border_grid = try allocator.alloc(BorderDir, size);
    @memset(border_grid, BorderDir{});
    const border_cells = try allocator.alloc(Screen.Cell, size);
    @memset(border_cells, Screen.Cell{});
    const border_colors = try allocator.alloc(Screen.Color, size);
    @memset(border_colors, Screen.Color.default);
    const pane_adjacency = try allocator.alloc(u32, size);
    @memset(pane_adjacency, 0);
    return .{
        .width = width,
        .height = height,
        .border_grid = border_grid,
        .border_cells = border_cells,
        .border_colors = border_colors,
        .pane_adjacency = pane_adjacency,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Renderer) void {
    self.allocator.free(self.border_grid);
    self.allocator.free(self.border_cells);
    self.allocator.free(self.border_colors);
    self.allocator.free(self.pane_adjacency);
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
    @memset(self.pane_adjacency, 0);

    // Per-pane border frame marking: each pane's border is drawn independently.
    // This prevents borders from connecting across gaps between panes.
    for (rects, 0..) |r, pi| {
        const mask: u32 = @as(u32, 1) << @intCast(pi);
        const r_right: usize = @as(usize, r.col) + @as(usize, r.width);
        const r_bottom: usize = @as(usize, r.row) + @as(usize, r.height);
        const col_start: usize = if (r.col > 0) @as(usize, r.col) - 1 else 0;
        const col_end: usize = @min(r_right, w - 1); // inclusive
        const row_start: usize = if (r.row > 0) @as(usize, r.row) - 1 else 0;
        const row_end: usize = @min(r_bottom, h - 1); // inclusive

        // Top border
        if (r.row > 0) {
            const top: usize = @as(usize, r.row) - 1;
            for (col_start..col_end + 1) |c| {
                if (!cellCoveredByAny(rects, top, c)) {
                    const idx = top * w + c;
                    self.border_grid[idx].horizontal = true;
                    self.pane_adjacency[idx] |= mask;
                }
            }
        }

        // Bottom border
        if (r_bottom < h) {
            for (col_start..col_end + 1) |c| {
                if (!cellCoveredByAny(rects, r_bottom, c)) {
                    const idx = r_bottom * w + c;
                    self.border_grid[idx].horizontal = true;
                    self.pane_adjacency[idx] |= mask;
                }
            }
        }

        // Left border
        if (r.col > 0) {
            const left: usize = @as(usize, r.col) - 1;
            for (row_start..row_end + 1) |rv| {
                if (!cellCoveredByAny(rects, rv, left)) {
                    const idx = rv * w + left;
                    self.border_grid[idx].vertical = true;
                    self.pane_adjacency[idx] |= mask;
                }
            }
        }

        // Right border
        if (r_right < w) {
            for (row_start..row_end + 1) |rv| {
                if (!cellCoveredByAny(rects, rv, r_right)) {
                    const idx = rv * w + r_right;
                    self.border_grid[idx].vertical = true;
                    self.pane_adjacency[idx] |= mask;
                }
            }
        }
    }

    // Color assignment — use pane_adjacency to determine colors.
    for (0..h) |row| {
        for (0..w) |col| {
            const idx = row * w + col;
            if (!self.border_grid[idx].horizontal and !self.border_grid[idx].vertical) continue;

            const adj_mask = self.pane_adjacency[idx];
            var is_active_adjacent = false;
            var has_error_adjacent = false;

            for (0..rects.len) |pi| {
                if (adj_mask & (@as(u32, 1) << @intCast(pi)) == 0) continue;
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

            const my_panes = self.pane_adjacency[idx];

            // A neighbor connects only if it is a border AND shares at
            // least one pane with this cell. This prevents borders of
            // different panes from merging when they are adjacent
            // (e.g. pane_gap = 1 → divider_width = 2).
            const has_up = row > 0 and self.border_grid[(row - 1) * w + col].vertical and
                (self.pane_adjacency[(row - 1) * w + col] & my_panes) != 0;
            const has_down = row + 1 < h and self.border_grid[(row + 1) * w + col].vertical and
                (self.pane_adjacency[(row + 1) * w + col] & my_panes) != 0;
            const has_left = col > 0 and self.border_grid[row * w + (col - 1)].horizontal and
                (self.pane_adjacency[row * w + (col - 1)] & my_panes) != 0;
            const has_right = col + 1 < w and self.border_grid[row * w + (col + 1)].horizontal and
                (self.pane_adjacency[row * w + (col + 1)] & my_panes) != 0;

            const char: u21 = if (dir.horizontal and dir.vertical) blk: {
                // Junction — use the same pane-aware neighbor checks.
                const u = has_up;
                const d = has_down;
                const l = has_left;
                const r = has_right;

                if (u and d and l and r) break :blk '┼'
                else if (u and d and r and !l) break :blk '├'
                else if (u and d and l and !r) break :blk '┤'
                else if (d and l and r and !u) break :blk '┬'
                else if (u and l and r and !d) break :blk '┴'
                else if (d and r and !u and !l) break :blk '┌'
                else if (d and l and !u and !r) break :blk '┐'
                else if (u and r and !d and !l) break :blk '└'
                else if (u and l and !d and !r) break :blk '┘'
                else if (u and d and !l and !r) break :blk '│'
                else if (l and r and !u and !d) break :blk '─'
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

            // Skip continuation cells (right half of wide characters).
            // The wide character already consumed 2 terminal columns.
            if (cell.char == 0) continue;

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

            // Skip continuation cells (right half of wide characters).
            if (cell.char == 0) continue;

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

pub fn renderPaneNames(self: *Renderer, rects: []const Layout.Rect, names: []const []const u8) void {
    const w: usize = self.width;

    for (rects, 0..) |r, i| {
        if (i >= names.len) break;
        const name = names[i];
        if (name.len == 0) continue;

        // Name goes on the top border row, just after the top-left corner.
        // Format: " name " (padded with spaces)
        const top_row: usize = if (r.row > 0) r.row - 1 else 0;
        const start_col: usize = r.col; // col after the corner character

        // Total width needed: space + name + space
        const label_len = name.len + 2;
        // Available border width (excluding corners)
        const border_width: usize = @as(usize, r.width);
        if (label_len > border_width) continue;

        // Write " name " starting at start_col
        var col = start_col;
        const idx = top_row * w + col;
        if (idx < self.border_cells.len) {
            const color = self.border_colors[idx];
            // Space before name
            self.border_cells[idx] = .{
                .char = ' ',
                .fg = color,
                .bg = .default,
                .style = .{},
            };
            col += 1;
            // Name characters
            for (name) |c| {
                const cidx = top_row * w + col;
                if (cidx >= self.border_cells.len) break;
                self.border_cells[cidx] = .{
                    .char = @as(u21, c),
                    .fg = color,
                    .bg = .default,
                    .style = .{},
                };
                col += 1;
            }
            // Space after name
            const eidx = top_row * w + col;
            if (eidx < self.border_cells.len) {
                self.border_cells[eidx] = .{
                    .char = ' ',
                    .fg = self.border_colors[eidx],
                    .bg = .default,
                    .style = .{},
                };
            }
        }
    }
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
    // Begin synchronized update — the terminal buffers all output and
    // applies it atomically, eliminating flicker.  Terminals that do
    // not support mode 2026 simply ignore the sequence.
    try writer.writeAll("\x1b[?2026h\x1b[?25l");

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

    // End synchronized update — terminal renders the frame now.
    try writer.writeAll("\x1b[?2026l");
}

pub fn renderFrameWithScrollback(
    self: *const Renderer,
    writer: anytype,
    screens: []const *const Screen,
    rects: []const Layout.Rect,
    scroll_offsets: []const usize,
    active_pane: usize,
) !void {
    // Begin synchronized update — prevents flicker by buffering in the terminal.
    try writer.writeAll("\x1b[?2026h\x1b[?25l");

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

    // End synchronized update — terminal renders the frame now.
    try writer.writeAll("\x1b[?2026l");
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

    // Starts with synchronized update + hide cursor
    try std.testing.expect(std.mem.startsWith(u8, output, "\x1b[?2026h\x1b[?25l"));
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

test "outer frame corners for single pane inside border" {
    // Single pane at (1,1) with width=8, height=3 inside a 10x5 renderer.
    // Outer border cells should form a rectangular frame.
    const rects = &[_]Layout.Rect{
        .{ .col = 1, .row = 1, .width = 8, .height = 3 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 10, 5);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    // Corners
    try std.testing.expectEqual(@as(u21, '┌'), renderer.borderCellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, '┐'), renderer.borderCellAt(0, 9).char);
    try std.testing.expectEqual(@as(u21, '└'), renderer.borderCellAt(4, 0).char);
    try std.testing.expectEqual(@as(u21, '┘'), renderer.borderCellAt(4, 9).char);
    // Top/bottom edges
    try std.testing.expectEqual(@as(u21, '─'), renderer.borderCellAt(0, 5).char);
    try std.testing.expectEqual(@as(u21, '─'), renderer.borderCellAt(4, 5).char);
    // Left/right edges
    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(2, 0).char);
    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(2, 9).char);
}

test "outer frame with 2-pane horizontal split has T-junctions" {
    // 2 panes side by side inside outer border: 12w x 5h renderer
    // pane0: (1,1, 4, 3), pane1: (6,1, 5, 3), divider at col 5
    const rects = &[_]Layout.Rect{
        .{ .col = 1, .row = 1, .width = 4, .height = 3 },
        .{ .col = 6, .row = 1, .width = 5, .height = 3 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 12, 5);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    // Top junction at (0, 5) where divider meets top border
    try std.testing.expectEqual(@as(u21, '┬'), renderer.borderCellAt(0, 5).char);
    // Bottom junction at (4, 5) where divider meets bottom border
    try std.testing.expectEqual(@as(u21, '┴'), renderer.borderCellAt(4, 5).char);
    // Divider between panes
    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(2, 5).char);
    // Corners still correct
    try std.testing.expectEqual(@as(u21, '┌'), renderer.borderCellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, '┐'), renderer.borderCellAt(0, 11).char);
    try std.testing.expectEqual(@as(u21, '└'), renderer.borderCellAt(4, 0).char);
    try std.testing.expectEqual(@as(u21, '┘'), renderer.borderCellAt(4, 11).char);
}

test "outer border color matches adjacent active pane" {
    // Single pane at (1,1) with width=8, height=3 inside 10x5.
    // Active pane = 0. Outer border cells should be active color (green).
    const rects = &[_]Layout.Rect{
        .{ .col = 1, .row = 1, .width = 8, .height = 3 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 10, 5);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    // Top-left corner should have active color
    try std.testing.expectEqual(active_color, renderer.borderCellAt(0, 0).fg);
    // Top edge
    try std.testing.expectEqual(active_color, renderer.borderCellAt(0, 5).fg);
    // Left edge
    try std.testing.expectEqual(active_color, renderer.borderCellAt(2, 0).fg);
}

test "renderPaneNames writes name on top border" {
    // Pane at (1,1, 10, 5) inside 12x7 renderer. Name = "editor"
    const rects = &[_]Layout.Rect{
        .{ .col = 1, .row = 1, .width = 10, .height = 5 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 12, 7);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    const names: []const []const u8 = &.{"editor"};
    renderer.renderPaneNames(rects, names);

    // " editor " should appear starting at col 1 of row 0 (after ┌)
    // Check that the cells contain the name characters
    try std.testing.expectEqual(@as(u21, ' '), renderer.borderCellAt(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'e'), renderer.borderCellAt(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'd'), renderer.borderCellAt(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'i'), renderer.borderCellAt(0, 4).char);
    try std.testing.expectEqual(@as(u21, 't'), renderer.borderCellAt(0, 5).char);
    try std.testing.expectEqual(@as(u21, 'o'), renderer.borderCellAt(0, 6).char);
    try std.testing.expectEqual(@as(u21, 'r'), renderer.borderCellAt(0, 7).char);
    try std.testing.expectEqual(@as(u21, ' '), renderer.borderCellAt(0, 8).char);
    // Corner should be preserved
    try std.testing.expectEqual(@as(u21, '┌'), renderer.borderCellAt(0, 0).char);
}

test "renderPaneNames skips empty names" {
    const rects = &[_]Layout.Rect{
        .{ .col = 1, .row = 1, .width = 10, .height = 5 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 12, 7);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    const names: []const []const u8 = &.{""};
    renderer.renderPaneNames(rects, names);

    // Top edge should remain '─' (unchanged)
    try std.testing.expectEqual(@as(u21, '─'), renderer.borderCellAt(0, 5).char);
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

test "gap=1 horizontal 2-pane produces separate rectangles" {
    // With gap=1, divider_width = 2: adjacent separate borders (no gap cell)
    // pane0: (1,1,4,3), pane1: (7,1,5,3), renderer: 13x5
    // divider zone: cols 5 (pane0 right border), 6 (pane1 left border)
    const rects = &[_]Layout.Rect{
        .{ .col = 1, .row = 1, .width = 4, .height = 3 },
        .{ .col = 7, .row = 1, .width = 5, .height = 3 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 13, 5);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    // pane0's top-right corner at (0,5) should be ┐ (not ┬)
    try std.testing.expectEqual(@as(u21, '┐'), renderer.borderCellAt(0, 5).char);
    // pane1's top-left corner at (0,6) should be ┌ (not ┬)
    try std.testing.expectEqual(@as(u21, '┌'), renderer.borderCellAt(0, 6).char);
    // pane0's bottom-right corner at (4,5) should be ┘
    try std.testing.expectEqual(@as(u21, '┘'), renderer.borderCellAt(4, 5).char);
    // pane1's bottom-left corner at (4,6) should be └
    try std.testing.expectEqual(@as(u21, '└'), renderer.borderCellAt(4, 6).char);
    // pane0's right edge at (2,5) should be │
    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(2, 5).char);
    // pane1's left edge at (2,6) should be │
    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(2, 6).char);
}

test "gap=0 still produces shared borders with T-junctions" {
    // Regression: gap=0 should work the same as before
    const rects = &[_]Layout.Rect{
        .{ .col = 1, .row = 1, .width = 4, .height = 3 },
        .{ .col = 6, .row = 1, .width = 5, .height = 3 },
    };

    var renderer = try Renderer.init(std.testing.allocator, 12, 5);
    defer renderer.deinit();

    renderer.computeBorders(rects, 0, false);

    // Shared border at col 5
    try std.testing.expectEqual(@as(u21, '┬'), renderer.borderCellAt(0, 5).char);
    try std.testing.expectEqual(@as(u21, '┴'), renderer.borderCellAt(4, 5).char);
    try std.testing.expectEqual(@as(u21, '│'), renderer.borderCellAt(2, 5).char);
}
