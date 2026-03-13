const std = @import("std");
const Config = @import("Config.zig");
const Allocator = std.mem.Allocator;

pub const Rect = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,
};

/// Compute layout rectangles for each leaf pane in depth-first order.
/// Caller owns the returned slice and must free it.
pub fn compute(allocator: Allocator, pane: Config.Pane, area: Rect, gap: u16) Allocator.Error![]Rect {
    switch (pane) {
        .leaf => {
            const rects = try allocator.alloc(Rect, 1);
            rects[0] = area;
            return rects;
        },
        .split => |split| {
            return computeSplit(allocator, split, area, gap);
        },
    }
}

fn childSize(child: Config.Pane) Config.SizeMode {
    return switch (child) {
        .leaf => |l| l.size,
        .split => |s| s.size,
    };
}

fn computeSplit(allocator: Allocator, split: Config.Pane.Split, area: Rect, gap: u16) Allocator.Error![]Rect {
    const n: u16 = @intCast(split.children.len);
    const borders: u16 = n - 1;
    // gap=0: shared border (1 cell). gap=1: adjacent separate borders (2 cells). etc.
    const divider_width: u16 = 1 + gap;
    const is_horizontal = split.direction == .horizontal;

    const total = if (is_horizontal) area.width else area.height;
    const available = total -| (borders * divider_width);

    // Pass 1: resolve fixed/percent sizes, count equal children.
    var claimed: u16 = 0;
    var equal_count: u16 = 0;
    for (split.children) |child| {
        switch (childSize(child)) {
            .fixed => |f| claimed += @min(f, available),
            .percent => |p| claimed += available * p / 100,
            .equal => equal_count += 1,
        }
    }

    // Pass 2: distribute remaining space among equal children.
    const remaining = available -| claimed;
    const equal_base = if (equal_count > 0) remaining / equal_count else 0;
    const equal_rem = if (equal_count > 0) remaining % equal_count else 0;

    var result = std.array_list.AlignedManaged(Rect, null).init(allocator);
    defer result.deinit();

    var offset: u16 = if (is_horizontal) area.col else area.row;
    var equal_idx: u16 = 0;

    for (split.children) |child| {
        const child_size: u16 = switch (childSize(child)) {
            .fixed => |f| @min(f, available),
            .percent => |p| available * p / 100,
            .equal => blk: {
                const extra: u16 = if (equal_idx >= equal_count - equal_rem) 1 else 0;
                equal_idx += 1;
                break :blk equal_base + extra;
            },
        };

        const child_area = if (is_horizontal)
            Rect{ .col = offset, .row = area.row, .width = child_size, .height = area.height }
        else
            Rect{ .col = area.col, .row = offset, .width = area.width, .height = child_size };

        const child_rects = try compute(allocator, child, child_area, gap);
        defer allocator.free(child_rects);

        try result.appendSlice(child_rects);

        offset += child_size + divider_width;
    }

    return result.toOwnedSlice();
}

pub const Direction = enum { up, down, left, right };

/// Find the neighboring pane in the given direction.
/// Returns the index of the closest pane that is strictly in that direction
/// and overlaps on the perpendicular axis, or null if none exists.
pub fn findNeighbor(rects: []const Rect, current: usize, dir: Direction) ?usize {
    const cur = rects[current];
    const cur_center_row: i32 = @as(i32, cur.row) + @divTrunc(@as(i32, cur.height), 2);
    const cur_center_col: i32 = @as(i32, cur.col) + @divTrunc(@as(i32, cur.width), 2);

    var best: ?usize = null;
    var best_dist: i32 = std.math.maxInt(i32);

    for (rects, 0..) |r, i| {
        if (i == current) continue;

        const r_center_row: i32 = @as(i32, r.row) + @divTrunc(@as(i32, r.height), 2);
        const r_center_col: i32 = @as(i32, r.col) + @divTrunc(@as(i32, r.width), 2);

        // Check the candidate is strictly in the requested direction
        // and overlaps on the perpendicular axis.
        const valid = switch (dir) {
            .right => @as(i32, r.col) >= @as(i32, cur.col) + @as(i32, cur.width) and
                overlapsVertically(cur, r),
            .left => @as(i32, cur.col) >= @as(i32, r.col) + @as(i32, r.width) and
                overlapsVertically(cur, r),
            .down => @as(i32, r.row) >= @as(i32, cur.row) + @as(i32, cur.height) and
                overlapsHorizontally(cur, r),
            .up => @as(i32, cur.row) >= @as(i32, r.row) + @as(i32, r.height) and
                overlapsHorizontally(cur, r),
        };
        if (!valid) continue;

        // Distance: primary axis gap + perpendicular center offset
        const dist: i32 = switch (dir) {
            .right, .left => @as(i32, @intCast(@abs(r_center_col - cur_center_col))) +
                @as(i32, @intCast(@abs(r_center_row - cur_center_row))),
            .up, .down => @as(i32, @intCast(@abs(r_center_row - cur_center_row))) +
                @as(i32, @intCast(@abs(r_center_col - cur_center_col))),
        };

        if (dist < best_dist) {
            best_dist = dist;
            best = i;
        }
    }
    return best;
}

