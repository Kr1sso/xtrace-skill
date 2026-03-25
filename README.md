# xtrace — Command-line CPU Profiling for macOS

Unix-style profiling tools for macOS Instruments. Record traces, analyze hotspots, generate flamegraphs — all from the terminal, all composable with pipes.

```bash
# Profile any command. Just prefix it.
xtrace ./my_app --benchmark

# Pipe to a flamegraph
xtrace ./my_app | trace-flamegraph - --open

# Build → profile → interactive analysis
cmake --build . && xtrace ./my_app | trace-speedscope -
```

## Why

Apple's Instruments is powerful but GUI-only. `xctrace` exists but is raw and hard to use. There's no good way to go from "I have a binary" to "here are my hotspots" in one command.

**xtrace** bridges this gap:

- **`xtrace`** — prefix any command to profile it, like `time`
- **All tools pipe together** — record → analyze → visualize in one pipeline
- **Multiple output formats** — text summaries for terminals/LLMs, JSON for scripts, SVG flamegraphs for humans, speedscope for deep analysis
- **Time-resolved analysis** — don't just see averages, see how CPU usage changes over time with sparklines, confidence indicators, and automatic phase detection
- **Before/after comparison** — differential text diffs and red/blue flamegraphs
- **Zero external dependencies for core analysis** — Python stdlib only. Optional inferno/speedscope for best visualizations.

## Install

### Quick Install

```bash
git clone https://github.com/YOUR_USER/xtrace-skill.git
cd xtrace-skill
./install.sh
```

This symlinks all scripts to `~/.local/bin` (or the first writable PATH directory), and installs as a pi skill if pi is detected.

### Manual Install

```bash
# Add to your shell profile (~/.zshrc, ~/.bashrc)
export PATH="$HOME/Work/xtrace-skill/scripts:$PATH"
```

### Install optional tools (recommended)

```bash
cargo install inferno        # Best flamegraph SVGs (click-to-zoom, search, hover)
npm install -g speedscope    # Interactive web UI (sandwich view, time-ordered, zoom)
```

### Verify

```bash
./scripts/trace-check.sh     # check environment
./test.sh                    # run 37 end-to-end tests
```

### Requirements

- **macOS** with Xcode or Command Line Tools (`xcode-select --install`)
- **Python 3.8+** (ships with macOS)
- **Apple Silicon or Intel** (Processor Trace requires Apple Silicon + Developer Tools enabled)

## Quick Start

```bash
# Profile a command for 10 seconds
xtrace -d 10 ./my_app

# The summary prints to stderr, the trace path prints to stdout.
# Pipe to any visualization tool:
xtrace ./my_app | trace-flamegraph - --open      # flamegraph in browser
xtrace ./my_app | trace-speedscope -             # interactive analysis
xtrace ./my_app | trace-analyze.py summary -     # text summary
```

## Tools

### `xtrace` — The Main Entry Point

Works like `time`. Prefix any command to profile it.

```bash
xtrace [options] command [args...]
```

| Option | Description |
|---|---|
| `-d DURATION` | Recording time limit (default: `30s`) |
| `-t TEMPLATE` | Instruments template (default: `Time Profiler`) |
| `-o PATH` | Output `.trace` file path (default: auto in `/tmp`) |
| `--no-summary` | Skip the auto-printed summary |
| `--top N` | Functions to show in summary (default: `15`) |

**Output:** Summary to stderr, trace file path to stdout.

```bash
# Save the trace path for later use
TRACE=$(xtrace -d 10 ./my_app)
trace-analyze.py calltree "$TRACE" --depth 15
trace-flamegraph.sh "$TRACE" -w 2400 --open

# Build → profile in one line
make -j8 && xtrace ./build/app | trace-flamegraph - --open
```

---

### `trace-record.sh` — Full Recording Control

When you need more than `xtrace` offers: attach to processes, system-wide tracing, environment variables, different templates.

```bash
trace-record.sh [options] [-- command args...]
```

| Option | Description |
|---|---|
| `-t, --template NAME` | Template (default: `Time Profiler`) |
| `-d, --duration SEC` | Duration: `10`, `10s`, `500ms`, `2m` (default: `10s`) |
| `-o, --output PATH` | Output path (default: auto-timestamped) |
| `-p, --pid PID` | Attach to running process by PID |
| `-n, --name NAME` | Attach to running process by name |
| `--wait-for NAME` | Wait for process to spawn, then attach |
| `--wait-timeout SEC` | Max wait time (default: 30s) |
| `-a, --all` | System-wide (all processes) |
| `-e, --env K=V` | Environment variable (repeatable) |
| `--stdout` | Forward target stdout |
| `--stderr` | Forward target stderr |

