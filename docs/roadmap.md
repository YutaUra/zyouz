# zyouz Roadmap

## Milestone 0: Foundation (current)

Project scaffold, dev environment, and philosophy documentation.

- [x] Nix flake + direnv dev environment
- [x] Zig project scaffold (`zig build` / `zig build test`)
- [x] Project philosophy document

---

## Milestone 1: Single Pane — PTY + Raw Terminal

**Goal:** Launch a single command in a PTY, display its output fullscreen, and forward keyboard input. Essentially a transparent terminal passthrough — the simplest thing that proves the PTY pipeline works end-to-end.

- [x] Enter raw mode / alternate screen on startup, restore on exit
- [x] Allocate a PTY and spawn a child process (e.g. `bash`)
- [x] Forward PTY output to the terminal (ANSI passthrough)
- [x] Forward keyboard input to the PTY
- [x] Handle SIGWINCH (terminal resize) and propagate to PTY
- [x] Clean shutdown: kill child process, restore terminal state
- [x] Ctrl+S prefix key detection (just exit for now)

**Exit criteria:** `zyouz` launches `bash` fullscreen, indistinguishable from running `bash` directly. Ctrl+S → Ctrl+Q exits cleanly.

---

## Milestone 2: Config Parser

**Goal:** Parse `~/.config/zyouz/config.zon` and produce an in-memory layout tree.

- [x] Define layout tree data structures (direction, children, command, size, mouse, restart)
- [x] Parse ZON config file at runtime using `std.zon`
- [x] Named layout lookup (`zyouz <name>`, default to `default`)
- [x] Validation: error on missing `default` layout when no name given
- [x] Validation: error on invalid config (missing command in leaf, etc.)

**Exit criteria:** `zyouz web-app` reads config, parses the named layout, prints the parsed tree to stdout.

---

## Milestone 3: Layout Engine

**Goal:** Given a layout tree and terminal dimensions, compute the exact rectangle (row, col, width, height) for each pane.

- [x] Recursive layout calculation: horizontal/vertical splits
- [x] Size modes: `percent`, `fixed`, and equal distribution (default)
- [x] Border allocation (1 cell between panes)
- [x] Recalculate on terminal resize (SIGWINCH)

**Exit criteria:** Given a config and terminal size, produces correct pane rectangles. Verified by unit tests with various layout configurations.

---

## Milestone 4: Multi-Pane Rendering

**Goal:** Draw multiple panes with borders, each showing its PTY output in the correct region.

- [x] Spawn a PTY per pane
- [x] Per-pane virtual terminal emulator (parse ANSI sequences, maintain screen buffer)
- [x] Render each pane's buffer to its computed rectangle
- [x] Draw borders between panes
- [x] Highlight active pane border
- [x] Composite all panes and flush to terminal

**Exit criteria:** A 2-pane horizontal split shows two commands running side-by-side with a visible border. Active pane is visually distinct.

---

## Milestone 5: Input Handling + Command Mode

**Goal:** Full keyboard input routing with the prefix key + transient command mode.

- [x] Default: all input forwarded to focused pane's PTY
- [x] Prefix key (Ctrl+S) enters command mode
- [x] Command mode: arrow keys switch focus directionally
- [x] Command mode: Ctrl+Q triggers clean shutdown
- [x] Command mode: any other key exits mode and forwards the key
- [x] Command mode visual indicator (border color/style change)
- [x] Configurable prefix key (from config)

**Exit criteria:** Can switch between panes using Ctrl+S → arrow keys. Ctrl+S → Ctrl+Q exits. All other keys pass through transparently.

---

## Milestone 6: Mouse Support

**Goal:** Mouse-driven pane interaction — click to focus, drag to resize, scroll for history.

- [x] Click on pane to focus
- [x] Mouse drag on border to resize panes (adjust ratios)
- [x] Mouse wheel scrollback for non-passthrough panes
- [x] Per-pane `.mouse = .passthrough` — forward all mouse events to PTY
- [x] Horizontal scroll support for non-passthrough panes

**Exit criteria:** Can click to switch panes, drag borders to resize, scroll through output history. Panes with `.mouse = .passthrough` correctly forward mouse events to programs like nvim.

---

## Milestone 7: Scrollback Buffer

**Goal:** Per-pane scrollback history for non-passthrough panes.

- [x] Ring buffer for scrollback lines (configurable max size)
- [x] Mouse wheel scroll navigates history
- [x] Scroll position indicator (e.g. "[42/1000]" or visual scrollbar)
- [x] Auto-scroll to bottom on new output (when already at bottom)
- [x] Horizontal scroll for wide output

**Exit criteria:** `npm run dev` output is scrollable. Scrolling up pauses auto-follow. New output snaps back to bottom when already at bottom.

---

## Milestone 8: Process Lifecycle

**Goal:** Handle command exit, auto-restart, and clean shutdown.

- [ ] Pane shows last output when command exits (stays as empty pane)
- [ ] Exit status display in pane border or footer
- [ ] `.restart = .on_failure` — auto-restart on non-zero exit
- [ ] Ctrl+S → Ctrl+Q kills all child processes and exits
- [ ] Graceful shutdown: SIGTERM first, SIGKILL after timeout

**Exit criteria:** Crashed commands auto-restart per config. Exited commands leave output visible. Clean shutdown kills all children.

---

## Milestone 9: Polish + First Release (v0.1.0)

**Goal:** Production-ready for personal use. Publishable as OSS.

- [ ] README.md with usage, installation, and config examples
- [ ] Error messages: helpful diagnostics for config errors, missing commands, etc.
- [ ] `--help` and `--version` CLI flags
- [ ] Cross-compile CI: Linux (x86_64, aarch64) + macOS (aarch64)
- [ ] Static binary releases on GitHub
- [ ] Dogfood: use zyouz daily for own development

**Exit criteria:** A stranger can `zyouz` from a downloaded binary with a config file and have it work.

---

## Post v0.1 — Future Considerations

These are not committed to. They exist as ideas worth exploring if demand arises.

- **`-c` flag**: specify config file path (override `~/.config/zyouz/config.zon`)
- **Per-pane environment variables**: `.env = .{ "PORT", "3000" }`
- **Pane name labels**: display a name on the pane border
- **Maximize toggle**: temporarily expand one pane to fullscreen, restore with prefix key
- **Shell completions**: Bash/Zsh/Fish completions for layout names
- **Nix package / Homebrew formula**: easy installation
- **Configurable scrollback size**: per-pane `.scrollback = 10000`
- **Color theme**: configurable border colors and command mode indicator style