fn overlapsVertically(a: Rect, b: Rect) bool {
    return @as(i32, a.row) < @as(i32, b.row) + @as(i32, b.height) and
        @as(i32, b.row) < @as(i32, a.row) + @as(i32, a.height);
}

/// Find which pane contains the given (row, col) coordinate.
/// Returns the pane index, or null if the coordinate is on a border or outside all panes.
pub fn paneAt(rects: []const Rect, row: u16, col: u16) ?usize {
    for (rects, 0..) |r, i| {
        if (col >= r.col and col < @as(u16, r.col) + @as(u16, r.width) and
            row >= r.row and row < @as(u16, r.row) + @as(u16, r.height))
        {
            return i;
        }
    }
    return null;
}

pub const BorderInfo = struct {
    /// Index of the pane to the left (vertical) or above (horizontal) the border.
    pane_before: usize,
    /// Index of the pane to the right (vertical) or below (horizontal) the border.
    pane_after: usize,
    /// True for vertical border (between horizontally split panes).
    is_vertical: bool,
};

/// Find the border at the given (row, col) coordinate and identify the adjacent panes.
/// Returns null if the coordinate is inside a pane, outside all panes, or at a junction
/// where adjacent cells are also borders.
/// Scans outward from the coordinate to find panes across gap cells.
pub fn borderAt(rects: []const Rect, row: u16, col: u16) ?BorderInfo {
    // Not a border if it's inside a pane
    if (paneAt(rects, row, col) != null) return null;

    // Check for vertical border: scan left and right for panes
    const left = scanForPane(rects, row, col, .left);
    const right = scanForPane(rects, row, col, .right);
    if (left != null and right != null and left.? != right.?) {
        return .{ .pane_before = left.?, .pane_after = right.?, .is_vertical = true };
    }

    // Check for horizontal border: scan up and down for panes
    const above = scanForPane(rects, row, col, .up);
    const below = scanForPane(rects, row, col, .down);
    if (above != null and below != null and above.? != below.?) {
        return .{ .pane_before = above.?, .pane_after = below.?, .is_vertical = false };
    }

    return null;
}

/// Scan from (row, col) in the given direction until a pane is found or another
/// pane's perpendicular edge is crossed. Returns the pane index or null.
fn scanForPane(rects: []const Rect, row: u16, col: u16, dir: Direction) ?usize {
    var r = row;
    var c = col;
    // Limit scan to a reasonable distance (max gap should be small).
    var steps: u16 = 0;
    const max_steps: u16 = 64;
    while (steps < max_steps) {
        switch (dir) {
            .left => {
                if (c == 0) return null;
                c -= 1;
            },
            .right => {
                c += 1;
            },
            .up => {
                if (r == 0) return null;
                r -= 1;
            },
            .down => {
                r += 1;
            },
        }
        if (paneAt(rects, r, c)) |idx| return idx;
        steps += 1;
    }
    return null;
}

fn overlapsHorizontally(a: Rect, b: Rect) bool {
    return @as(i32, a.col) < @as(i32, b.col) + @as(i32, b.width) and
        @as(i32, b.col) < @as(i32, a.col) + @as(i32, a.width);
}

// --- Tests ---

test "single leaf pane fills entire area" {
    const pane = Config.Pane{ .leaf = .{ .command = &.{"bash"} } };
    const area = Rect{ .col = 0, .row = 0, .width = 80, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expectEqual(area, rects[0]);
}

test "horizontal split with 2 equal children" {
    // width=80: 1 border → 79 usable → child0=39, child1=40
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"vim"} } },
            Config.Pane{ .leaf = .{ .command = &.{"bash"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 80, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    // left pane
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 39, .height = 24 }, rects[0]);
    // right pane (after 1-cell border)
    try std.testing.expectEqual(Rect{ .col = 40, .row = 0, .width = 40, .height = 24 }, rects[1]);
}

