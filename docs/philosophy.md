# zyouz Philosophy

> zyouz (from Japanese "上手" / jouzu) — A minimal terminal multiplexer focused on declarative layout and one-shot startup.

## What is zyouz?

A minimal terminal multiplexer. Not a general-purpose workspace manager like tmux or zellij — zyouz does one thing well: launch a predefined set of panes with commands in a fixed layout, instantly.

## Core Principles

### Declarative

Everything is defined in the config file. What you write is what you get. No implicit behavior, no magic discovery of config files, no parent directory traversal.

### Fixed Structure

Panes cannot be added, removed, or rearranged at runtime. The layout is determined at startup and stays that way. Only pane sizes can be adjusted by dragging borders with the mouse.

### Disposable

No session management. No detach/attach. Close zyouz and everything terminates. Startup is instant from config, so "close and reopen" is the recovery model.

### Transparent

zyouz must not interfere with the terminal emulator's features. Cmd+click for URLs, link detection, and other terminal emulator capabilities should work as expected. zyouz renders PTY output faithfully to preserve these features.

### Single Prefix, Zero Interference

zyouz occupies exactly one keybinding: the prefix key (`Ctrl+S` by default). Everything else is forwarded to the focused pane's PTY. This is a deliberate differentiation from zellij, where extensive keybindings can interfere with pane programs.

Pressing the prefix key enters **command mode**. In command mode:

| Key | Action |
|-----|--------|
| Arrow keys | Switch pane focus (directional) — stays in command mode |
| `Ctrl+Q` | Quit (terminate all processes and exit zyouz) |
| Any other key | Exit command mode and forward the key to the focused pane |

Command mode is transient — it auto-exits the moment you press anything other than an arrow key. You never get stuck in a mode. The active pane is always indicated by its border style.

## Why zyouz Exists

zellij's layout system is excellent — define a layout, launch with commands, and your development environment is ready. But zellij is a full-featured terminal multiplexer with capabilities that can get in the way:

- Keybindings that conflict with programs running inside panes
- No horizontal scrolling
- Terminal emulator features (Cmd+click, URL detection) broken by zellij's rendering
- Features like session management, plugins, and tabs that add complexity without value for the "launch and work" use case

zyouz extracts the best part of zellij — declarative layout with one-shot startup — and discards everything else.

## What zyouz Does

- Named layout definitions with one-shot startup
- Per-pane mouse passthrough configuration (default: zyouz manages mouse; opt-in passthrough for TUI apps like nvim)
- Scrollback buffer management for non-passthrough panes
- Horizontal scrolling support
- Border dragging to resize panes
- Optional auto-restart on command failure

## What zyouz Does NOT Do

- **Tabs** — That is the terminal emulator's job (Ghostty, iTerm2, etc.)
- **Dynamic pane add/remove** — Structure is fixed at startup
- **Session detach/attach** — Close and reopen instead
- **Plugin system** — No extensibility beyond the config file
- **Config hot-reload** — Close and reopen instead

These are not missing features. They are intentional exclusions. If a feature request falls into this list, the answer is no.

## Configuration

A single config file at `~/.config/zyouz/config.zon` holds all named layouts:

```zig
.{
    .prefix = .ctrl_s,               // global default (configurable)
    .layouts = .{
        .default = .{
            .direction = .horizontal,
            .children = .{
                .{
                    .command = .{ "nvim", "." },
                    .size = .{ .percent = 60 },
                    .mouse = .passthrough,
                },
                .{
                    .direction = .vertical,
                    .children = .{
                        .{
                            .command = .{ "npm", "run", "dev" },
                        },
                        .{
                            .command = .{ "npm", "run", "test:watch" },
                            .restart = .on_failure,
                        },
                    },
                },
            },
        },
        .rust_project = .{
            .prefix = .ctrl_t,       // per-layout override
            .direction = .horizontal,
            .children = .{ ... },
        },
    },
}
```

```bash
zyouz            # uses "default" layout (error if not found)
zyouz web-app    # uses "web-app" layout
```

## Decision Record

| Decision | Rationale |
|----------|-----------|
| No parent directory config discovery | Implicit behavior makes it hard to know which config is used. Explicit `~/.config/zyouz/config.zon` is always predictable. |
| Per-pane mouse passthrough instead of auto-detection | Auto-detection is unreliable and opaque. Declarative config makes behavior visible and predictable. |
| No detach/attach | Adds significant implementation complexity. Instant startup from config makes it unnecessary. |
| No tabs | Terminal emulators already provide tabs. Duplicating this feature adds no value. |
| No config hot-reload | Closing and reopening is simple and predictable. Hot-reload introduces state synchronization complexity. |
| Default mouse managed by zyouz | Most panes run log-output commands that benefit from zyouz-managed scrollback. TUI apps are the exception, explicitly marked with `.mouse = .passthrough`. |
| Single prefix key with transient command mode | Occupies exactly one keybinding. No global shortcuts that could conflict with pane programs. Command mode auto-exits to prevent mode confusion. |
| `Ctrl+S` as default prefix | XOFF flow control is disabled in virtually all modern terminals, making `Ctrl+S` effectively unused. "S" is mnemonic for "Switch". Configurable globally and per-layout for users who need `Ctrl+S` for other purposes. |
| Directional pane switching (arrow keys) instead of Tab cycling | Matches spatial layout of panes. More intuitive than sequential cycling when panes are arranged in a grid. |
| Quit requires prefix + Ctrl+Q (two steps) | Prevents accidental termination of all processes. No single key can kill the entire session. |
