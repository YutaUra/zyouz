# Text Selection & Copy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable click-and-drag text selection in non-passthrough panes with automatic clipboard copy via OSC 52.

**Architecture:** Selection state is tracked in the event loop as a local variable. Mouse press records an anchor, drag creates/updates the selection range using unified line indices (covering both scrollback and live screen). The Renderer applies inverse video to selected cells non-destructively. On release, selected text is extracted, base64-encoded, and sent to the host terminal via OSC 52. Auto-scroll triggers when dragging past pane edges.

**Tech Stack:** Zig 0.15, OSC 52 clipboard protocol, SGR inverse rendering

---

## Data Design

### Selection State

```zig
const SelectionAnchor = struct {
    pane: usize,
    unified_row: i64,  // scrollback-aware row index
    col: u16,
};

const Selection = struct {
    pane: usize,
    start_row: i64,
    start_col: u16,
    end_row: i64,
    end_col: u16,

    /// Normalize so start <= end for iteration.
    fn normalized(self: Selection) Selection { ... }

    /// Check if a cell at (unified_row, col) is within the selection.
    fn contains(self: Selection, unified_row: i64, col: u16) bool { ... }
};
```

Located in `event_loop.zig` as `runMultiPane` local variables:
```zig
var selection_anchor: ?SelectionAnchor = null;
var selection: ?Selection = null;
```

### Unified Line Index

Same coordinate system as `renderPaneWithOffset`:
```
unified_row = scrollback_count - scroll_offset + screen_row
```

---

### Task 1: Selection data types and contains logic

**Files:**
- Modify: `src/event_loop.zig`

**Step 1: Write failing test — Selection.contains**

```zig
test "Selection.contains single line" {
    const sel = Selection{
        .pane = 0,
        .start_row = 5,
        .start_col = 3,
        .end_row = 5,
        .end_col = 8,
    };
    const n = sel.normalized();
    try std.testing.expect(n.contains(5, 3));
    try std.testing.expect(n.contains(5, 5));
    try std.testing.expect(n.contains(5, 8));
    try std.testing.expect(!n.contains(5, 2));
    try std.testing.expect(!n.contains(5, 9));
    try std.testing.expect(!n.contains(4, 5));
}

test "Selection.contains multi line" {
    const sel = Selection{
        .pane = 0,
        .start_row = 10,
        .start_col = 5,
        .end_row = 12,
        .end_col = 3,
    };
    const n = sel.normalized();
    // First line: col 5 onwards
    try std.testing.expect(n.contains(10, 5));
    try std.testing.expect(n.contains(10, 40));
    try std.testing.expect(!n.contains(10, 4));
    // Middle line: entire line
    try std.testing.expect(n.contains(11, 0));
    try std.testing.expect(n.contains(11, 999));
    // Last line: up to col 3
    try std.testing.expect(n.contains(12, 0));
    try std.testing.expect(n.contains(12, 3));
    try std.testing.expect(!n.contains(12, 4));
}

test "Selection.normalized reverses when end before start" {
    const sel = Selection{
        .pane = 0,
        .start_row = 10,
        .start_col = 5,
        .end_row = 8,
        .end_col = 3,
    };
    const n = sel.normalized();
    try std.testing.expectEqual(@as(i64, 8), n.start_row);
    try std.testing.expectEqual(@as(u16, 3), n.start_col);
    try std.testing.expectEqual(@as(i64, 10), n.end_row);
    try std.testing.expectEqual(@as(u16, 5), n.end_col);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -E 'Selection|error'`
Expected: Compilation error — `Selection` not found

**Step 3: Implement Selection and SelectionAnchor**

```zig
const SelectionAnchor = struct {
    pane: usize,
    unified_row: i64,
    col: u16,
};

const Selection = struct {
    pane: usize,
    start_row: i64,
    start_col: u16,
    end_row: i64,
    end_col: u16,

    fn normalized(self: Selection) Selection {
        if (self.start_row > self.end_row or
            (self.start_row == self.end_row and self.start_col > self.end_col))
        {
            return .{
                .pane = self.pane,
                .start_row = self.end_row,
                .start_col = self.end_col,
                .end_row = self.start_row,
                .end_col = self.start_col,
            };
        }
        return self;
    }

    fn contains(self: Selection, unified_row: i64, col: u16) bool {
        // self must be normalized
        if (unified_row < self.start_row or unified_row > self.end_row) return false;
        if (self.start_row == self.end_row) {
            return col >= self.start_col and col <= self.end_col;
        }
        if (unified_row == self.start_row) return col >= self.start_col;
        if (unified_row == self.end_row) return col <= self.end_col;
        return true; // middle line
    }
};
```

