# Milestone 1: Single Pane — PTY + Raw Terminal

## Goal

Launch a single command in a PTY, display its output fullscreen, and forward keyboard input. A transparent terminal passthrough that proves the PTY pipeline works end-to-end.

**Exit criteria:** `zyouz` launches `bash` fullscreen, indistinguishable from running `bash` directly. Ctrl+S → Ctrl+Q exits cleanly.

---

## Module Structure

```
src/
  root.zig          # Library root — re-exports public API
  main.zig          # CLI entry point — wires modules together
  input.zig         # Prefix key state machine (pure logic)
  Terminal.zig      # Raw mode, alternate screen, I/O
  Pty.zig           # PTY allocation + child process management
  event_loop.zig    # Main poll loop — ties everything together
```

### Why this split

| Module | Testability | OS dependency |
|--------|-------------|---------------|
| `input.zig` | Pure unit tests | None |
| `Terminal.zig` | Integration tests | termios, ioctl |
| `Pty.zig` | Integration tests | openpty, fork, exec |
| `event_loop.zig` | End-to-end only | poll, signals |

Bottom-up order: `input.zig` → `Terminal.zig` → `Pty.zig` → `event_loop.zig` → `main.zig`

---

## Module Designs

### 1. input.zig — Prefix Key State Machine

Pure logic: takes input bytes, returns an action. No side effects.

**State machine:**

```
                  Ctrl+S
     ┌──────────┐ ────────→ ┌──────────┐
     │  normal   │           │ command  │
     └──────────┘ ←──────── └──────────┘
                  other key        │
                  (forward)        │ Ctrl+Q
                                   ↓
                                 quit
```

- **normal**: All bytes forwarded to PTY, except Ctrl+S (0x13) which transitions to `command`.
- **command**: Ctrl+Q (0x11) signals quit. Any other key exits command mode and is forwarded to PTY.

**Public interface:**

```zig
pub const Action = union(enum) {
    /// Forward these bytes to the PTY.
    forward: []const u8,
    /// Clean shutdown requested (Ctrl+S → Ctrl+Q).
    quit,
    /// Input consumed by state machine, no action needed.
    none,
};

pub const InputHandler = struct {
    state: State = .normal,

    const State = enum { normal, command };

    /// Process a single byte of input. Returns the action to take.
    pub fn feed(self: *InputHandler, byte: u8) Action { ... }
};
```

**Test cases (TDD targets):**

1. Normal mode: regular byte → `forward` with that byte
2. Normal mode: Ctrl+S → `none`, state becomes `command`
3. Command mode: Ctrl+Q → `quit`
4. Command mode: other byte → `forward` with that byte, state becomes `normal`
5. Double Ctrl+S → forward Ctrl+S to PTY (second Ctrl+S in command mode exits and forwards)

### 2. Terminal.zig — Raw Terminal Mode

Wraps POSIX termios for raw mode and ANSI escape sequences for alternate screen.

**Public interface:**

```zig
pub const Terminal = struct {
    tty: std.posix.fd_t,
    original_termios: std.posix.termios,

    /// Open the controlling terminal and save original state.
    pub fn init() !Terminal { ... }

    /// Set raw mode: disable canonical, echo, signals. VMIN=1, VTIME=0.
    pub fn enableRawMode(self: *Terminal) !void { ... }

    /// Restore original terminal state.
    pub fn disableRawMode(self: *Terminal) !void { ... }

    /// Enter alternate screen buffer (CSI ?1049h).
    pub fn enterAlternateScreen(self: *Terminal) !void { ... }

    /// Leave alternate screen buffer (CSI ?1049l).
    pub fn leaveAlternateScreen(self: *Terminal) !void { ... }

    /// Get current terminal dimensions (rows, cols).
    pub fn getSize(self: *Terminal) !Size { ... }

    /// Read available input bytes. Non-blocking when used with poll.
    pub fn read(self: *Terminal, buf: []u8) !usize { ... }

    /// Write output bytes to terminal.
    pub fn write(self: *Terminal, data: []const u8) !void { ... }
};

pub const Size = struct {
    rows: u16,
    cols: u16,
};
```

**Raw mode termios flags:**

```
Disable: ECHO, ICANON, ISIG, IEXTEN, IXON, ICRNL, OPOST, BRKINT, INPCK, ISTRIP
Set: CS8, VMIN=1, VTIME=0
```

- ISIG disabled: Ctrl+C, Ctrl+Z forwarded to PTY instead of generating signals.
- IXON disabled: Ctrl+S/Ctrl+Q not intercepted by flow control.
- ICRNL disabled: CR not translated to NL — preserves raw input.
- OPOST disabled: No output processing — ANSI passthrough.

### 3. Pty.zig — PTY Allocation and Child Process

Wraps POSIX PTY APIs to allocate a pseudo-terminal and spawn a child process.