```bash
# Attach to a running process
trace-record.sh -d 10 -p $(pgrep MyApp)
trace-record.sh -d 10 -n Safari

# Wait for a process to spawn (useful after kicking off a build)
trace-record.sh --wait-for MyApp -d 10
trace-record.sh --wait-for MyApp --wait-timeout 60 -d 10

# System-wide profile
trace-record.sh -d 10 -a

# Different template
trace-record.sh -t 'System Trace' -d 10 -- ./my_app

# With environment variables
trace-record.sh -e MALLOC_STACK_LOGGING=1 -d 10 -- ./my_app
```

---

### `trace-analyze.py` — Analysis Engine

The core analysis tool. 1,500 lines of Python, stdlib only, no pip dependencies.

All subcommands accept `-` as the trace path to read from stdin (for piping).
All subcommands support `--process`, `--thread`, and `--time-range` filters.

#### `summary` — Flat Profile

Rank functions by CPU time. The first thing to run on any trace.

```bash
trace-analyze.py summary <trace> [--top N] [--by self|total] [--json] [--module NAME]
```

```
Trace: recording.trace
Duration: 10.62s | Samples: 2150 | Template: Time Profiler

 Samples   Self%  Total%  Function                              Module
──────────────────────────────────────────────────────────────────────────
     519   24.1%   63.0%  <deduplicated_symbol>                 libnode.141.dylib
     259   12.0%   12.0%  _platform_memchr                      libsystem_platform
     115    5.3%   36.5%  String::WriteToFlat2<u16>              libnode.141.dylib
```

- **Self%** — time in the function body itself (not callees)
- **Total%** — time in the function + everything it calls
- **`--json`** — machine-readable output for scripting and LLM consumption

#### `timeline` — Time-Bucketed Analysis

See how CPU usage shifts over the trace duration. Spot startup overhead, periodic spikes, GC pauses.

```bash
trace-analyze.py timeline <trace> [--window SIZE] [--adaptive] [--top N] [--json]
```

```
Time              Samples  Conf  Spark  Top Functions
──────────────────────────────────────────────────────────────────
0.00–0.50s             47  ░░    ▂     dyld4::prepare (72%)
0.50–1.00s            312  ██    ▅     computeHash (61%), memcpy (15%)
1.00–1.50s            502  ██    ▆     computeHash (58%)
1.50–2.00s            891  ██    ████   GC_collect (67%)              ← SPIKE
2.00–2.50s            498  ██    ▅     computeHash (55%)
```

**Confidence indicators:**
- `██` high (>50 samples) — reliable
- `▓░` medium (20-50) — directional
- `░░` low (<20) — noisy, interpret carefully

**Adaptive mode** (`--adaptive`) automatically detects phase transitions using Jaccard similarity between adjacent buckets. It identifies startup, steady-state, spikes, and idle periods:

```
=== PHASE DETECTION ===
Phase 1:  0.00s–0.85s  "Startup"   (dyld4::prepare dominates)
Phase 2:  0.85s–1.50s  "Compute"   (computeHash stable at ~58%)
Phase 3:  1.50s–2.00s  "GC Spike"  (GC_collect at 67%, 500ms)
Phase 4:  2.00s–10.0s  "Compute"   (computeHash stable at ~55%)
```

**Window sizes:** `1ms`, `10ms`, `100ms`, `500ms`, `1s`, `2s`. At 1ms sampling rate, you need ~100ms windows for statistically reliable data.

#### `calltree` — Call Hierarchy

See how time flows through your call stack with tree-drawing characters.

```bash
trace-analyze.py calltree <trace> [--depth N] [--min-pct PCT]
```

```
├──  99.0%  start                                     dyld
│   └──  99.0%  node::Start(int, char**)              libnode
│       └──  99.0%  node::NodeMainInstance::Run()      libnode
│           └──  90.9%  uv__run_timers                 libuv
│               └──  90.9%  RunTimers                  libnode
│                   ├──  45.0%  computeHash  ← HOT     MyApp
│                   └──  35.0%  renderFrame             MyApp
```

`← HOT` marks functions where self-time is ≥10% of total.

#### `collapsed` — Universal Interchange Format

