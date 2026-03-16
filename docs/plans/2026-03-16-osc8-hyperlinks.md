# OSC 8 Hyperlink Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Support OSC 8 hyperlinks so that terminal programs (ls, cargo, gcc, etc.) can output clickable links that are preserved through zyouz's rendering pipeline and displayed by the host terminal.

**Architecture:** VtParser buffers OSC payloads and parses OSC 8 sequences to extract hyperlink URLs. Screen stores a URL table and tracks the current hyperlink per cell via a compact u16 index. Renderer detects hyperlink changes between cells and emits OSC 8 open/close sequences alongside SGR attributes.

**Tech Stack:** Zig 0.15, OSC 8 protocol (ESC]8;params;url ST)

---

## Data Design

### URL Storage

Screen maintains an `ArrayList([]const u8)` as a URL table. Each unique URL is stored once. Cell stores a `u16` index (0 = no hyperlink, 1+ = index+1 into the table). This keeps Cell small (only 2 bytes added) while supporting up to 65534 unique URLs per screen.

### OSC 8 Protocol

```
Open:  ESC ] 8 ; params ; url ST    (ST = ESC \ or BEL)
Close: ESC ] 8 ; ; ST
```

params is typically empty or contains `id=value` for multi-line link grouping.

---

### Task 1: Add hyperlink field to Cell and URL table to Screen

**Files:**
- Modify: `src/Screen.zig`

**Step 1: Write failing test — Cell stores hyperlink index**

```zig
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
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -A2 'hyperlink'`
Expected: Compilation error — `hyperlink` field not found

**Step 3: Implement Cell.hyperlink field, URL table, and internHyperlink**

In `Screen.zig`:

1. Add to `Cell` struct:
```zig
hyperlink: u16 = 0,
```

2. Add to `Screen` struct fields:
```zig
hyperlink_urls: std.ArrayListUnmanaged([]const u8) = .empty,
current_hyperlink: u16 = 0,
```

3. Add methods:
```zig
pub fn internHyperlink(self: *Screen, url: []const u8) !u16 {
    // Check if URL already interned
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
```

4. In `writeChar()`, apply `self.current_hyperlink` to the cell:
```zig
cell.* = .{
    .char = char,
    .fg = self.current_fg,
    .bg = self.current_bg,
    .style = self.current_style,
    .wide = (w == 2),
    .hyperlink = self.current_hyperlink,
};
```

5. In `deinit()`, free the URL strings:
```zig
for (self.hyperlink_urls.items) |url| {
    self.allocator.free(url);
}
self.hyperlink_urls.deinit(self.allocator);
```

6. In `resetAttributes()`, reset hyperlink:
```zig
self.current_hyperlink = 0;
```

**Step 4: Run test to verify it passes**

Run: `zig build test 2>/dev/null; echo $?`
Expected: 0

**Step 5: Commit**

```bash
git add src/Screen.zig
git commit -m "feat: add hyperlink storage to Cell and URL table to Screen"
```

---

### Task 2: Buffer OSC payloads in VtParser

**Files:**
- Modify: `src/VtParser.zig`

**Step 1: Write failing test — OSC 8 sets hyperlink on screen**

```zig
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
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep 'OSC 8'`
Expected: Test fails — hyperlink is 0

**Step 3: Add OSC buffer and dispatch OSC 8**

In `VtParser.zig`:

1. Add OSC buffer fields:
```zig
osc_buf: [2048]u8 = undefined,
osc_len: u16 = 0,
```

2. Replace `processOsc` to buffer payload:
```zig
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
```

3. Update the escape handler so that `\` after OSC also dispatches:

In `processEscape`, the current handling for `\` when coming from osc_string needs to call `dispatchOsc()`. Check how the state machine transitions — when in `osc_string` state and ESC is received, `processOsc` sets `state = .escape`. Then the next byte `\` is processed by `processEscape`. Look for the handler for `\\` in processEscape and add `dispatchOsc()` call there.

Note: `processEscape` currently resets to ground for unrecognized bytes. The `\\` byte after ESC from an OSC state needs to trigger dispatch. Check if there's a way to know we came from OSC state. If not, add a flag or check `osc_len > 0`.

4. Add `dispatchOsc`:
```zig
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
    // Find the semicolon separating params from URL
    const sep = std.mem.indexOfScalar(u8, data, ';') orelse return;
    const url = data[sep + 1 ..];

    if (url.len == 0) {
        // Close hyperlink
        self.screen.current_hyperlink = 0;
    } else {
        self.screen.current_hyperlink = self.screen.internHyperlink(url) catch 0;
    }
}
```

5. Reset `osc_len` in `resetParams`:
```zig
self.osc_len = 0;
```

**Step 4: Run test to verify it passes**

Run: `zig build test 2>/dev/null; echo $?`
Expected: 0

**Step 5: Write additional test — OSC 8 with BEL terminator**

```zig
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
```

**Step 6: Run all tests**

Run: `zig build test 2>/dev/null; echo $?`
Expected: 0

**Step 7: Commit**

```bash
git add src/VtParser.zig
git commit -m "feat: parse OSC 8 hyperlinks in VtParser"
```

---

### Task 3: Emit OSC 8 sequences in Renderer

**Files:**
- Modify: `src/Renderer.zig`

**Step 1: Write failing test — rendered output contains OSC 8**

This test needs to verify that when a cell has a hyperlink, the rendered output includes the OSC 8 sequence. Test by writing to a screen, then calling the renderer and checking the output buffer.

```zig
test "renderPane emits OSC 8 for hyperlinked cells" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    const url = "https://example.com";
    const idx = try screen.internHyperlink(url);
    screen.current_hyperlink = idx;
    screen.writeChar('H');
    screen.writeChar('i');
    screen.current_hyperlink = 0;
    screen.writeChar('!');

    var renderer = try Renderer.init(std.testing.allocator, 20, 5);
    defer renderer.deinit();

    const rects = &[_]Layout.Rect{.{ .col = 0, .row = 0, .width = 10, .height = 3 }};
    const screens = &[_]*const Screen{&screen};
    const offsets = &[_]usize{0};

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const writer = buf.writer(std.testing.allocator);

    try renderer.renderFrameWithScrollback(writer, screens, rects, offsets, 0);

    const output = buf.items;
    // Should contain OSC 8 open sequence
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b]8;;https://example.com\x1b\\") != null);
    // Should contain OSC 8 close sequence
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b]8;;\x1b\\") != null);
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — output doesn't contain OSC 8

