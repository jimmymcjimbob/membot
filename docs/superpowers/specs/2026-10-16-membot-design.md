# MemBot design

Date: 2026-10-16
Status: approved by owner (2026-10-16)

## Intent

The owner runs many memory-heavy AI tools on one Mac (48 GB, Apple silicon, macOS 27): Claude Code, Codex and ComfyUI. These tools start many child processes (MCP servers, Python workers, node helpers). Some of these children continue to run after their session stops, and they hold memory and ports.

Activity Monitor does not help with this problem. The owner cannot see which root process owns a child without opening details. The owner cannot see the ports of a process. The owner cannot see if a process does useful work.

MemBot is a native Mac app with a menu bar item and a main window. It shows real-time memory and CPU, groups processes under their root, shows ports, marks idle processes as candidates for removal, and lets the owner send SIGTERM or SIGKILL.

Success: the owner looks at the menu bar panel and knows in a few seconds what uses the memory, and which leftover processes they can remove.

## Goals

- Real-time totals: used memory (value and percent), swap, total CPU.
- A process tree grouped by root, with summed memory and CPU for each root.
- The ports that each process listens on, and its open connections.
- A status for each process: active, idle (with a time), or candidate.
- A list of candidates for removal, each with the reasons.
- Manual SIGTERM and SIGKILL from the menu bar panel and the main window.

## Non-goals (this version)

- Automatic memory management. This is a future enhancement. The candidate logic must be a separate module so that a future manager can use it without changes to the UI.
- Signals to processes of other users or to system processes (no administrator rights, no privileged helper).
- History on disk. History stays in memory only.
- Code signing, notarization, distribution, auto-update.
- Notifications. (Not asked for. Easy to add later.)

## Anti-goals

- The app must not remove a process without a click from the owner.
- The app must not use much CPU itself. It is a monitor, so it must stay light.
- SIGKILL must not occur from one accidental click.

## Constraints

- Swift 6 and SwiftUI. Xcode 27 is installed. Target macOS 27 (the owner's Mac only). (Owner's choice of a native Mac window and menu bar; Swift/SwiftUI is my call.)
- No third-party dependencies. Use system APIs (libproc, sysctl, Mach host statistics) directly. Do not parse CLI output, with two exceptions given below: `launchctl list` and `top` for processes of other users.
- The app runs as the owner's user, without the App Sandbox. The sandbox blocks process inspection and signals to other processes. (My call.)
- The app shows every process, including processes of root and other users. It can send signals only to the owner's processes. For other processes, the SIGTERM and SIGKILL buttons are disabled with a tooltip that gives the reason.

## Menu bar

### Menu bar item

A small icon in the menu bar. (My call: a memory icon. The builder can add the memory percent as text next to it if it stays small.)

### Menu bar panel

Mockup: `.superpowers/brainstorm/13539-1792145375/content/menubar-v2.html` (approved, layout A).

From top to bottom:

1. **Memory line.** `38.2 / 48 GB · 80% · swap 4.1 GB`, with a bar under it.
2. **CPU line.** `23%`, with a bar under it.
3. **Bar colors.** Both bars change color with the percent: below 60% green, 60% to 85% amber, above 85% red. These limits are settings.
4. **Top memory (root + children).** One line for each root, sorted by summed memory, largest first. Each line shows the root name, the child count, and the summed memory. A click on a root opens its children under it (indented). Show the top 6 roots (my call).
5. **Candidates for removal.** A count in the heading. Each candidate shows its name, pid, memory, a short reason (for example `parent gone · 0% CPU for 2 h`), a **Term** button and a **Kill** button. Show the top 5 by memory, then `+ N more`. For a candidate tree, Term and Kill go to its highest idle process only.
6. **Footer.** `Open MemBot window…`

Term sends SIGTERM at once. Kill asks for confirmation first (owner accepted this). The confirmation names the process and pid.

## Main window

Mockup: `.superpowers/brainstorm/13539-1792145375/content/main-window-v2.html` (accepted).

The main task: select a process and look at its details.

### Toolbar