Output collapsed stacks: `frame1;frame2;...frameN count`

```bash
trace-analyze.py collapsed <trace> [--module]
```

This is the **standard input format** for every flamegraph tool in the ecosystem:

```bash
# Feed to inferno
trace-analyze.py collapsed recording.trace | inferno-flamegraph > flame.svg

# Feed to brendangregg's flamegraph.pl
trace-analyze.py collapsed recording.trace | flamegraph.pl > flame.svg

# Feed to speedscope
trace-analyze.py collapsed recording.trace > stacks.folded
speedscope stacks.folded
```

#### `diff` — Before/After Comparison

Compare two JSON summaries to quantify optimization impact.

```bash
trace-analyze.py diff <before.json> <after.json> [--threshold PCT]
```

```
=== PERFORMANCE DIFF: baseline → optimized ===
Baseline: 9847 samples | Optimized: 9652 samples

IMPROVED ↓ (less CPU time):
  computeHash()                  23.8%    8.6%   -15.2%  ⬇
  allocateBuffer()                5.2%    2.1%    -3.1%  ⬇

REGRESSED ↑ (more CPU time):
  newOptimizedPath()              0.0%    2.0%    +2.0%  ⬆
```

---

### `trace-flamegraph.sh` — Flamegraph Generator

Auto-detects the best available tool: inferno → flamegraph.pl → built-in.

```bash
trace-flamegraph.sh <trace|-> [options]
```

| Option | Description |
|---|---|
| `-o, --output FILE` | Output SVG (default: `flamegraph.svg`) |
| `-w, --width PX` | Width (default: 1200, use 2400+ for detail) |
| `-t, --title TEXT` | Title |
| `--time-range RANGE` | Time window filter |
| `--process NAME` | Process filter |
| `--thread NAME` | Thread filter |
| `--tool TOOL` | Force: `inferno`, `flamegraph.pl`, `builtin` |
| `--open` | Open in browser |

When inferno is installed and no filters are needed, uses the optimal native pipeline:
`xctrace export → inferno-collapse-xctrace → inferno-flamegraph`

When filters are applied, routes through trace-analyze.py collapsed first:
`trace-analyze.py collapsed (filtered) → inferno-flamegraph`

---

### `trace-speedscope.sh` — Interactive Analysis

