const std = @import("std");
const zyouz = @import("zyouz");

pub fn main() !void {
    var terminal = try zyouz.Terminal.Terminal.init();
    defer terminal.deinit();

    try terminal.enableRawMode();
    defer terminal.disableRawMode();

    try terminal.enterAlternateScreen();
    defer terminal.leaveAlternateScreen() catch {};

    const size = try terminal.getSize();

    const argv = [_:null]?[*:0]const u8{ "/bin/bash" };
    var pty = try zyouz.Pty.Pty.spawn(&argv, size);
    defer pty.deinit();

    zyouz.event_loop.run(&terminal, &pty) catch {};
}