**Step 4: Run tests**

Run: `zig build test 2>/dev/null; echo $?`
Expected: 0

**Step 5: Commit**

```bash
git add src/event_loop.zig
git commit -m "feat: add Selection and SelectionAnchor data types"
```

---

### Task 2: Mouse event handling for selection (press/drag/release)

**Files:**
- Modify: `src/event_loop.zig`

**Step 1: Add selection state variables to runMultiPane**

After `var drag_state: ?DragState = null;` (line 220), add:
```zig
var selection_anchor: ?SelectionAnchor = null;
var selection: ?Selection = null;
```

**Step 2: Pass selection state to handleMouseEvent**

Add `selection_anchor: *?SelectionAnchor` and `selection: *?Selection` parameters to `handleMouseEvent`. Update the call site in `runMultiPane` to pass `&selection_anchor, &selection`.

**Step 3: Helper to compute unified row from mouse event**

```zig
fn unifiedRowFromMouse(panes: []const Pane, rects: []const Layout.Rect, pane_idx: usize, ev_row: u16) i64 {
    const screen = &panes[pane_idx].screen;
    const local_row: i64 = @as(i64, ev_row) - @as(i64, rects[pane_idx].row);
    const sb_count: i64 = @intCast(screen.scrollbackLen());
    const scroll_offset: i64 = @intCast(panes[pane_idx].scroll_offset);
    return sb_count - scroll_offset + local_row;
}
```

**Step 4: Modify press handler**

In the `.press` handler, after the Ctrl+click hyperlink check and before the junction/border checks, for left clicks on a non-passthrough pane:

```zig
// Record selection anchor for potential drag selection
if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
    if (panes[target_pane].mouse_mode != .passthrough) {
        const local_col = ev.col -| rects[target_pane].col;
        selection_anchor.* = .{
            .pane = target_pane,
            .unified_row = unifiedRowFromMouse(panes, rects, target_pane, ev.row),
            .col = local_col,
        };
        // Clear any previous selection
        selection.* = null;
    }
}
```

Place this BEFORE the existing junction/border/focus logic so the anchor is set regardless.

**Step 5: Modify drag handler**

In the `.drag` handler, when `drag_state.*` is null (no border drag) and `selection_anchor.*` is set:

```zig
if (selection_anchor.*) |anchor| {
    if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
        if (target_pane == anchor.pane) {
            const local_col = ev.col -| rects[target_pane].col;
            const unified = unifiedRowFromMouse(panes, rects, target_pane, ev.row);
            selection.* = .{
                .pane = anchor.pane,
                .start_row = anchor.unified_row,
                .start_col = anchor.col,
                .end_row = unified,
                .end_col = local_col,
            };
            needs_render.* = true;

            // Auto-scroll when dragging past pane edges
            const rect = rects[target_pane];
            if (ev.row <= rect.row and panes[target_pane].scroll_offset < panes[target_pane].screen.scrollbackLen()) {
                panes[target_pane].scrollViewUp(1);
                selection.*.?.end_row -= 1;
                // Don't update anchor — it stays in unified coords
            } else if (ev.row >= rect.row + rect.height -| 1 and panes[target_pane].scroll_offset > 0) {
                panes[target_pane].scrollViewDown(1);
                selection.*.?.end_row += 1;
            }
        }
    }
}
```

**Step 6: Modify release handler**

In the `.release` handler:

```zig
if (selection.*) |sel| {
    // Copy selected text to clipboard via OSC 52
    copySelectionToClipboard(terminal, panes, sel);
    selection.* = null;
    selection_anchor.* = null;
    needs_render.* = true;
} else if (selection_anchor.*) |anchor| {
    // Click without drag — existing behavior (hyperlink/focus)
    selection_anchor.* = null;
    // The existing release logic (forward to passthrough) continues below
}
```

Note: The existing release logic (forward release to passthrough panes, reset cursor shape, clear drag_state) must still execute. Place the selection handling BEFORE the existing code, and `return` after `copySelectionToClipboard` to skip the passthrough forwarding.

**Step 7: Move hyperlink-on-click to release handler**

Since we now defer click-vs-drag determination to release, the "click on active pane opens hyperlink" logic needs to move from the press handler to the release handler's "click without drag" path:

