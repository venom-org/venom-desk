# venom-desk

The TUI workspace/desktop, a client of venomx: layouts (BSP, master-stack, scrolling), workspaces, command palette, launcher, which-key, a sidebar rail (sessions, git, agents), notifications, and an inbox view of venom's approvals and questions.

Part of [Venom](https://venom.tools). Status: **alpha**; interfaces may still change. Documentation: [venom.tools](https://venom.tools).

Build from source with the Zig version in `.zigversion` (see [Build & test](#build--test)).

Licensed under the [MIT License](LICENSE). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Layout

The presentation-client core is a headless Zig module, `venom-desk` (`src/root.zig`):

| File | What |
|---|---|
| `src/desk.zig` | `Desk`: the client. Feeds daemon events into the shared mirror, keeps the per-client view, runs keys and local actions, draws a text frame |
| `src/shared.zig` | Mirror of the daemon's shared state: windows, pane tags, attention, segments, notifications, floats |
| `src/status.zig` | Status segments: built-in `venomx.*` segments, templates, the tray group and click targets through the `status` config's lists, matching `venomx attach`; the rail's rows, groups as lists |
| `src/keys.zig` | Leader, lock, key tables with layers, the popup's rows, placeholders, `exec` environment |
| `src/floats.zig` | Float specs, presets with fallback, per-client geometry |
| `src/inbox.zig` | Notification history and inbox |
| `src/palette.zig` | Palette from every reachable product's verb schema (`<tool> mcp`, `tools/list`) |
| `src/tiling.zig` | Tiling policies (BSP, master-stack, scrolling) that drive `pane.split` / `pane.place` |
| `src/client.zig` | venomx link: `Wire` (NDJSON socket) and `Fake` (tests) |

## The binary

`venom-desk` is one binary: daemon, CLI, MCP server and the full-screen client.

| File | What |
|---|---|
| `src/main.zig` | Entry point; the local commands `tile split`, `workspace list`, `workspace create` |
| `src/daemon.zig` | `venom-desk serve`: per-session tiling overrides (`tiling list/get/set/clear`), `palette list`, doctor; config `tiling.policy`, `palette.products` |
| `src/verbs.zon` | The verb schema the CLI, MCP, docs, completions and skill are generated from |
| `src/term/attach.zig` | `venom-desk attach --session <s>`: host TTY (raw mode, Kitty keyboard, SGR mouse, bracketed paste), the venomx link, the loop |
| `src/term/pane_stream.zig` | Emulating client for one pane stream |
| `src/term/render.zig` | The desk drawn with real cells: venom-term Vt content, theme roles, overlays |
| `src/term/exec.zig` | `exec` binding runner (no shell, null stdin, output discarded, no venomx token) |

```bash
venom-desk attach --session s0        # humans: in place of `venomx attach` (needs a terminal)
venom-desk serve                      # the daemon; attach and tile split use its tiling policy when it runs
venom-desk tiling set --session s0 --policy master-stack --json
venom-desk tile split --window w0 --json      # with your own VENOMX_TOKEN; never starts a daemon
venom-desk palette list --query split --json
venom-desk doctor --json
```

`attach` reads the leader from venomx's `keys` config, so both clients of a session share it. Keys: the leader, then `?` lists them; `:` opens the palette (type to filter, up/down, enter; required parameters are prompted), `i` the inbox, `d` detaches. A failed `exec` binding shows a notice in this client only. Desk actions that change venomx are local commands with the caller's own identity; the daemon never relays requests to venomx.

`test/probe.zig` is a headless test client used by `test/live.py`; `test/attach.py` runs `venom-desk attach` next to `venomx attach` on real PTYs.

## Build & test

Zig 0.17 (see `.zigversion`). `zig build` fetches `venom-std` and `venom-term` at the commits pinned in `build.zig.zon`; to build against local checkouts instead, add `--fork=../venom-std --fork=../venom-term` to any `zig build` command:

```bash
zig build                 # the binary, module tests and the test probe
zig build test            # unit tests, conformance, and the live cases (need ../venomx/zig-out/bin/venomx, else skipped)
zig build test-conformance
zig build test-attach -Dvenomx=/path/to/venomx
zig build test-live -Dvenomx=/path/to/venomx
zig fmt --check .
```