test "vertical split with 2 equal children" {
    // height=24: 1 border → 23 usable → child0=11, child1=12
    const pane = Config.Pane{ .split = .{
        .direction = .vertical,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"top"} } },
            Config.Pane{ .leaf = .{ .command = &.{"bash"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 80, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    // top pane
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 80, .height = 11 }, rects[0]);
    // bottom pane (after 1-cell border)
    try std.testing.expectEqual(Rect{ .col = 0, .row = 12, .width = 80, .height = 12 }, rects[1]);
}

test "3 equal children with remainder distribution" {
    // width=81, 3 children: borders=2 → 79 usable → 79/3=26 rem=1
    // child0=26, child1=26, child2=27 (last gets remainder)
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"a"} } },
            Config.Pane{ .leaf = .{ .command = &.{"b"} } },
            Config.Pane{ .leaf = .{ .command = &.{"c"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 81, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 3), rects.len);
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 26, .height = 24 }, rects[0]);
    try std.testing.expectEqual(Rect{ .col = 27, .row = 0, .width = 26, .height = 24 }, rects[1]);
    try std.testing.expectEqual(Rect{ .col = 54, .row = 0, .width = 27, .height = 24 }, rects[2]);
}

test "percent-based sizing" {
    // width=101, 2 children: border=1 → 100 usable
    // child0: 60% of 100 = 60, child1: equal gets remainder = 40
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{
                .command = &.{"nvim"},
                .size = .{ .percent = 60 },
            } },
            Config.Pane{ .leaf = .{ .command = &.{"bash"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 101, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 60, .height = 24 }, rects[0]);
    try std.testing.expectEqual(Rect{ .col = 61, .row = 0, .width = 40, .height = 24 }, rects[1]);
}

test "fixed-size pane" {
    // width=101, 2 children: border=1 → 100 usable
    // child0: fixed=30, child1: equal gets remainder = 70
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{
                .command = &.{"sidebar"},
                .size = .{ .fixed = 30 },
            } },
            Config.Pane{ .leaf = .{ .command = &.{"main"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 101, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 30, .height = 24 }, rects[0]);
    try std.testing.expectEqual(Rect{ .col = 31, .row = 0, .width = 70, .height = 24 }, rects[1]);
}

test "nested splits" {
    // horizontal(81w) → left leaf(40w) | right vertical(40w, 24h)
    //   right vertical → top leaf(11h) | bottom leaf(12h)
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"nvim"} } },
            Config.Pane{ .split = .{
                .direction = .vertical,
                .children = &.{
                    Config.Pane{ .leaf = .{ .command = &.{ "npm", "run", "dev" } } },
                    Config.Pane{ .leaf = .{ .command = &.{"bash"} } },
                },
            } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 81, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 3), rects.len);
    // left: nvim
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 40, .height = 24 }, rects[0]);
    // top-right: npm run dev
    try std.testing.expectEqual(Rect{ .col = 41, .row = 0, .width = 40, .height = 11 }, rects[1]);
    // bottom-right: bash
    try std.testing.expectEqual(Rect{ .col = 41, .row = 12, .width = 40, .height = 12 }, rects[2]);
}

test "recalculate on resize produces different rectangles" {
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"vim"} } },
            Config.Pane{ .leaf = .{ .command = &.{"bash"} } },
        },
    } };

    // Original size
    const rects1 = try compute(std.testing.allocator, pane, .{ .col = 0, .row = 0, .width = 80, .height = 24 }, 0);
    defer std.testing.allocator.free(rects1);

    // After resize to 120x40
    const rects2 = try compute(std.testing.allocator, pane, .{ .col = 0, .row = 0, .width = 120, .height = 40 }, 0);
    defer std.testing.allocator.free(rects2);

    // Both produce 2 rects
    try std.testing.expectEqual(@as(usize, 2), rects1.len);
    try std.testing.expectEqual(@as(usize, 2), rects2.len);

    // Sizes differ after resize
    try std.testing.expect(rects1[0].width != rects2[0].width);
    try std.testing.expect(rects1[0].height != rects2[0].height);
}

test "non-zero origin area offset" {
    // Layout should respect the starting position of the area
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"a"} } },
            Config.Pane{ .leaf = .{ .command = &.{"b"} } },
        },
    } };
    const area = Rect{ .col = 10, .row = 5, .width = 81, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(Rect{ .col = 10, .row = 5, .width = 40, .height = 24 }, rects[0]);
    try std.testing.expectEqual(Rect{ .col = 51, .row = 5, .width = 40, .height = 24 }, rects[1]);
}

// --- findNeighbor tests ---