In the `else if (selection_anchor.*) |anchor|` block:
```zig
// No drag happened — handle as click
if (panes[anchor.pane].mouse_mode != .passthrough and anchor.pane == active_pane.*) {
    const local_row = ev.row -| rects[anchor.pane].row;
    const local_col = ev.col -| rects[anchor.pane].col;
    const cell = panes[anchor.pane].screen.cellAt(local_row, local_col);
    if (panes[anchor.pane].screen.hyperlinkUrl(cell.hyperlink)) |url| {
        openUrl(url);
        selection_anchor.* = null;
        return;
    }
}
// Focus pane if different
if (anchor.pane != active_pane.*) {
    active_pane.* = anchor.pane;
    recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
    needs_render.* = true;
}
selection_anchor.* = null;
```

Remove the hyperlink-on-click from the press handler (the `else if (target_pane == active_pane.*)` block).

**Step 8: Run all tests and build**

Run: `zig build test 2>/dev/null; echo $? && zig build 2>&1; echo $?`
Expected: 0, 0

**Step 9: Commit**

```bash
git add src/event_loop.zig
git commit -m "feat: add mouse-driven text selection with anchor/drag/release flow"
```

---

### Task 3: Render selection highlight

**Files:**
- Modify: `src/Renderer.zig`
- Modify: `src/event_loop.zig` (pass selection to renderer)

**Step 1: Add selection parameter to renderPaneWithOffset**

Change signature:
```zig
pub fn renderPaneWithOffset(
    self: *const Renderer,
    writer: anytype,
    screen: *const Screen,
    rect: Layout.Rect,
    scroll_offset: usize,
    pane_selection: ?Selection,  // new
) !void
```

Import `Selection` from event_loop or define a shared type. Since Zig doesn't have circular imports easily, define a `SelectionRange` struct in Renderer.zig:

```zig
pub const SelectionRange = struct {
    start_row: i64,
    start_col: u16,
    end_row: i64,
    end_col: u16,

    fn contains(self: SelectionRange, unified_row: i64, col: u16) bool {
        if (unified_row < self.start_row or unified_row > self.end_row) return false;
        if (self.start_row == self.end_row) {
            return col >= self.start_col and col <= self.end_col;
        }
        if (unified_row == self.start_row) return col >= self.start_col;
        if (unified_row == self.end_row) return col <= self.end_col;
        return true;
    }
};
```

**Step 2: Apply inverse video for selected cells**

In `renderPaneWithOffset`, after getting the cell and before the SGR check, determine if the cell is selected:

```zig
const is_selected = if (pane_selection) |sel|
    sel.contains(unified, col)
else
    false;
```

When the cell is selected, swap fg and bg for the SGR output. Modify the SGR comparison to also trigger on selection changes:

```zig
var render_fg = cell.fg;
var render_bg = cell.bg;
if (is_selected) {
    render_fg = if (cell.bg == .default) Screen.Color{ .indexed = 0 } else cell.bg;
    render_bg = if (cell.fg == .default) Screen.Color{ .indexed = 7 } else cell.fg;
}
```

Add `var last_selected: bool = false;` tracking. Include selection in the attribute change check:

```zig
if (!std.meta.eql(render_fg, last_fg) or !std.meta.eql(render_bg, last_bg) or
    !std.meta.eql(cell.style, last_style) or is_selected != last_selected)
```

Pass `render_fg`/`render_bg` to writeSgr instead of cell's original colors. This requires either modifying writeSgr or creating a modified cell. Simplest: create a local cell copy with swapped colors:

```zig
var render_cell = cell.*;
if (is_selected) {
    render_cell.fg = render_fg;
    render_cell.bg = render_bg;
}
```

Then pass `&render_cell` to `writeSgr`.

Update `last_selected = is_selected;` after rendering.

**Step 3: Update renderFrameWithScrollback to pass selection**

```zig
pub fn renderFrameWithScrollback(
    self: *const Renderer,
    writer: anytype,
    screens: []const *const Screen,
    rects: []const Layout.Rect,
    scroll_offsets: []const usize,
    active_pane: usize,
    pane_selections: []const ?SelectionRange,  // new
) !void
```

In the render loop:
```zig
for (screens, rects, scroll_offsets, pane_selections) |screen, rect, offset, sel| {
    try self.renderPaneWithOffset(writer, screen, rect, offset, sel);
}
```

**Step 4: Update event_loop.zig renderAll to build and pass selections**

Build a `pane_selections` array from the current `selection` variable:

```zig
var pane_selections: [max_panes]?Renderer.SelectionRange = .{null} ** max_panes;
if (selection) |sel| {
    const n = sel.normalized();
    pane_selections[sel.pane] = .{
        .start_row = n.start_row,
        .start_col = n.start_col,
        .end_row = n.end_row,
        .end_col = n.end_col,
    };
}
```