**Step 3: Add hyperlink tracking and emission to Renderer**

In `renderPaneWithOffset` (and `renderPane` if used):

1. Add tracking variable alongside `last_fg`, `last_bg`, `last_style`:
```zig
var last_hyperlink: u16 = 0;
```

2. In the cell comparison check, add hyperlink:
```zig
if (!std.meta.eql(cell.fg, last_fg) or !std.meta.eql(cell.bg, last_bg) or
    !std.meta.eql(cell.style, last_style) or cell.hyperlink != last_hyperlink)
```

3. Before `writeSgr`, emit OSC 8 if hyperlink changed:
```zig
if (cell.hyperlink != last_hyperlink) {
    if (cell.hyperlink == 0) {
        try writer.writeAll("\x1b]8;;\x1b\\");
    } else if (screen.hyperlinkUrl(cell.hyperlink)) |url| {
        try writer.writeAll("\x1b]8;;");
        try writer.writeAll(url);
        try writer.writeAll("\x1b\\");
    }
    last_hyperlink = cell.hyperlink;
}
```

4. At end of pane rendering (where `\x1b[0m` reset is emitted), also close any open hyperlink:
```zig
if (last_hyperlink != 0) {
    try writer.writeAll("\x1b]8;;\x1b\\");
    last_hyperlink = 0;
}
```

Note: The renderer receives `screens: []const *const Screen`, so it has access to `screen.hyperlinkUrl()`. The `renderPaneWithOffset` function needs the screen reference passed to it or accessible from the screens array.

**Step 4: Run test to verify it passes**

Run: `zig build test 2>/dev/null; echo $?`
Expected: 0

**Step 5: Commit**

```bash
git add src/Renderer.zig
git commit -m "feat: emit OSC 8 hyperlinks in renderer output"
```

---

### Task 4: Edge cases and integration tests

**Files:**
- Modify: `src/VtParser.zig` (tests)
- Modify: `src/Screen.zig` (tests)

**Step 1: Test — same URL is interned once**

```zig
test "internHyperlink deduplicates same URL" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    const idx1 = try screen.internHyperlink("https://example.com");
    const idx2 = try screen.internHyperlink("https://example.com");
    const idx3 = try screen.internHyperlink("https://other.com");

    try std.testing.expectEqual(idx1, idx2);
    try std.testing.expect(idx3 != idx1);
}
```

**Step 2: Test — hyperlink reset on new line / screen clear**

```zig
test "resetAttributes clears current hyperlink" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    const idx = try screen.internHyperlink("https://example.com");
    screen.current_hyperlink = idx;
    screen.resetAttributes();

    try std.testing.expectEqual(@as(u16, 0), screen.current_hyperlink);
}
```

**Step 3: Test — OSC 8 with params (id=) is handled**

```zig
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
```

**Step 4: Test — switching hyperlinks without closing**

```zig
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
```

**Step 5: Run all tests**

Run: `zig build test 2>/dev/null; echo $?`
Expected: 0

**Step 6: Full build verification**

Run: `zig build 2>&1; echo $?`
Expected: 0

**Step 7: Commit**

```bash
git add src/Screen.zig src/VtParser.zig
git commit -m "test: add edge case tests for OSC 8 hyperlinks"
```

---

## Verification

1. `zig build test` — all tests pass
2. `zig build` — builds successfully
3. Manual test with `ls` (if coreutils supports OSC 8):
   - `ls --hyperlink=always` in a zyouz pane
   - Cmd+click on a filename should open it
4. Manual test with printf:
   - `printf '\e]8;;https://example.com\e\\Click me\e]8;;\e\\\n'`
   - "Click me" should be a clickable link in Ghostty
