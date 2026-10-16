# MemBot

A native macOS menu bar app that shows where your memory goes when you run AI tools such as Claude Code, Codex and ComfyUI, and finds the leftover processes that you can remove.

Activity Monitor shows a flat list of processes. MemBot shows which session owns each process, which ports it holds, and whether it does any work. It marks idle leftovers as candidates for removal. You stop them with one click.

## Why

AI tools start many child processes: MCP servers, Python workers, language servers, node helpers. When a session stops, some of these children continue to run. They hold memory and ports, and Activity Monitor cannot tell you which session started them.

MemBot answers three questions quickly:

- What uses my memory, grouped by the app or session that owns it?
- Which processes are leftovers that do nothing?
- Which ports does each process hold?

## Features

### Menu bar panel

- Memory used (value and percent of total), swap, and total CPU, each with a coloured bar: green below 60%, amber from 60% to 85%, red above 85%.
- The six roots that use the most memory, with the memory of all their children added. Click a root to see its children.
- Candidates for removal, sorted by memory, each with the reason (for example `parent gone · CPU below 0.5% for 2 h`) and **Term** and **Kill** buttons.
- Links to the main window, Settings and Quit.

### Main window

- A process tree with columns for memory, CPU, ports and status (active, idle with a time, or candidate).
- Each `claude` and `codex` session is its own root and shows its project folder, so you can see which project a session belongs to.
- Search by name, pid, port or folder. Filter by **All**, **Candidates** or **AI tools**.
- A detail panel for the selected process:
  - memory and CPU graphs for the last 10 minutes
  - the full command line and the working folder
  - root, parent and children (for an orphan: "parent gone" and its last known root)
  - listening ports and open connections
  - the reasons for its status
  - **Send SIGTERM** and **Send SIGKILL** buttons

### Safety

- MemBot never stops a process without a click from you.
- **Kill** (SIGKILL) always asks for confirmation and names the process and pid. **Term** (SIGTERM) does not ask.
- Before it sends a signal, MemBot checks the start time of the process. If the pid now belongs to a different process, MemBot does not send the signal.
- MemBot refuses pid 0 and negative pids, which would signal a process group.
- MemBot runs as your user, without administrator rights. It can only signal your own processes. For other processes the buttons are disabled.

## How it works

### Roots

A strict parent tree puts every terminal session under the terminal app. MemBot groups processes under a **root** instead:

1. **App:** a process inside an `.app` bundle, at the top of its chain. Helpers inside the same bundle stay under the app (for example all `Brave Browser Helper` processes under Brave Browser).
2. **Command:** a command started from a terminal shell, that is a shell whose parent is a terminal host (Terminal, iTerm2, Ghostty, Warp, WezTerm, Alacritty, kitty, Zed, VS Code, Cursor, `tmux`, `herdr` or `sshd`). Each `claude` or `codex` session is a separate root. Shells that a tool starts itself (for example the `sh -c` of each tool call) stay under the session.
3. **Orphan:** a process of yours whose parent is `launchd`, that is not a launchd job and not a system binary. It shows as "no parent", with its last known root when MemBot saw it before.
4. **Background services:** every other child of `launchd` (launch agents, daemons, XPC services).

Command roots are named from the command line, so a versioned binary such as `~/.local/share/claude/versions/2.1.301` shows as `claude`, and `node …/bin/codex` shows as `codex`.

### Active, idle and candidate

MemBot looks at each process in one-minute buckets. A process is **active** when, in a bucket, any of these is true:

- its average CPU is 0.5% or more
- it read or wrote more than 64 KB on disk
- its set of open connections changed
- one of its children is active

A process that is not active is **idle**. A process is a **candidate** for removal when all of these are true:

- it belongs to you
- it is an orphan, or it is in the tree of an AI tool root (`claude`, `codex`, `ComfyUI`, `Claude.app` by default)
- it is idle for 15 minutes (5 minutes for an orphan), and all its children are idle

When a whole tree is idle, only its highest process is a candidate, with the memory of the tree. A stopped session is one candidate, not one for each child.

The idle clock starts when MemBot starts, so for the first 15 minutes the panel shows `watching · N of 15 min`. Orphans can show after 5 minutes. After the Mac sleeps for more than 2 minutes, the clock starts again, so that sleep does not make every process look idle. Leave **Launch at login** on to keep the clock running.