**Public interface:**

```zig
pub const Pty = struct {
    master_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,

    /// Allocate a PTY and spawn the given command.
    /// Child process gets its own session and the PTY as controlling terminal.
    pub fn spawn(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        size: Terminal.Size,
    ) !Pty { ... }

    /// Set the PTY window size (TIOCSWINSZ).
    pub fn setSize(self: *Pty, size: Terminal.Size) !void { ... }

    /// Read output from the child process.
    pub fn read(self: *Pty, buf: []u8) !usize { ... }

    /// Write input to the child process.
    pub fn write(self: *Pty, data: []const u8) !void { ... }

    /// Send signal to child process and close PTY.
    pub fn kill(self: *Pty) void { ... }

    /// Wait for child to exit, returns exit status.
    pub fn wait(self: *Pty) !u32 { ... }
};
```

**Spawn sequence:**

1. `std.posix.openpty()` → (master_fd, slave_fd)
2. Set initial window size on master_fd via `TIOCSWINSZ`
3. `std.posix.fork()`
4. Child: `setsid()`, set slave as controlling terminal, `dup2()` to 0/1/2, close master, `execvpe()`
5. Parent: close slave_fd, return `Pty{ .master_fd, .child_pid }`

### 4. event_loop.zig — Main Event Loop

Multiplexes terminal input, PTY output, and signals using `poll()`.

**Data flow:**

```
Terminal stdin ──→ InputHandler ──→ PTY master (write)
                       │
                       ├── quit → break loop
                       └── none → discard

PTY master (read) ──→ Terminal stdout

SIGWINCH (via self-pipe) ──→ Terminal.getSize() ──→ Pty.setSize()
```

**Public interface:**

```zig
pub fn run(terminal: *Terminal, pty: *Pty) !void { ... }
```

**Poll sources (3 file descriptors):**

1. `terminal.tty` — keyboard input ready
2. `pty.master_fd` — child output ready
3. Signal pipe read end — SIGWINCH notification

**Signal handling strategy:**

SIGWINCH cannot be handled directly inside the poll loop. Use the self-pipe trick:
- At startup, create a `pipe()`.
- Register a SIGWINCH handler that writes 1 byte to the pipe.
- Poll the pipe's read end alongside other fds.
- When the pipe is readable, consume the byte and propagate the new terminal size to the PTY.

### 5. main.zig — CLI Entry Point

Wires all modules together:

```zig
pub fn main() !void {
    var terminal = try Terminal.init();
    try terminal.enableRawMode();
    try terminal.enterAlternateScreen();
    defer {
        terminal.leaveAlternateScreen() catch {};
        terminal.disableRawMode() catch {};
    }

    const size = try terminal.getSize();
    var pty = try Pty.spawn(allocator, &.{"bash"}, size);
    defer pty.kill();

    try event_loop.run(&terminal, &pty);
}
```

---

## Clean Shutdown Sequence

1. InputHandler returns `.quit`
2. Event loop breaks
3. Send `SIGHUP` to child process group
4. Wait for child exit (short timeout)
5. If child doesn't exit, send `SIGKILL`
6. Leave alternate screen
7. Restore terminal mode
8. Exit process

The `defer` chain in `main.zig` ensures terminal state is always restored, even on error.

---

## Testing Strategy

### Layer 1: Pure Unit Tests (input.zig)

Full TDD with Red-Green-Refactor. Test every state transition:

- Normal → byte → forward
- Normal → Ctrl+S → none, enter command
- Command → Ctrl+Q → quit
- Command → byte → forward, enter normal
- Rapid sequences: Ctrl+S Ctrl+S, Ctrl+S a Ctrl+S Ctrl+Q

### Layer 2: Integration Tests (Terminal.zig, Pty.zig)

Test with real OS resources, but isolated:

- Terminal: open /dev/tty, enter/exit raw mode without crash
- PTY: spawn `echo hello`, read output, verify "hello\n"
- PTY: spawn `cat`, write input, read echo
- PTY: set size, verify via child `stty size`
- PTY: kill child, verify wait returns

### Layer 3: Behavioral Tests (event_loop.zig)

Harder to automate. Manual verification + simple scripted tests:

- Spawn `echo hello && exit`, verify output and clean exit
- Spawn `cat`, type input, verify echo
- Resize terminal during `cat`, verify no crash

---

## Implementation Order (TDD)

1. **input.zig** — Red-Green-Refactor for each state transition
2. **Terminal.zig** — Raw mode enter/exit, get size
3. **Pty.zig** — Spawn, read, write, kill, set size
4. **event_loop.zig** — Poll loop, signal handling
5. **main.zig** — Wire everything, manual end-to-end test
6. **Cleanup** — Error handling, edge cases, polish

Each step builds on the previous. No step requires stubs or mocks of later modules.
