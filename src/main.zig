const std = @import("std");
const zyouz = @import("zyouz");

const Config = zyouz.Config;
const Layout = zyouz.Layout;
const Pane = zyouz.Pane;
const Renderer = zyouz.Renderer;

fn collectLeaves(pane: Config.Pane, out: *std.ArrayListUnmanaged(Config.Pane.Leaf)) !void {
    switch (pane) {
        .leaf => |leaf| try out.append(std.heap.page_allocator, leaf),
        .split => |split| {
            for (split.children) |child| {
                try collectLeaves(child, out);
            }
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const layout_name: ?[]const u8 = if (args.len > 1) args[1] else null;

    if (layout_name != null) {
        const config_path = try Config.defaultConfigPath(allocator);
        defer allocator.free(config_path);

        var config = Config.parseFile(allocator, config_path) catch |err| {
            std.debug.print("error: failed to load config from {s}: {s}\n", .{ config_path, @errorName(err) });
            std.process.exit(1);
        };
        defer config.deinit();

        const layout = config.resolveLayout(layout_name) catch |err| switch (err) {
            error.NoDefaultLayout => {
                std.debug.print("error: no 'default' layout found in config\n", .{});
                std.process.exit(1);
            },
            error.LayoutNotFound => {
                std.debug.print("error: layout '{s}' not found in config\n", .{layout_name.?});
                std.process.exit(1);
            },
        };

        // Initialize terminal (but don't enter alternate screen yet —
        // errors during setup must remain visible on the normal screen).
        var terminal = zyouz.Terminal.Terminal.init() catch |err| {
            if (err == error.NotATerminal) {
                std.debug.print("error: no controlling terminal (stdin is not a TTY)\n", .{});
                std.debug.print("hint: run the binary directly: ./zig-out/bin/zyouz\n", .{});
            }
            return err;
        };
        defer terminal.deinit();

        try terminal.enableRawMode();
        defer terminal.disableRawMode();

        const size = try terminal.getSize();

        // Compute layout rects
        const area = Layout.Rect{ .col = 0, .row = 0, .width = size.cols, .height = size.rows };
        const rects = try Layout.compute(allocator, layout.root, area);
        defer allocator.free(rects);

        // Collect leaf panes (depth-first order matches rect order)
        var leaves: std.ArrayListUnmanaged(Config.Pane.Leaf) = .empty;
        defer leaves.deinit(std.heap.page_allocator);
        try collectLeaves(layout.root, &leaves);

        if (leaves.items.len != rects.len) {
            std.debug.print("error: leaf count ({d}) != rect count ({d})\n", .{ leaves.items.len, rects.len });
            std.process.exit(1);
        }

        // Spawn panes (before alternate screen so errors are visible)
        var panes_buf: [32]Pane = undefined;
        const pane_count = @min(leaves.items.len, 32);
        for (0..pane_count) |i| {
            panes_buf[i] = try Pane.initFromCommand(allocator, leaves.items[i].command, rects[i]);
        }
        const panes = panes_buf[0..pane_count];
        defer {
            for (panes) |*p| p.deinit();
        }

        // Create renderer
        var renderer = try Renderer.init(allocator, size.cols, size.rows);
        defer renderer.deinit();

        // Make a mutable copy of rects for resize
        var mutable_rects_buf: [32]Layout.Rect = undefined;
        @memcpy(mutable_rects_buf[0..pane_count], rects[0..pane_count]);
        const mutable_rects = mutable_rects_buf[0..pane_count];

        // Now enter alternate screen — all fallible setup is done.
        try terminal.enterAlternateScreen();
        defer terminal.leaveAlternateScreen() catch {};

        // Run multi-pane event loop
        var active_pane: usize = 0;
        zyouz.event_loop.runMultiPane(
            allocator,
            &terminal,
            panes,
            &renderer,
            mutable_rects,
            layout.root,
            &active_pane,
        ) catch |err| {
            std.debug.print("event loop error: {s}\n", .{@errorName(err)});
        };

        return;
    }

    // Default: launch single pane terminal (Milestone 1 behavior).
    var terminal = zyouz.Terminal.Terminal.init() catch |err| {
        if (err == error.NotATerminal) {
            std.debug.print("error: no controlling terminal (stdin is not a TTY)\n", .{});
            std.debug.print("hint: run the binary directly: ./zig-out/bin/zyouz\n", .{});
        }
        return err;
    };
    defer terminal.deinit();

    try terminal.enableRawMode();
    defer terminal.disableRawMode();

    try terminal.enterAlternateScreen();
    defer terminal.leaveAlternateScreen() catch {};

    const size = try terminal.getSize();

    const argv = [_:null]?[*:0]const u8{"/bin/bash"};
    var pty = try zyouz.Pty.Pty.spawn(&argv, size);
    defer pty.deinit();

    zyouz.event_loop.run(&terminal, &pty) catch |err| {
        std.debug.print("event loop error: {s}\n", .{@errorName(err)});
    };
}