### Data sources

MemBot reads the system directly through `libproc`, `sysctl` and Mach host statistics. It does not parse `ps` or `lsof`.

| Value | Source |
| --- | --- |
| Memory per process | `phys_footprint` from `proc_pid_rusage` (the same value as Activity Monitor's Memory column) |
| CPU per process | change in CPU time between samples |
| Memory used | app memory + wired + compressed, from `host_statistics64` |
| Swap | `vm.swapusage` |
| Command line, folder | `KERN_PROCARGS2`, `PROC_PIDVNODEPATHINFO` |
| Ports and connections | `PROC_PIDLISTFDS` and `PROC_PIDFDSOCKETINFO` |
| Launchd jobs | `launchctl list`, every 30 s |
| Processes of other users | `/usr/bin/top`, every 5 s, only while a MemBot window or the panel is open |

Without administrator rights, macOS gives no memory or CPU data for processes of other users (WindowServer, `kernel_task`, root daemons). `top` has these rights already, so MemBot uses it for their memory and CPU. Their command line, folder and ports show as "not available".

MemBot samples once a second while the panel or the main window is open, and once every 5 seconds otherwise. History stays in memory only.

## Requirements

- macOS 27 or later (tested on Apple silicon only)
- Xcode 27 (Swift 6.2 tools or later) to build

## Build and run

```bash
git clone <this repository>
cd membot
bash scripts/build-app.sh
open build/MemBot.app
```

`scripts/build-app.sh` builds a release binary, wraps it in `build/MemBot.app` and signs it ad hoc. To keep MemBot, move `MemBot.app` to `/Applications`.

MemBot has no Dock icon. Click the memory chip icon in the menu bar to open the panel. To quit, use **Quit MemBot** in the panel.

You can also open `Package.swift` in Xcode and run the `MemBot` scheme.

### Launch at login

**Launch at login** is on by default. MemBot registers itself with `SMAppService` on first launch. To stop this, turn the switch off in Settings, or remove MemBot in **System Settings › General › Login Items**. If registration fails (for example when you run the binary outside an app bundle), Settings shows the error.

## Settings

| Setting | Default |
| --- | --- |
| Warn at (memory and CPU bars) | 60% |
| Critical at | 85% |
| Active above (CPU, minute average) | 0.5% |
| Candidate after idle | 15 min |
| Orphan after idle | 5 min |
| AI tool names | `claude`, `codex`, `ComfyUI`, `Claude.app` |
| Terminal hosts | Terminal, iTerm, iTerm2, Ghostty, Warp, WezTerm, Alacritty, kitty, Zed, Visual Studio Code, Cursor, tmux, herdr, sshd, sshd-session |
| Launch at login | on |

If you use another terminal or multiplexer, add its name to **Terminal hosts** so that commands started in it become their own roots.

## Project layout

```
Sources/
  MemBotCore/     Pure logic, no OS calls: models, parsers, the root rule,
                  activity tracking and candidates, history, search
  MemBotSystem/   OS access: libproc/sysctl/Mach reader, top and launchctl,
                  signals, and the Monitor actor that turns samples into state
  MemBot/         SwiftUI app: menu bar panel, main window, settings
Tests/
  MemBotCoreTests/    Unit tests with fixed sample data
  MemBotSystemTests/  Tests against the live OS and the Monitor with fake sources
Resources/Info.plist
scripts/build-app.sh
```

`MemBotCore` and `MemBotSystem` contain no UI code. A future automatic memory manager can use `Monitor` and the candidate engine directly.

## Tests

```bash
swift test
```

The core tests use fixed process data and cover the root rule, candidates, sleep gaps, pid reuse and the parsers. The system tests run against the live OS (the current process, `launchd`, a local TCP listener) and drive the `Monitor` with fake sources and a fake clock.

## Limits

- No automatic removal. MemBot only recommends candidates. Automatic memory management is planned.
- No signals to processes of other users or system processes, and no privileged helper.
- macOS has no public API for network bytes per process, so "network activity" means a change in the set of open connections.
- Signing is ad hoc. There is no notarized build or auto-update.
- History is not saved to disk.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before you open a pull request, and keep `MemBotCore` free of OS and UI calls.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <https://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <https://opensource.org/licenses/MIT>)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