test "findNeighbor right in horizontal 2-pane" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    try std.testing.expectEqual(@as(?usize, 1), findNeighbor(rects, 0, .right));
}

test "findNeighbor left in horizontal 2-pane" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    try std.testing.expectEqual(@as(?usize, 0), findNeighbor(rects, 1, .left));
}

test "findNeighbor returns null when no neighbor" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    try std.testing.expectEqual(@as(?usize, null), findNeighbor(rects, 0, .left));
    try std.testing.expectEqual(@as(?usize, null), findNeighbor(rects, 1, .right));
    try std.testing.expectEqual(@as(?usize, null), findNeighbor(rects, 0, .up));
    try std.testing.expectEqual(@as(?usize, null), findNeighbor(rects, 0, .down));
}

test "findNeighbor down in vertical 2-pane" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 80, .height = 11 },
        .{ .col = 0, .row = 12, .width = 80, .height = 12 },
    };
    try std.testing.expectEqual(@as(?usize, 1), findNeighbor(rects, 0, .down));
    try std.testing.expectEqual(@as(?usize, 0), findNeighbor(rects, 1, .up));
}

test "findNeighbor in 3-pane L-shape layout" {
    // left | top-right / bottom-right
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 11 },
        .{ .col = 41, .row = 12, .width = 40, .height = 12 },
    };
    // From left pane, right → pane 2 is closer (center row 18 vs pane 1 center row 5,
    // pane 0 center is at row 12)
    try std.testing.expectEqual(@as(?usize, 2), findNeighbor(rects, 0, .right));
    // From top-right, left → pane 0
    try std.testing.expectEqual(@as(?usize, 0), findNeighbor(rects, 1, .left));
    // From top-right, down → pane 2
    try std.testing.expectEqual(@as(?usize, 2), findNeighbor(rects, 1, .down));
    // From bottom-right, up → pane 1
    try std.testing.expectEqual(@as(?usize, 1), findNeighbor(rects, 2, .up));
}

// --- paneAt tests ---

test "paneAt returns pane index for click inside pane 0" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    try std.testing.expectEqual(@as(?usize, 0), paneAt(rects, 10, 20));
}

test "paneAt returns pane index for click inside pane 1" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    try std.testing.expectEqual(@as(?usize, 1), paneAt(rects, 10, 50));
}

test "paneAt returns null for click on border" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    try std.testing.expectEqual(@as(?usize, null), paneAt(rects, 10, 40));
}

test "paneAt returns correct pane in 3-pane layout" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 11 },
        .{ .col = 41, .row = 12, .width = 40, .height = 12 },
    };
    // Click in bottom-right pane
    try std.testing.expectEqual(@as(?usize, 2), paneAt(rects, 15, 50));
    // Click in top-right pane
    try std.testing.expectEqual(@as(?usize, 1), paneAt(rects, 5, 50));
}

test "paneAt returns null for coordinates outside all panes" {
    const rects = &[_]Rect{
        .{ .col = 5, .row = 5, .width = 10, .height = 10 },
    };
    try std.testing.expectEqual(@as(?usize, null), paneAt(rects, 0, 0));
}

// --- borderAt tests ---

test "borderAt returns vertical border info between 2 horizontal panes" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    const info = borderAt(rects, 10, 40);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(usize, 0), info.?.pane_before);
    try std.testing.expectEqual(@as(usize, 1), info.?.pane_after);
    try std.testing.expect(info.?.is_vertical);
}

test "borderAt returns horizontal border info between 2 vertical panes" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 80, .height = 11 },
        .{ .col = 0, .row = 12, .width = 80, .height = 12 },
    };
    const info = borderAt(rects, 11, 40);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(usize, 0), info.?.pane_before);
    try std.testing.expectEqual(@as(usize, 1), info.?.pane_after);
    try std.testing.expect(!info.?.is_vertical);
}

test "borderAt returns null for coordinate inside a pane" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 24 },
    };
    try std.testing.expectEqual(@as(?BorderInfo, null), borderAt(rects, 10, 20));
}

test "borderAt returns null for junction cell in L-shape layout" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 11 },
        .{ .col = 41, .row = 12, .width = 40, .height = 12 },
    };
    // Junction at (11, 40) — adjacent cells on right are also on border
    try std.testing.expectEqual(@as(?BorderInfo, null), borderAt(rects, 11, 40));
}