- A search field. It matches name, pid, port and folder.
- Filters: **All**, **Candidates** (with count), **AI tools**.
- The same memory and CPU bars as the menu bar panel.

"AI tools" (my call): roots whose name or command path matches `claude`, `codex`, `ComfyUI` or `Claude.app`. Keep this list as a setting.

### Process tree (left)

A table with an outline. Columns: Process, Memory, CPU, Ports, Status.

- Root lines show summed memory and CPU of the root and all its children, and the child count.
- `claude` and `codex` roots also show their working directory (for example `~/Code/membot`), because this tells the owner which project the session belongs to.
- Child lines show their own values and pid.
- Status shows a colored dot: green active, gray idle (with the idle time), amber candidate.
- Sort by memory, largest first, by default. Column headers can change the sort.

### Detail panel (right)

For the selected process:

- Name, pid, user, start time and age.
- A graph of memory and CPU for the last 10 minutes.
- Full command line and working directory.
- Family: its root, its parent, its children. If the parent is gone, show "parent gone" and the name of the last known root.
- Ports it listens on (address, port, TCP/UDP), and its open connections.
- The reasons for its status (each signal as one line).
- **Send SIGTERM** and **Send SIGKILL** buttons. SIGKILL asks for confirmation.

If the selected process stops, keep the panel with a "process ended" label until the owner selects a different process.

## The rule for a root

A strict parent tree does not work. `claude` has a shell as its parent, and the shell has the terminal app as its parent. Then all sessions show under the terminal app.

A process is a root when one of these conditions is true:

1. It is a Mac app: its executable is inside a `.app` bundle, and its parent is `launchd` (pid 1) or it is the top `.app` process in its chain. Helper processes inside the same bundle (for example `Brave Browser Helper (Renderer)`) belong under that app.
2. It is a command started from a **terminal shell**. A terminal shell is a shell (`zsh`, `bash`, `sh`, `fish`) whose parent is a terminal host: Terminal, iTerm2, Ghostty, Warp, WezTerm, Alacritty, kitty, Zed, VS Code, Cursor, the `tmux` server, or `sshd`. Each such command is its own root. Thus each `claude` or `codex` session is a separate root. Shells that a command starts itself (for example the `sh -c` of each Claude tool call, or `npx` for an MCP server) do **not** start a new root. They stay under the session root. (My call. The terminal host list is a setting.)
3. It is an **orphan**: its parent is `launchd` (pid 1), it belongs to the owner, rule 1 does not apply, and it is not a launchd job. It shows at the top level, labeled "no parent", with its last known root if MemBot saw it before.
4. Every other process with `launchd` as its parent (launch agents, daemons, XPC services outside an app) goes under one group root named **Background services**. These are started on purpose. They are not orphans.

The shell and the terminal app themselves stay in the tree under the terminal app root. They do not include the memory of the command roots under them.

### How to tell an orphan from a launchd job (my call)

The kernel does not tell them apart. MemBot uses two signals:

- MemBot saw the process with a different parent before (strongest signal).
- The pid is not in the owner's launchd job list. Read the list with `launchctl list` each 30 seconds. This is the one allowed exception to "do not parse CLI output", because no current public API gives this list.

Executables under `/System`, `/usr/libexec` and `/usr/sbin` are never orphans.

ComfyUI: when it runs as `python main.py` from a shell, rule 2 makes it a root. Show it with the name `ComfyUI` when the command line contains `ComfyUI` (my call).

### Memory of the last root

When a parent stops, macOS moves its children to `launchd`, and the original root is lost from the system. MemBot keeps a map from pid to its last known root while it runs. Remove an entry when its pid stops. (Pid reuse: also store the process start time and check it.)

## Status and candidate rules

Start values. All values are settings.

A process is **active** if, in any one minute of the last 15 minutes, one of these is true (my call on the exact measure):

- Its average CPU for that minute is 0.5% or more.
- It read or wrote more than 64 KB on disk in that minute.
- Its set of open connections changed in that minute.
- Any child is active.

