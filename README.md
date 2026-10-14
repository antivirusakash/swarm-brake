<div align="center">

<img src=".claude-plugin/icon.png" alt="swarm-brake: a bee holding a stop sign while two smaller bees wait" width="160">

# swarm-brake

**Keep Claude Code and Codex agent swarms from freezing your Mac.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757.svg)](#install)
[![Codex CLI](https://img.shields.io/badge/Codex%20CLI-0.154%2B-black.svg)](#install)
[![macOS](https://img.shields.io/badge/tested%20on-macOS-lightgrey.svg)](#status)
[![bash 3.2](https://img.shields.io/badge/bash-3.2-4EAA25.svg)](bin/swarm-brake)

[Install](#install) · [Before and after](#before-and-after) · [Settings](#settings) · [Logs and the report](#logs-and-the-report)

</div>

Your Claude Code agents froze your Mac again. swarm-brake is a hook plugin for Claude Code and Codex CLI that makes heavy jobs (video renders, builds, headless Chrome) wait their turn when memory or CPU runs low, cleans up the Chrome processes renders leave behind, and logs every heavy job so you can see what froze the machine.

Agents decide on their own to render a video, run a build or start two subagents in parallel. None of them checks whether the laptop has room first. swarm-brake checks for them.

## Why I built it

I run a lot of Claude Code sessions on a 16 GB MacBook (10 cores). Over one week the machine kept falling over, and every time I traced it back to the same thing: agents starting heavy work with no idea what else was running.

**2026-10-08.** My external SSD started returning `EPERM` to whole terminal trees. The cause turned out to be memory: swap was at 11.8 of 13 GB, and macOS's privacy daemon (`tccd`) was answering too late or getting killed by jetsam, so every file check failed closed. There were 20 `claude` processes (3.6 GB, many idle for 8+ days), each with its own 3 MCP servers: 57 node processes. Killing the idle sessions brought swap down to 6.4 GB.

**2026-10-13, 10:53 to 10:54.** Four node processes died in two minutes with V8 `FatalProcessOutOfMemory`.

**2026-10-14, about 10:55.** The Mac hung while I was working in a light session (a few `curl` calls and a 0.4 s rate-limited Python loop). That session was a bystander. In another session, an agent had started two background subagents to re-render frames of a Remotion video in parallel. Every frame was a fresh `remotion still` call, and every call started a new headless Chrome with a 4 GB GPU memory budget. Two of those Chrome trees were left orphaned (parent pid 1) after their renders ended and kept running. At the same time: 11 open Claude sessions with 44 MCP node processes, a browser using 3.5 GB, swap at 5.4 of 7 GB, and a 5-minute load average of 26 on 10 cores.

My existing hooks managed context size and planning. Nothing looked at the machine.

## What it does

| Hook | What happens |
| --- | --- |
| `PreToolUse` on shell commands | If the command runs a heavy program (Remotion, ffmpeg, headless Chrome, Playwright, Xcode builds, `npm run build`, Docker builds and similar), swarm-brake checks free memory, kernel memory pressure, load per core and how many heavy jobs already run across **all** sessions. If there is room, the command runs unchanged and a watcher lowers it to `nice 10` about half a second after it starts, so your UI stays responsive. If not, it waits (90 s by default, checking every 5 s), then denies the command with a reason the agent can act on: wait, run jobs one at a time, or ask you. |
| `PostToolUse`, `PostToolUseFailure` | Frees the slot that tool call held, 3 s later (time for the watcher to renice a job the call started in the background). |
| `Stop`, `SubagentStop`, `SessionEnd` | Kills orphaned headless-browser trees (parent pid 1, older than 2 minutes) that renders left behind. |

Light commands (`ls`, `git`, `cat .remotion/x.log`, `grep -r ffmpeg src`) are never checked. Matching looks at the program being run, after stripping `npx`, `node`, `env`, `bash -c` and `VAR=value` prefixes, so paths and arguments that mention a heavy tool do not count.

When an agent hits the limit, it sees this:

```
swarm-brake held this command for 90s and the machine still has no room: memory available 5% (min 20%); 2 heavy jobs already running (max 2). Do not retry it right away. Wait for the running heavy jobs to finish, run the work one job at a time (lower concurrency, fewer parallel agents), or ask the user.
```

The message does not mention a way around the guard. Yours is the config file, which is read on every call: add `SB_DISABLE=1` to `~/.config/swarm-brake/config` and remove it when the job is done.

Any failure inside swarm-brake lets the command through: bad input, missing `jq`, unreadable metrics, a lock left by a dead process (broken at once; the gate stops waiting for the lock after 15 s), even a syntax error in the script itself (`hooks.json` ends every hook with `|| true`). A bug in the guard never blocks your agent.

## Before and after

Eight agent jobs start at the same moment, the way parallel subagents fire off renders. Each job holds 500 MB of random (incompressible) memory and keeps one core busy for 10 s. Run on my 16 GB, 10-core MacBook, five rounds each, alternating, medians:

| 8 heavy jobs at once | without swarm-brake | with swarm-brake (2 slots) |
| --- | --- | --- |
| jobs running at the same time | 8 | 2 |
| lowest free memory during the run | 33% (range 30 to 42) | 58% (52 to 59) |
| time to start a tiny command, p95 | 9.1 ms (7.5 to 10.5) | 2.2 ms (2.1 to 3.1) |
| time to start a tiny command, worst | 27 ms (16 to 78) | 4.8 ms (3.7 to 27) |
| time until all 8 jobs finish | 21.4 s | 55.4 s |
| jobs denied | 0 | 0 |

The tiny command is `/usr/bin/true`, timed every 200 ms as a stand-in for how the rest of the machine feels. The cost is real: queued jobs finish later, about 2.6 times later here. The test is sized to stay safe (4 GB total, swap already near full on my machine), so it shows the headroom swarm-brake keeps, not a full freeze. Only the slot limit acted in this run; the memory and load checks were pinned to "room". Reproduce it with `bash tests/bench.sh 5 8 500 10`.

## Start in observe mode

The default limits (20% memory, 1.5 load per core, 2 heavy jobs) are a starting point, not something measured on your machine. Run a few days with

```
SB_MODE=observe
```

in `~/.config/swarm-brake/config`. Nothing is held, denied or reniced. Every heavy command is still recorded with the readings at that moment and what the gate would have done, and its job is followed to the end for duration and peak memory. After a few days, `swarm-brake report` shows how often heavy work started on a machine that had no room for it. Set the limits from that, then remove the line and compare the two columns of the report a week later (see [Logs and the report](#logs-and-the-report)).

## Install

Claude Code:

```
/plugin marketplace add antivirusakash/swarm-brake
/plugin install swarm-brake@swarm-brake
```

Codex CLI (0.154+):

```
codex plugin marketplace add antivirusakash/swarm-brake
codex plugin add swarm-brake@swarm-brake
```

Then start `codex` once in the TUI and trust the plugin's hooks when asked. Codex skips command hooks it has not reviewed.

Requirements: bash 3.2+, `jq`, macOS (Linux untested). Without `jq` the gate lets every command through and only the cleanup runs.

## Settings

Set environment variables, or put `KEY=VALUE` lines in `~/.config/swarm-brake/config`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SB_MAX_HEAVY` | `2` | Heavy commands allowed at once, across all sessions |
| `SB_MEM_MIN` | `20` | Minimum % memory available. macOS: `kern.memorystatus_level`; Linux: `MemAvailable` |
| `SB_LOAD_MAX` | `1.5` | Maximum 1-minute load average per core |
| `SB_SWAP_MAX` | `0` (off) | Maximum % swap used. Off by default because macOS grows swap on demand, so the % is noisy |
| `SB_WAIT` / `SB_POLL` | `90` / `5` | Seconds to wait for room, and seconds between checks. Capped at 90 and 10 so the gate always answers inside the 120 s hook timeout |
| `SB_NICE` | `10` | Nice level for heavy commands; `0` turns it off |
| `SB_QOS` | empty | `background` also runs heavy commands at macOS background QoS (much slower, very quiet) |
| `SB_HEAVY_REGEX` | see script | Programs that count as heavy |
| `SB_REAP_REGEX` / `SB_REAP_AGE` | headless Chrome / `120` | Which orphans to kill, and their minimum age in seconds |
| `SB_LEASE` | `120` | Longest a slot is held when no hook or watcher releases it: a command you rejected at the permission prompt, or a job whose process the watcher cannot match |
| `SB_MODE` | `enforce` | `observe` logs what would be held or denied and blocks nothing |
| `SB_DISABLE` | `0` | `1` turns the gate and reaper off. Machine readings are still taken when a shell call finishes, so the report has a third column to compare |
| `SB_KEEP_DAYS` | `30` | Days of event files kept |
| `SB_LOG_CMD` | `key` | `key` stores the program and up to two subcommand words before the first flag (`npm run build`, `remotion still *`); `off` stores the program name only |
| `SB_TICK` | `15` | Seconds between the watcher's checks on a running job, after its first 10 s |

Check the machine the way the gate sees it:

```
$ bin/swarm-brake status
mem 54% · load 2.67/10 · heavy 2/2 · BUSY
$ bin/swarm-brake classify 'npx remotion still Foo out.png'
heavy
```

## Logs and the report

Every heavy command writes one line to `~/.local/state/swarm-brake/events/<date>.log`. Light commands write nothing. Each line is `key=value` pairs:

```
ts=1791955018 t=10:46:58 v=1 ev=gate mode=observe call=toolu_A sess=3c079921-aaaa agent=- where=marketing-os#9af1 key=remotion+still+* verdict=room why=- wait=0 mem=31 press=2 load=14.2 ncpu=10 swap=55 heavy=1
```

| Event | Written by | What it records |
| --- | --- | --- |
| `gate` | the gate, once per heavy call | session, subagent, folder, command key, verdict (`room`, `held`, `denied`, `would_hold`, `failopen`), the reasons, seconds waited, readings |
| `start` / `end` | the watcher | the job's pid; at the end its duration, peak memory of the whole process tree, process count |
| `orphan` | the watcher, when the job exits | child processes it left behind at pid 1, while they are still alive |
| `done` | the release hook | whether the tool call succeeded |
| `pulse` | the first gate, finished shell call, watcher check or Stop hook in a minute (one per minute machine-wide, taken in the background) | memory, pressure, load, swap, heavy jobs, heavy processes no gate saw, Claude and node process counts |
| `stall` | the watcher | a check that ran 20 s or more late, not counting sleep (lid closed) |
| `turn` / `reap` | the Stop hooks | which sessions were active; what the reaper killed and how much memory it freed |

`swarm-brake report` reads them. With no arguments it covers 14 days, one column per mode:

```
$ swarm-brake report
                                             observe                enforce
  heavy calls gated                          212                    187
  heavy starts while there was no room       41 (19%)               3 (2%)
  held, then ran                             -                      29
    wait median/p90                          -                      18s/71s
  denied                                     -                      7 (retry 2)
  distress minutes                           38 (2.1/h)             9 (0.6/h)
  orphan trees reaped                        6, 9120 MB (5 traced)  2, 1400 MB (2 traced)
```

(Shortened; the numbers are an example.) "Heavy starts while there was no room" is what the gate controls. Distress minutes (memory under 10% or critical pressure, or load over 2.5 per core) are the outcome you care about, but they also move with work the gate never sees: browsers, MCP servers, idle sessions. The report prints that caveat at the bottom. It does not claim the plugin caused a change.

For a hang or a slow spell, ask for the minutes around it:

```
$ swarm-brake report --at '2026-10-14 10:55'
machine, one reading a minute while agents were active
time       mem  pressure  load   swap  heavy  ungated  claude  node
10:53:00    6%  critical  2.64    77%      4        2      11    44

heavy calls in the window
start     end          dur     peak  command                    session   where                  gate said
10:46:59  10:55:40    521s  3994 MB  remotion+still+*           3c079921  marketing-os#9af1      room
10:47:03  running?       -        -  remotion+still+*           3c079921  marketing-os#9af1      would_hold (heavy,load)

orphans reaped
10:57:12  2310 MB freed, roots 51234 left by toolu_A (session 3c079921, marketing-os#9af1)

sessions present that started no heavy work
  9be1d2aa  map-csv#11c0
```

That is the hang that started this project, replayed from a test fixture: the renders came from marketing-os, and map-csv, the session I blamed first, was only present. `--window MIN` widens the span (default 15 minutes either side). Readings are taken only while agents run shell commands, so a gap usually means nobody was running any. A gap while a job was being followed means the machine froze, and the watcher marks a check that ran 20 s or more late as a stall.

What is stored, and what is not: logs stay on your machine, files are created readable by you only, and nothing is sent anywhere. The folder is stored as its last name plus a 4-character checksum of the full path. The command is reduced to a key: the program, then at most two words before the first flag, and any of those words that is not a plain lowercase subcommand (a path, a file name, a URL, an assignment, anything with two or more digits or over 16 characters) becomes `*`. `ffmpeg -i /Users/you/Clients/raw.mov out.mp4` is stored as `ffmpeg`, and `npx remotion still Launch.tsx` as `remotion still *`. Set `SB_LOG_CMD=off` to keep the program name only. Fake readings (`SB_FAKE_*`, used by the tests) are only read from the environment, never from the config file. A line over 400 bytes is dropped; orphan pid lists are cut to 20 so they fit. Files older than `SB_KEEP_DAYS` are deleted once a day. A minute's reading is about 130 bytes, so 30 days of them come to under 6 MB.

## How the slot count works

A heavy job is a heavy process with no heavy ancestor in `ps`, so `npm run build` and the `vite build` it starts count once. swarm-brake never rewrites the command, so your permission rules (`Bash(npm run build:*)`) match it exactly as the agent wrote it.

Between the gate saying yes and the job showing up in `ps` (you may still be reading the permission prompt), the slot is held by a lease file in `~/.local/state/swarm-brake/leases`, named after the tool call. The lease goes away when the first of these happens:

- 3 s after the tool call ends (`PostToolUse` or `PostToolUseFailure`), which also covers commands that exit at once, like `ffmpeg -version`
- a background watcher sees the job's process start under that agent, running one of the command's own heavy programs; it lowers the job's priority and hands the count over to `ps`
- the agent exits
- `SB_LEASE` seconds pass

Two gates checking in the same instant are serialized with a lock: a symlink whose target text is the holder's pid and start time, created atomically. A lock is broken when its holder has died or it is older than 30 s; a holder confirms it still holds the lock before it grants a slot, and checks again if not.

## Tests

| | What it does | Result |
| --- | --- | --- |
| `bash tests/run.sh` | 142 checks with faked readings: classifier, gate, leases, watcher, release hook, lock, settings, fail-open, reaper on real orphan processes, events, redaction, the report against a fixture of the 10:55 hang | 142 passed, 3 runs in a row |
| `bash tests/stress.sh` | 8 concurrent gates race for 2 slots with the real `ps` count, each job a 6 s fake render; then 16 gates race for 1 slot, 5 times | max 2 alive at once, 0 denied, 25 s (ideal 24 s); exactly 1 let through in 5 of 5 races |
| `bash tests/bench.sh [rounds] [jobs] [mb] [secs]` | The before and after table above: N jobs at once, with and without the gate, alternating | see [Before and after](#before-and-after) |
| `bash tests/e2e.sh` | Real `claude -p` sessions with the plugin loaded (costs a few cents of Haiku) | 11 of 11: deny stops the agent, an allowed command runs at nice 10, parallel background renders queue for one slot, Stop reaps an orphan, an allow rule still matches in normal permission mode, a command that exits at once frees its slot |

Testing and three review passes by agents that did not write the code caught these bugs before release. The stress test found a job counted twice (lease plus process), so 2 slots behaved like 1, and a window between two `ps` calls that let a third job in. An early version prefixed the command with `renice -p $$`; in normal permission mode Claude Code refused it ("A variable in this command can't be checked before it runs") and allow rules stopped matching. The e2e suite now covers that case. A later review found that a command finishing in under half a second held its slot for 5 minutes, and that a watcher could hand a gated command's slot to an unrelated browser started by an MCP server; the release hook and the program check fixed both. A fourth pass found that the release hook beat the watcher to background jobs (6 of 8 ran at normal priority) and that 16 gates racing for 1 slot let 2 through in 2 of 8 runs; the 3 s release window and an atomic symlink lock fixed both.

## Status

| | Claude Code | Codex CLI 0.154 |
| --- | --- | --- |
| Orphan cleanup on Stop | tested end to end | tested end to end |
| Gate (wait, deny, renice) | tested end to end | not confirmed: in my tests `codex exec` did not fire `PreToolUse` for shell calls, even with no matcher and hook trust bypassed. The gate reads both `command` and `cmd`, so it should work once Codex fires the hook. Reports welcome |
| Slot release on `PostToolUse` | tested end to end | not confirmed. Without it, a slot is freed by the watcher or after `SB_LEASE` |

## Limits

- A hook only runs when a command starts. A render that is already running is not slowed further or stopped.
- Priority is lowered on the job's process tree when the watcher finds it, about half a second after start (2 s if the job starts more than 20 s after the gate said yes). Children it starts later inherit the lower priority. A job that finishes before then runs at normal priority.
- A job whose process runs under a launcher with a different name (Yarn Berry's `yarn-4.x.cjs`, corepack's `pnpm.cjs`) is not matched by the watcher: it counts twice (lease and process) for up to `SB_LEASE` and is not reniced. `./gradlew` runs as `java` and is not counted in `ps` at all.
- A command you reject at the permission prompt holds its slot until `SB_LEASE` (120 s) runs out, since I have not found a hook that fires when you reject a call.
- One command that starts several heavy children (`npm run render-all` spawning 4 ffmpeg) counts as one job.
- Heavy work that agents start through other tools (MCP servers, a browser tool) counts toward the slots, but only shell commands are gated.
- The reaper only kills processes whose parent is pid 1 and whose command matches `SB_REAP_REGEX`. If you run headless Chrome under `nohup` on purpose, narrow the pattern.
- Tested on macOS 27 with bash 3.2. Linux code paths (`/proc/meminfo`, `nproc`) are written but not tested yet. Windows is not supported.

## License

MIT
