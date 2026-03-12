const std = @import("std");
const zyouz = @import("zyouz");

const Config = zyouz.Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const layout_name: ?[]const u8 = if (args.len > 1) args[1] else null;

    // If a layout name is given (or we want to use config), parse config.
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
                std.debug.print("hint: add a layout named 'default', or specify a layout name: zyouz <name>\n", .{});
                std.process.exit(1);
            },
            error.LayoutNotFound => {
                std.debug.print("error: layout '{s}' not found in config\n", .{layout_name.?});
                std.process.exit(1);
            },
        };

        const stdout = std.fs.File.stdout().deprecatedWriter();
        const name = layout_name orelse "default";
        try stdout.print("Layout: {s}\n", .{name});
        try Config.printTree(stdout, layout.root, 0);
        return;
    }

    // Default: launch single pane terminal (Milestone 1 behavior).
    var terminal = try zyouz.Terminal.Terminal.init();
    defer terminal.deinit();

    try terminal.enableRawMode();
    defer terminal.disableRawMode();

    try terminal.enterAlternateScreen();
    defer terminal.leaveAlternateScreen() catch {};

    const size = try terminal.getSize();

    const argv = [_:null]?[*:0]const u8{"/bin/bash"};
    var pty = try zyouz.Pty.Pty.spawn(&argv, size);
    defer pty.deinit();

    zyouz.event_loop.run(&terminal, &pty) catch {};
}