Opens the trace in [speedscope](https://www.speedscope.app/) — the best tool for human deep-dive analysis.

```bash
trace-speedscope.sh <trace|-> [--time-range RANGE] [--process NAME] [--thread NAME]
```

Speedscope provides:
- **Time Order view** — see every sample across time, full call stacks
- **Left Heavy view** — aggregate call tree (like a flamegraph, grouped)
- **Sandwich view** — select any function, see all callers AND callees
- **Zoom, pan, search** — full interactivity

---

### `trace-diff-flamegraph.sh` — Differential Flamegraph

Visual before/after comparison. Red = regression, blue = improvement.

```bash
trace-diff-flamegraph.sh <before.trace> <after.trace> [options]
```

Requires inferno (`cargo install inferno`).

---

### `trace-check.sh` — Environment Check

Verify everything is set up correctly.

```bash
trace-check.sh
```

Reports: xctrace version, Apple Silicon detection, Processor Trace availability, Python version, optional tools (inferno, speedscope), SIP status, available templates.

---

### `sample-quick.sh` — Lightweight Profiling

When you don't have Xcode or need a quick check. Uses macOS `sample` command.

```bash
sample-quick.sh <pid|name> [duration] [interval_ms] [output_file]
```

## Template Guide

| Template | Use When | Resolution | Overhead |
|---|---|---|---|
| **Time Profiler** | General CPU profiling — **start here** | 1ms sampling | Very low |
| **System Trace** | Thread contention, syscalls, lock issues, scheduling | Microsecond | Medium |
| **Processor Trace** | Need every function call, instruction-level | Every branch | Low-medium |
| **CPU Counters** | IPC, cache misses, branch mispredictions | Per-event | Low |
| **Allocations** | Memory leaks, allocation rates, object lifetimes | Per-allocation | Medium |

**Processor Trace** requires Apple Silicon and must be enabled in **System Settings → Privacy & Security → Developer Tools**.

## Debug Symbols

Without debug symbols, you'll see hex addresses instead of function names. How to enable per toolchain:

| Toolchain | Flag |
|---|---|
| **C/C++** (clang/gcc) | `-g -O2` or `-gline-tables-only -O2` (minimal symbols, full optimization) |
| **Swift** | `swift build -c release -Xswiftc -g` |
| **Rust** | `CARGO_PROFILE_RELEASE_DEBUG=true cargo build --release` |
| **Node.js** | V8 builtins are automatic; JS frames need `--perf-basic-prof` |
| **Xcode projects** | Debug builds include symbols. For Release: Build Settings → Debug Information Format → DWARF with dSYM |
| **CMake** | `cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ..` |

## Workflows

### Profile-Guided Optimization Loop

```bash
# 1. Build with symbols
cmake --build . --config RelWithDebInfo

# 2. Profile
TRACE=$(xtrace -d 10 ./build/my_app --benchmark)

# 3. Identify the hotspot
trace-analyze.py summary "$TRACE" --top 10
#  → "computeHash() at 24% self time"

# 4. Understand the call context
trace-analyze.py calltree "$TRACE" --min-pct 5

# 5. Make the fix, rebuild, re-profile
vim src/hash.cpp  # optimize
cmake --build .
TRACE_AFTER=$(trace -d 10 ./build/my_app --benchmark)

# 6. Compare
trace-analyze.py summary "$TRACE" --json > /tmp/before.json
trace-analyze.py summary "$TRACE_AFTER" --json > /tmp/after.json
trace-analyze.py diff /tmp/before.json /tmp/after.json

# 7. Visual diff
trace-diff-flamegraph.sh "$TRACE" "$TRACE_AFTER" --open
```

### Drill Into a Spike

```bash
TRACE=$(xtrace -d 10 ./my_app)

# See the timeline — where does it spike?
trace-analyze.py timeline "$TRACE" --window 100ms

# Zoom into the spike
trace-analyze.py summary "$TRACE" --time-range 3.2s-3.5s
trace-flamegraph.sh "$TRACE" --time-range 3.2s-3.5s --open
```

### Profile a Running Process

```bash
# By PID
trace-record.sh -d 10 -p $(pgrep -x MyApp) | trace-flamegraph.sh - --open

# By name
trace-record.sh -d 10 -n Safari | trace-speedscope.sh -
```

### LLM / CI Integration

```bash
# Machine-readable JSON output
TRACE=$(xtrace --no-summary -d 10 ./my_app)
trace-analyze.py summary "$TRACE" --json --top 20 > profile.json

# The JSON contains:
# {
#   "trace_file": "...",
#   "duration_s": 10.02,
#   "total_samples": 9847,
#   "functions": [
#     {"function": "computeHash", "module": "MyApp", "self_pct": 23.8, ...},
#     ...
#   ],
#   "modules": [{"module": "MyApp", "self_pct": 45.9}, ...]
# }
```

## Architecture

```
xtrace (entry point)
  └── trace-record.sh (xctrace wrapper)
        └── xctrace record (Apple's tool)
              └── .trace file

trace-analyze.py (analysis engine, Python, stdlib only)
  ├── summary    → text or JSON
  ├── timeline   → time-bucketed view
  ├── calltree   → call hierarchy
  ├── collapsed  → universal interchange format ──→ any flamegraph tool
  ├── flamegraph → built-in SVG (fallback)
  └── diff       → before/after comparison

trace-flamegraph.sh ──→ inferno (preferred) or flamegraph.pl or builtin
trace-speedscope.sh ──→ speedscope (interactive web UI)
trace-diff-flamegraph.sh ──→ inferno-diff-folded + inferno-flamegraph
```

**Data flow:**

```
.trace file ──→ xctrace export (XML) ──→ trace-analyze.py (parse) ──→ analysis
                                    └──→ inferno-collapse-xctrace ──→ inferno-flamegraph
```

The XML parser handles xctrace's id/ref/sentinel encoding:
- Elements define values with `id` attributes
- Later elements reference them with `ref` attributes
- `<sentinel/>` means "reuse previous row's value for this column"
- Frames in backtraces are leaf-first (index 0 = executing function)

## Pi Skill

This project is also a [pi](https://github.com/mariozechner/pi-coding-agent) skill. The `SKILL.md` file is loaded automatically when the agent encounters profiling tasks.

To install as a pi skill:

```bash
# Option 1: Symlink
ln -s ~/Work/xtrace-skill ~/.pi/agent/skills/instruments

# Option 2: Copy
cp -R ~/Work/xtrace-skill ~/.pi/agent/skills/instruments
```

## License

MIT
