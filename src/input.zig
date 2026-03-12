const std = @import("std");

pub const Action = union(enum) {
    /// Forward this byte to the PTY.
    forward: u8,
    /// Clean shutdown requested (Ctrl+S → Ctrl+Q).
    quit,
    /// Input consumed by state machine, no action needed.
    none,
};

pub const InputHandler = struct {
    state: State = .normal,

    const State = enum { normal, command };

    const prefix_key = 0x13; // Ctrl+S
    const quit_key = 0x11; // Ctrl+Q

    /// Process a single byte of input. Returns the action to take.
    pub fn feed(self: *InputHandler, byte: u8) Action {
        switch (self.state) {
            .normal => {
                if (byte == prefix_key) {
                    self.state = .command;
                    return .none;
                }
                return .{ .forward = byte };
            },
            .command => {
                if (byte == quit_key) {
                    return .quit;
                }
                self.state = .normal;
                return .{ .forward = byte };
            },
        }
    }
};

test "normal mode: regular byte is forwarded" {
    var handler = InputHandler{};
    const action = handler.feed('a');
    try std.testing.expectEqual(Action{ .forward = 'a' }, action);
}

test "normal mode: Ctrl+S enters command mode" {
    var handler = InputHandler{};
    const action = handler.feed(0x13); // Ctrl+S
    try std.testing.expectEqual(Action.none, action);
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}

test "command mode: Ctrl+Q signals quit" {
    var handler = InputHandler{ .state = .command };
    const action = handler.feed(0x11); // Ctrl+Q
    try std.testing.expectEqual(Action.quit, action);
}

test "command mode: other byte exits command mode and forwards" {
    var handler = InputHandler{ .state = .command };
    const action = handler.feed('x');
    try std.testing.expectEqual(Action{ .forward = 'x' }, action);
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
}

test "Ctrl+S twice: second Ctrl+S is forwarded" {
    var handler = InputHandler{};

    // First Ctrl+S enters command mode.
    const first = handler.feed(0x13);
    try std.testing.expectEqual(Action.none, first);
    try std.testing.expectEqual(InputHandler.State.command, handler.state);

    // Second Ctrl+S exits command mode and forwards the byte.
    const second = handler.feed(0x13);
    try std.testing.expectEqual(Action{ .forward = 0x13 }, second);
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
}

test "full quit sequence: Ctrl+S then Ctrl+Q" {
    var handler = InputHandler{};

    const enter = handler.feed(0x13); // Ctrl+S
    try std.testing.expectEqual(Action.none, enter);

    const quit = handler.feed(0x11); // Ctrl+Q
    try std.testing.expectEqual(Action.quit, quit);
}
