<div align="center">

<img src=".claude-plugin/icon.png" alt="swarm-brake: a bee holding a stop sign while two smaller bees wait" width="160">

# swarm-brake

**Keep Claude Code and Codex agent swarms from freezing your Mac.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757.svg)](#install)
[![Codex CLI](https://img.shields.io/badge/Codex%20CLI-0.154%2B-black.svg)](#install)
[![macOS](https://img.shields.io/badge/tested%20on-macOS-lightgrey.svg)](#limits)
[![bash 3.2](https://img.shields.io/badge/bash-3.2-4EAA25.svg)](bin/swarm-brake)

[Install](#install) · [Before and after](#before-and-after) · [Settings](#settings) · [Full details](docs/DETAILS.md)

</div>

When Claude Code agents start heavy work in parallel (video renders, builds, headless Chrome), nothing checks whether your laptop has room. My 16 GB Mac froze because two subagents rendered Remotion frames at the same time, each frame opening a new headless Chrome. swarm-brake is a hook plugin that makes that kind of work wait its turn.

## What it does

- **Heavy commands wait for room.** Before a shell command runs, swarm-brake checks if it's heavy (Remotion, ffmpeg, headless Chrome, Playwright, Xcode or npm builds, Docker builds). If memory or CPU is low, or 2 heavy jobs are already running across all your sessions, it waits up to 90 s. If there's still no room, it blocks the command and tells the agent why.
- **Running jobs stay polite.** Jobs it lets through run at lower priority, so your apps stay responsive.
- **Leftover Chrome gets cleaned up.** When a session or subagent stops, it kills headless Chrome processes that renders left behind.
- **Everything is logged.** After a freeze, `swarm-brake report --at '2026-10-14 10:55'` shows which session started what.

Light commands (`ls`, `git`, `grep`) pass in about 16 ms with no checks. If swarm-brake itself fails for any reason, the command goes through, so a bug in it never blocks your agent.

## Before and after

8 heavy jobs started at once on a 16 GB, 10-core MacBook (500 MB and one busy core each, medians of 5 alternating rounds):

| | without | with (2 slots) |
| --- | --- | --- |
| jobs running at the same time | 8 | 2 |
| lowest free memory | 33% | 58% |
| time to start a tiny command, p95 | 9.1 ms | 2.2 ms |
| time to start a tiny command, worst | 27 ms | 4.8 ms |
| time until all 8 finish | 21.4 s | 55.4 s |

The cost is the last row: queued jobs finish later. Rerun it with `bash tests/bench.sh 5 8 500 10`. Method and ranges are in [the details](docs/DETAILS.md#before-and-after).

## Install

Claude Code:

```
/plugin marketplace add antivirusakash/swarm-brake
/plugin install swarm-brake@swarm-brake
```

Codex CLI (0.154+), then open `codex` once and trust the plugin's hooks:

```
codex plugin marketplace add antivirusakash/swarm-brake
codex plugin add swarm-brake@swarm-brake
```

Needs `jq` and bash 3.2+. Tested on macOS.

## Settings

Put `KEY=VALUE` lines in `~/.config/swarm-brake/config` (or set them as environment variables). The ones you'll touch:

| Setting | Default | What it does |
| --- | --- | --- |
| `SB_MODE` | `enforce` | `observe` only logs what it would have held. Good for your first few days |
| `SB_MAX_HEAVY` | `2` | Heavy jobs allowed at once, across all sessions |
| `SB_MEM_MIN` | `20` | Minimum % of memory that must be free |
| `SB_LOAD_MAX` | `1.5` | Maximum load per CPU core |
| `SB_DISABLE` | `0` | `1` turns it off. Handy for one big job you want to run anyway |

All settings are in [the details](docs/DETAILS.md#settings).

## Check it

Ask your agent to run these (Claude Code puts the plugin's `bin/` on its PATH), or run `bin/swarm-brake` from a clone of this repo.

```
$ swarm-brake status
mem 54% · load 2.67/10 · heavy 2/2 · BUSY
$ swarm-brake report        # how often heavy work started with no room, per mode
```

Logs stay on your machine and nothing is sent anywhere. Commands are stored as a short key (`npm run build`, `remotion still *`), without paths, file names or URLs. See [what is stored](docs/DETAILS.md#logs-and-the-report).

## Limits

- Tested on macOS only. Linux is written but untested.
- In Codex, cleanup works, but in my tests `codex exec` didn't fire the pre-command hook, so the gate may not run there yet.
- It only acts when a command starts. A render that's already running isn't slowed or stopped.

More in [the details](docs/DETAILS.md#limits), plus the [full story](docs/DETAILS.md#why-i-built-it) of the freezes that started this.

## License

MIT