test "borderAt works on horizontal border in L-shape layout" {
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 40, .height = 24 },
        .{ .col = 41, .row = 0, .width = 40, .height = 11 },
        .{ .col = 41, .row = 12, .width = 40, .height = 12 },
    };
    // Horizontal border between pane 1 and 2 at (11, 50)
    const info = borderAt(rects, 11, 50);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(usize, 1), info.?.pane_before);
    try std.testing.expectEqual(@as(usize, 2), info.?.pane_after);
    try std.testing.expect(!info.?.is_vertical);
}

test "horizontal split with gap=1" {
    // width=80, gap=1: divider_width = 1+1 = 2, borders=1
    // usable = 80 - 2 = 78 → child0=39, child1=39
    // child0 starts at col 0, child1 starts at col 0+39+2 = 41
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"vim"} } },
            Config.Pane{ .leaf = .{ .command = &.{"bash"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 80, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 1);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 39, .height = 24 }, rects[0]);
    try std.testing.expectEqual(Rect{ .col = 41, .row = 0, .width = 39, .height = 24 }, rects[1]);
}

test "horizontal split with gap=0 matches legacy behavior" {
    // width=80, gap=0: divider_width = 1+0 = 1, borders=1
    // usable = 80 - 1 = 79 → child0=39, child1=40
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"vim"} } },
            Config.Pane{ .leaf = .{ .command = &.{"bash"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 80, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 39, .height = 24 }, rects[0]);
    try std.testing.expectEqual(Rect{ .col = 40, .row = 0, .width = 40, .height = 24 }, rects[1]);
}

test "vertical split with gap=2" {
    // height=24, gap=2: divider_width = 1+2 = 3, borders=1
    // usable = 24 - 3 = 21 → child0=10, child1=11
    // child1 starts at row 0+10+3 = 13
    const pane = Config.Pane{ .split = .{
        .direction = .vertical,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"top"} } },
            Config.Pane{ .leaf = .{ .command = &.{"bash"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 80, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 2);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(Rect{ .col = 0, .row = 0, .width = 80, .height = 10 }, rects[0]);
    try std.testing.expectEqual(Rect{ .col = 0, .row = 13, .width = 80, .height = 11 }, rects[1]);
}

test "borderAt with gap=1 returns info on all divider cells" {
    // gap=1: divider_width=2. pane0 {col=0,w=39}, pane1 {col=41,w=39}
    // divider zone: cols 39, 40 (pane0 border, pane1 border)
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 39, .height = 24 },
        .{ .col = 41, .row = 0, .width = 39, .height = 24 },
    };
    // Both cells in the divider zone should return border info
    for (39..41) |c| {
        const info = borderAt(rects, 10, @intCast(c));
        try std.testing.expect(info != null);
        try std.testing.expectEqual(@as(usize, 0), info.?.pane_before);
        try std.testing.expectEqual(@as(usize, 1), info.?.pane_after);
        try std.testing.expect(info.?.is_vertical);
    }
}

test "borderAt with gap=2 returns info on all divider cells" {
    // gap=2: divider_width=3. pane0 {col=0,w=10}, pane1 {col=13,w=10}
    // divider zone: cols 10, 11, 12
    const rects = &[_]Rect{
        .{ .col = 0, .row = 0, .width = 10, .height = 24 },
        .{ .col = 13, .row = 0, .width = 10, .height = 24 },
    };
    for (10..13) |c| {
        const info = borderAt(rects, 10, @intCast(c));
        try std.testing.expect(info != null);
        try std.testing.expectEqual(@as(usize, 0), info.?.pane_before);
        try std.testing.expectEqual(@as(usize, 1), info.?.pane_after);
    }
}

test "mixed percent, fixed, and equal sizing" {
    // width=101: border=2 → 99 usable
    // child0: fixed=20, child1: percent=50 → 49, child2: equal → 99-20-49=30
    const pane = Config.Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Config.Pane{ .leaf = .{ .command = &.{"sidebar"}, .size = .{ .fixed = 20 } } },
            Config.Pane{ .leaf = .{ .command = &.{"editor"}, .size = .{ .percent = 50 } } },
            Config.Pane{ .leaf = .{ .command = &.{"terminal"} } },
        },
    } };
    const area = Rect{ .col = 0, .row = 0, .width = 101, .height = 24 };

    const rects = try compute(std.testing.allocator, pane, area, 0);
    defer std.testing.allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 3), rects.len);
    // fixed=20
    try std.testing.expectEqual(@as(u16, 20), rects[0].width);
    // percent=50 of 99 = 49
    try std.testing.expectEqual(@as(u16, 49), rects[1].width);
    // equal gets remainder = 99 - 20 - 49 = 30
    try std.testing.expectEqual(@as(u16, 30), rects[2].width);
}