The idle clock starts at the first sample that MemBot takes. Thus, after MemBot starts, no process can become a candidate for 15 minutes (5 minutes for an orphan). The candidates section shows `watching · 3 of 15 min` until then. To keep the clock warm, the settings have a **Launch at login** switch, on by default (my call, one call to `SMAppService.mainApp`).

A process is **idle** when it is not active. Show the time since it was last active.

A process is a **candidate** when all of these are true (owner approved):

- It belongs to the owner (MemBot can send it a signal).
- It is an orphan (rule 3), or it is in the tree of an AI tools root (see "AI tools" in the toolbar section).
- It is idle for 15 minutes or more and all its children are idle, or it is an orphan and idle for 5 minutes or more.

**One candidate for each idle tree.** When a full tree is idle, only its highest idle process is a candidate. It shows the summed memory of that tree. Its children do not show as separate candidates. Example: a stopped `claude` session is one candidate, not four.

The candidates list is sorted by memory, largest first. The menu bar panel shows the top 5 and a `+ N more` link that opens the main window with the Candidates filter.

Processes of other users get "active" or "idle" from CPU only. They are never candidates.

Each candidate keeps a list of reasons, for example:

- `0% CPU for 47 min`
- `parent gone`
- `no network or disk activity`
- `children idle`
- `listens on 24282, no connections` (from the socket data, no new signal)

The mockups also show "memory grows slowly, no work done". That text was only an example. There is no memory-growth signal in this version.

Signals:

- CPU: change in user and system CPU time between samples.
- Disk: change in bytes read and written (`proc_pid_rusage`).
- Network: macOS has no public API for per-process network bytes. Use a change in the set of open sockets and connection states as the signal (my call). If the builder finds a better public method, use it.

The status and candidate logic must be a separate module with no UI code. Its input is the process samples. Its output is a status and reasons for each process. A future automatic manager uses the same module.

## Data

- Memory per process: the physical footprint (`phys_footprint` from `proc_pid_rusage`). This is the same value that Activity Monitor shows in its Memory column.
- Used memory total: the same value as "Memory Used" in Activity Monitor (app memory + wired + compressed), from Mach host statistics.
- Swap: `vm.swapusage` from sysctl.
- CPU per process: from the change in CPU time. Total CPU: from host CPU load.
- Command line: `KERN_PROCARGS2` sysctl. Working directory: `proc_pidinfo` with `PROC_PIDVNODEPATHINFO`.
- Ports and connections: `proc_pidinfo` with `PROC_PIDLISTFDS`, then `proc_pidfdinfo` for socket info.
- **Processes of other users** (WindowServer, kernel_task, root daemons). Without administrator rights, libproc and sysctl give only name, path, parent pid and user for these processes. The probe on the owner's Mac confirmed this for 201 processes. MemBot gets their memory and CPU from `/usr/bin/top`, which has setuid root on macOS, so there is no password prompt (owner approved, option B). Run it each 5 seconds, for example `top -l 2 -s 1 -stats pid,mem,cpu` and use the second sample (the first sample has no CPU values). This is the second allowed exception to "do not parse CLI output". The command line, folder and ports of these processes show "not available". Do not fail.

## Refresh

- One sample each second while the panel or the main window is open.
- One sample each 5 seconds when both are closed. The candidate logic continues in the background so the count stays correct.
- Ports and command lines change rarely. The builder can read them less often to save CPU.
- History: 10 minutes for each process, in memory, removed when the process stops.

## Signals

- SIGTERM: no confirmation.
- SIGKILL: confirmation that names the process and pid.
- Errors (for example `EPERM` or the process already stopped) show as a short message near the button. They do not stop the app.
- A signal to a root goes only to that pid. (My call. A "signal the full tree" action is a possible later addition.)

## Settings

A small settings window:

- Bar color limits (60%, 85%).
- Idle time for a candidate (15 min) and for an orphan (5 min).
- CPU limit for "active" (0.5%).
- The "AI tools" name list.

## Left to the builder

- Project layout, module names, and the data model.
- How to read the system APIs from Swift.
- The icon and the visual details, as long as they follow the mockups.
- Test approach. The root rule and the candidate rules need unit tests with fixed sample data.