Pass `pane_selections[0..panes.len]` to `renderFrameWithScrollback`.

This requires `renderAll` to accept a `selection: ?Selection` parameter. Thread it from `runMultiPane`.

**Step 5: Run tests and build**

Run: `zig build test 2>/dev/null; echo $? && zig build 2>&1; echo $?`
Expected: 0, 0

**Step 6: Commit**

```bash
git add src/Renderer.zig src/event_loop.zig
git commit -m "feat: render text selection with inverse video highlight"
```

---

### Task 4: Copy selected text to clipboard via OSC 52

**Files:**
- Modify: `src/event_loop.zig`
- Modify: `src/Screen.zig` (add text extraction helper)

**Step 1: Write failing test — Screen.extractText**

```zig
test "extractText returns cell characters as UTF-8" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.writeChar('H');
    screen.writeChar('i');
    screen.writeChar('!');

    var buf: [64]u8 = undefined;
    const text = screen.extractLineText(0, 0, 2, &buf);
    try std.testing.expectEqualStrings("Hi!", text);
}
```

**Step 2: Implement Screen.extractLineText**

```zig
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
```

**Step 3: Implement copySelectionToClipboard in event_loop.zig**

```zig
fn copySelectionToClipboard(terminal: *const Terminal.Terminal, panes: []const Pane, sel: Selection) void {
    const n = sel.normalized();
    const screen = &panes[n.pane].screen;
    const sb_count: i64 = @intCast(screen.scrollbackLen());

    // Build selected text into a buffer
    var text_buf: [16384]u8 = undefined;
    var text_pos: usize = 0;

    var row = n.start_row;
    while (row <= n.end_row) : (row += 1) {
        const start_c: u16 = if (row == n.start_row) n.start_col else 0;
        const end_c: u16 = if (row == n.end_row) n.end_col else screen.width -| 1;

        var line_buf: [1024]u8 = undefined;
        const line_text = if (row < sb_count) blk: {
            // Scrollback line
            if (screen.scrollbackLine(@intCast(row))) |line| {
                var lpos: usize = 0;
                var c = start_c;
                while (c <= end_c) : (c += 1) {
                    if (c >= line.len) break;
                    const cell = &line[c];
                    if (cell.char == 0) continue;
                    var utf8: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.char, &utf8) catch continue;
                    if (lpos + len > line_buf.len) break;
                    @memcpy(line_buf[lpos..][0..len], utf8[0..len]);
                    lpos += len;
                }
                while (lpos > 0 and line_buf[lpos - 1] == ' ') lpos -= 1;
                break :blk line_buf[0..lpos];
            }
            break :blk @as([]const u8, "");
        } else blk: {
            // Live screen line
            const screen_row: u16 = @intCast(row - sb_count);
            break :blk screen.extractLineText(screen_row, start_c, end_c, &line_buf);
        };

        if (text_pos + line_text.len + 1 > text_buf.len) break;
        @memcpy(text_buf[text_pos..][0..line_text.len], line_text);
        text_pos += line_text.len;
        if (row < n.end_row) {
            text_buf[text_pos] = '\n';
            text_pos += 1;
        }
    }

    if (text_pos == 0) return;

    // Base64 encode and send via OSC 52
    const text = text_buf[0..text_pos];
    var b64_buf: [24000]u8 = undefined;  // ceil(16384 * 4/3)
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, text);

    // OSC 52: \x1b]52;c;<base64>\x07
    terminal.writeAll("\x1b]52;c;") catch return;
    terminal.writeAll(b64) catch return;
    terminal.writeAll("\x07") catch return;
}
```

**Step 4: Run all tests and build**

Run: `zig build test 2>/dev/null; echo $? && zig build 2>&1; echo $?`
Expected: 0, 0

**Step 5: Commit**

```bash
git add src/Screen.zig src/event_loop.zig
git commit -m "feat: copy selected text to clipboard via OSC 52"
```

---

## Verification

1. `zig build test` — all tests pass
2. `zig build` — builds successfully
3. Manual test:
   - Start zyouz with a non-passthrough pane
   - Run some commands to produce output
   - Click and drag to select text → selection highlights in inverse
   - Release → text is copied to clipboard
   - Paste (Cmd+V) → selected text appears
   - Scroll up, select across scrollback → works
   - Drag past pane bottom/top → auto-scrolls
   - Click without drag → still opens hyperlinks / focuses panes
