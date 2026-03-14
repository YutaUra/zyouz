# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-03-14

### Added

- **OSC 22 cursor shape on pane borders**: mouse cursor changes to resize arrows (`ew-resize`/`ns-resize`) when hovering over draggable borders, and `grab` at junction points
- **Junction drag support**: T-junctions and cross-intersections now support dragging in both directions — the drag axis is determined by the initial mouse movement
- **Any-event mouse tracking** (`?1003h`): enables cursor shape feedback on hover without requiring a button press
- **Home Manager module** for declarative NixOS/home-manager configuration
- **`.motion` mouse event kind** in MouseParser for button-less mouse movement

### Changed

- **Improved rendering pipeline** with better terminal compatibility
- **VT parser generalized CSI prefix handling** to support Kitty keyboard protocol sequences (`>`, `<`, `=` prefixes) without leaking characters

## [0.1.1] - 2026-03-13

### Added

- **Nix flake package**: `nix profile install github:YutaUra/zyouz` or `nix run github:YutaUra/zyouz`
- **Homebrew formula**: `brew install YutaUra/tap/zyouz`
- **Intel Mac (x86_64-macos) build** in CI release artifacts
- **Nix CI workflow** with Cachix binary cache
- **Homebrew auto-update workflow** for homebrew-tap

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
