# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-03-13

Initial release.

### Added

- **Multi-pane terminal multiplexer** driven by a declarative ZON config file
- **Layout engine** with horizontal/vertical splits nested to arbitrary depth
- **Per-pane sizing**: equal, percentage, or fixed cell count
- **Configurable pane gap** between panes (default: 1 cell)
- **Process lifecycle management**: auto-restart on failure, exit status in borders
- **Graceful shutdown**: SIGTERM → SIGKILL with 500ms timeout
- **Input handling**: transparent keyboard passthrough with prefix key command mode
- **Configurable prefix key** (default: `Ctrl+S`), set via `prefix_key` in config
- **Directional focus switching** with arrow keys in command mode
- **Mouse support**: click to focus, drag borders to resize, scroll wheel for history
- **Per-pane mouse mode**: capture (default) or passthrough for TUI apps
- **Scrollback buffer** with history scrolling
- **VT100/ANSI terminal emulation**: CSI, SGR, ESC, OSC sequences
- **Screen compositing** with border rendering, junction detection, and active highlight
- **Named layouts**: define multiple layouts in one config, select by name on CLI
- **Per-pane labels** displayed in borders via `name` field
- **`ZYOUZ_CONFIG` env var** to override default config path
- **`--help` / `--version` CLI flags**
- **Specific error diagnostics** for config parsing failures
- **GitHub Actions CI** with tests on Linux/macOS, cross-compilation, and automated release
