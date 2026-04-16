# xtrace — Command-line CPU/GPU/Memory Profiling for macOS

Unix-style profiling tools for macOS Instruments. Record traces, analyze CPU hotspots, inspect GPU utilization, and investigate memory behavior — all from the terminal, all composable with pipes.

```bash
# Profile any command. Just prefix it.
xtrace ./my_app --benchmark

# Pipe to a flamegraph
xtrace ./my_app | trace-speedscope -

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

```bash
git clone https://github.com/Kr1sso/xtrace-skill.git
cd xtrace-skill
./install.sh
```

This does three things:

1. **Symlinks scripts to PATH** (`~/.local/bin`) — `xtrace`, `trace-record`, `trace-analyze.py`, etc.
2. **Installs as an AI agent skill** — Pi, Cursor, and Claude Code all use the same `SKILL.md` format. The installer symlinks this repo into each agent's skills directory.
3. **Prompts to install optional tools** — inferno and speedscope for best visualizations.

```
Skills:
  ✓ Pi:         ~/.pi/agent/skills/instruments/
  ✓ Cursor:     ~/.cursor/skills/instruments/
  ✓ Claude Code: ~/.claude/skills/instruments/
```

All three agents read the same `SKILL.md` natively — one repo, one file, three symlinks.

### Optional tools (recommended)

```bash
cargo install inferno        # Best flamegraph SVGs (click-to-zoom, search, hover)
npm install -g speedscope    # Interactive web UI (sandwich view, time-ordered, zoom)
```

### Verify

```bash
./scripts/trace-check.sh     # check environment
./test.sh                    # run end-to-end tests
```

### Requirements

- **macOS** with Xcode or Command Line Tools (`xcode-select --install`)
- **Python 3.8+** (ships with macOS)
- **Apple Silicon or Intel** (Processor Trace requires Apple Silicon + Developer Tools enabled)

## Quick Start

```bash
# CPU profiling (default Time Profiler)
xtrace -d 10 ./my_app

# GPU profiling (Metal System Trace)
xtrace --gpu -d 10 ./my_app

# Enable Shader Timeline for real shader hotspot / callsite tooling
xtrace --gpu --shader-timeline -d 10 ./my_shader_app

# Interactive shader stack exploration in speedscope
TRACE=$(xtrace --gpu --shader-timeline --no-summary -d 10 ./my_shader_app)
trace-shader-speedscope.sh "$TRACE"

# Broader Metal profiling (Game Performance template)
xtrace -t 'Game Performance' -d 10 ./my_metal_app

# Custom Metal instrument set
xtrace --instrument GPU --instrument 'Metal Application' -d 10 ./my_metal_app

# Memory analysis
trace-memory.py summary -- ./my_app

# Programmatic GPU trace capture from a Metal app that uses MTLCaptureManager
# .gputrace bundles do NOT come from xctrace/Instruments CLI recording.
# You need host-app code that calls MTLCaptureManager (or Xcode GUI capture).
MTL_CAPTURE_ENABLED=1 ./build/examples/metal_compute_demo \
  --capture-only /tmp/metal_compute_demo.gputrace --seconds 0.2
trace-gputrace.py info /tmp/metal_compute_demo.gputrace

# The trace path prints to stdout so you can pipe it:
xtrace ./my_app | trace-speedscope -
xtrace ./my_app | trace-analyze.py summary -
```

## Tools

### `xtrace` — The Main Entry Point

Works like `time`. Prefix any command to profile it.

```bash
xtrace [options] command [args...]
```

| Option | Description |
|---|---|
| `-d DURATION` | Recording time limit (default: `30s`). Accepts: `10`, `10s`, `2.5s`, `500ms`, `2m` |
| `-t TEMPLATE` | Instruments template (default: `Time Profiler`) |
| `--instrument NAME` | Add an Instruments instrument by name (repeatable) |
| `--shader-timeline` | Patch a GPU template on the fly so Metal Shader Timeline is enabled |
| `--gpu` | Shortcut for `-t "Metal System Trace"` + GPU summary |
| `--cpu` | Shortcut for `-t "Time Profiler"` |
| `--gpu-process NAME` | Override process filter for GPU summary matching |
| `-o PATH` | Output `.trace` file path (default: auto in `/tmp`) |
| `--no-summary` | Skip the auto-printed summary |
| `--top N` | Functions to show in CPU / shader summaries (default: `15`) |

**Output:** Summary to stderr, trace file path to stdout.

```bash
# Save the trace path for later use
TRACE=$(xtrace -d 10 ./my_app)
trace-analyze.py calltree "$TRACE" --depth 15
trace-speedscope.sh "$TRACE"

# Build → profile in one line
make -j8 && xtrace ./build/app | trace-speedscope -
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
| `-i, --instrument NAME` | Add an Instruments instrument by name (repeatable) |
| `--shader-timeline` | Enable Metal Shader Timeline by patching a GPU template on the fly |
| `-d, --duration SEC` | Duration: `10`, `10s`, `2.5s`, `500ms`, `2m` (default: `10s`) |
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

# Custom Metal instrument set
trace-record.sh --instrument GPU --instrument 'Metal Application' -d 10 -- ./my_metal_app

# Enable Shader Timeline on a Metal template
trace-record.sh -t 'Metal System Trace' --shader-timeline -d 10 -- ./my_shader_app

# Template + extra Metal instruments
trace-record.sh -t 'Game Performance' --instrument 'Metal GPU Counters' -d 10 -- ./my_game

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
trace-analyze.py collapsed <trace> [--with-module]
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

Compare two JSON summaries to quantify optimization impact. Shows both self-time and total (inclusive) time changes.

```bash
trace-analyze.py diff <before.json> <after.json> [--threshold PCT]
```

```
=== PERFORMANCE DIFF: baseline → optimized ===
Baseline: 9847 samples | Optimized: 9652 samples

IMPROVED ↓ (less CPU time):
  Function                              Self           Δself  Total            Δtotal
  computeHash()                   23.8→ 8.6%  -15.2%  45.0→30.1%   -14.9%  ⬇
  allocateBuffer()                 5.2→ 2.1%   -3.1%   8.3→ 5.0%    -3.3%  ⬇

REGRESSED ↑ (more CPU time):
  newOptimizedPath()               0.0→ 2.0%   +2.0%   0.0→ 3.5%    +3.5%  ⬆
```

---

### `trace-gpu.py` — GPU / Metal Summary

Analyze Metal-heavy traces from `xtrace --gpu`, `xtrace -t 'Game Performance'`, or custom instrument recordings such as `trace-record.sh --instrument GPU --instrument 'Metal Application'`.

```bash
trace-gpu.py recording.trace
trace-gpu.py recording.trace --json > gpu_report.json
trace-gpu.py recording.trace --process MyWorker
```

Reports include:
- GPU state utilization and GPU performance-state residency
- Metal application intervals, command-buffer submissions, and encoder cadence
- Shader inventory plus shader-timeline data when shader profiler rows are present
- CPU→GPU start latency, submission→completion latency, and GPU ownership share by process
- Driver activity and GPU counter metadata / aggregated counter intervals when available

Notes:
- Shader-profiler and GPU-counter tables are surfaced when the trace contains them.
- Some devices / counter profiles expose metadata but no interval rows; the report calls that out explicitly instead of failing silently.

---

### `trace-shader.py` — Shader Hotspots, Callsites, and Flamegraph Inputs

Analyze the real shader-profiler tables that Instruments exports when **Shader Timeline** is enabled in a GPU trace template.

```bash
# Record with Shader Timeline enabled
xtrace --gpu --shader-timeline ./my_shader_app

# Inspect availability / metadata
trace-shader.py info recording.trace

# Human-readable hotspots
trace-shader.py hotspots recording.trace

# Callsite / PC tree
trace-shader.py callsites recording.trace

# Collapsed stacks for inferno / flamegraph.pl
trace-shader.py collapsed recording.trace

# Built-in SVG flamegraph
trace-shader.py flamegraph recording.trace -o shader.svg
```

`trace-shader.py` automatically uses the best shader-profiler data available in the trace:
1. `metal-shader-profiler-intervals` (high-level shader timeline rows)
2. `gpu-shader-profiler-interval` (per-PC duration rows)
3. `gpu-shader-profiler-sample` (per-sample PC stacks)

When human-readable function labels are unavailable, raw PC offsets are emitted (for example `proceduralFragment+0x1a4`).

---

### `trace-shader-flamegraph.sh` — Shader Flamegraph Wrapper

Convenience wrapper around `trace-shader.py collapsed` with the same auto-tool behavior as the CPU flamegraph wrapper. Use this for the **static SVG** shader flamegraph.

```bash
trace-shader-flamegraph.sh recording.trace -o shader.svg
trace-shader-flamegraph.sh --stage fragment recording.trace -o fragment.svg
trace-shader-flamegraph.sh --tool builtin recording.trace -o shader.svg
```

Uses the best available tool:
- `inferno-flamegraph`
- `flamegraph.pl`
- built-in SVG generation via `trace-shader.py flamegraph`

---

### `trace-shader-speedscope.sh` — Interactive Shader Speedscope View

Open shader collapsed stacks from `trace-shader.py` in speedscope. Use this for the **interactive** shader flamegraph / sandwich / left-heavy exploration.

```bash
trace-shader-speedscope.sh recording.trace
trace-shader-speedscope.sh --stage fragment recording.trace
trace-shader-speedscope.sh --shader pbrFragment recording.trace
trace-shader-speedscope.sh -o shader.folded recording.trace
```

Notes:
- speedscope is the most detailed interactive shader stack viewer we support.
- It only becomes richly nested when the trace contains real shader-profiler rows.
- If the trace falls back to coarse GPU intervals, speedscope will only show coarse top-level stacks.

---

### `trace-gputrace.py` — MTLCaptureManager `.gputrace` Inspector

Inspect `.gputrace` bundles produced by Metal apps that call `MTLCaptureManager`.

Important:
- `xctrace` / Instruments CLI records `.trace`, **not** `.gputrace`.
- To get a `.gputrace`, you must either:
  1. capture from **Xcode Metal Debugger**, or
  2. add **host-project code** that calls `MTLCaptureManager`.
- This repo ships example Metal apps that already contain that host-side capture code.

```bash
# Human-readable overview
trace-gputrace.py info capture.gputrace

# Resource inventory + extracted shader names
trace-gputrace.py resources capture.gputrace

# Decode a captured buffer by label with a flexible layout
trace-gputrace.py buffer capture.gputrace --buffer "Compute Values Buffer" --layout float --index 0-8
trace-gputrace.py buffer capture.gputrace --buffer "Window Vertices" --layout "float2,float4" --index 0-2

# Dump extracted printable strings from internal bundle files
trace-gputrace.py strings capture.gputrace --limit 80

# Generate an HTML report for browser inspection
trace-gputrace.py report capture.gputrace -o capture_report.html
```

What it extracts today:
- binary-plist capture metadata (`metadata`)
- bundle file inventory, sizes, and magic bytes
- raw resource snapshot files (`MTLBuffer-*`, `MTLTexture-*`, `CAMetalLayer-*`)
- resource labels recovered from bundle internals
- shader/library names recovered from `device-resources*`
- flexible buffer decoding with layouts such as `float`, `float2`, `float4`, `float2,float4`

What it does **not** do:
- create `.gputrace` bundles by itself
- attach to arbitrary external processes and force them to emit `.gputrace`
- turn an Instruments `.trace` into a `.gputrace`

---

### `trace-template.py` — Template Patcher

Internal helper that patches an Instruments `.tracetemplate` so GPU traces can be recorded with Shader Timeline enabled from the command line.

```bash
trace-template.py enable-shader-timeline \
  '/Applications/Xcode.app/.../Metal System Trace.tracetemplate' \
  -o /tmp/MetalSystemTraceShaderTimeline.tracetemplate
```

`xtrace --shader-timeline ...` and `trace-record.sh --shader-timeline ...` call this automatically — you usually do not need to invoke it directly.

---

### `trace-memory.py` — Memory Analysis (Summary, Leaks, Growth)

Quick memory tooling that complements Instruments memory templates.

```bash
trace-memory.py summary -- ./my_app
trace-memory.py leaks -- ./my_app
trace-memory.py growth -d 30 --interval 2 -- ./my_app
```

Use with recordings when needed:

```bash
xtrace -t Allocations ./my_app
xtrace -t Leaks ./my_app
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
| **Metal System Trace** | GPU utilization, command-buffer cadence, shader inventory, CPU/GPU correlation | Event intervals | Medium |
| **Metal System Trace + Shader Timeline** | Real shader hotspots / callsites / shader flamegraphs via `trace-shader.py` | Event intervals + shader-profiler rows | Medium-high |
| **Game Performance** | Broader Metal/game traces: GPU state, shader inventory, counters metadata, driver activity | Mixed | Medium |
| **Game Performance Overview** | High-level graphics/Metal overview metrics when available | Metric intervals | Low-medium |
| **System Trace** | Thread contention, syscalls, lock issues, scheduling | Microsecond | Medium |
| **Processor Trace** | Need every function call, instruction-level | Every branch | Low-medium |
| **CPU Counters** | IPC, cache misses, branch mispredictions | Per-event | Low |
| **Allocations** | Memory usage, object lifetimes, allocation rates | Per-allocation | Medium |
| **Leaks** | Leak detection and allocation backtraces | Per-allocation | Medium |

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
TRACE_AFTER=$(xtrace -d 10 ./build/my_app --benchmark)

# 6. Compare
trace-analyze.py summary "$TRACE" --json > /tmp/before.json
trace-analyze.py summary "$TRACE_AFTER" --json > /tmp/after.json
trace-analyze.py diff /tmp/before.json /tmp/after.json

# 7. Visual diff
trace-diff-flamegraph.sh "$TRACE" "$TRACE_AFTER" -o diff.svg
```

### Drill Into a Spike

```bash
TRACE=$(xtrace -d 10 ./my_app)

# See the timeline — where does it spike?
trace-analyze.py timeline "$TRACE" --window 100ms

# Zoom into the spike
trace-analyze.py summary "$TRACE" --time-range 3.2s-3.5s
trace-speedscope.sh "$TRACE" --time-range 3.2s-3.5s
```

### Profile a Running Process

```bash
# By PID
trace-record.sh -d 10 -p $(pgrep -x MyApp) | trace-speedscope.sh -

# By name
trace-record.sh -d 10 -n Safari | trace-speedscope.sh -
```

### Shader Hotspots / Callsites / Flamegraphs

```bash
# 1. Record a shader-profiler-capable trace
TRACE=$(xtrace --gpu --shader-timeline --no-summary -d 10 ./my_shader_app)

# 2. Inspect what shader data is available
trace-shader.py info "$TRACE"

# 3. Human-readable hotspots
trace-shader.py hotspots "$TRACE"

# 4. Callsite / PC tree
trace-shader.py callsites "$TRACE"

# 5. Static SVG flamegraph
trace-shader-flamegraph.sh "$TRACE" -o shader.svg

# 6. Interactive shader speedscope view
trace-shader-speedscope.sh "$TRACE"
```

If `trace-shader.py info` reports that Shader Timeline is enabled but there are still no runtime shader rows, the device / driver likely declined to export shader-profiler samples for that counter profile. The tooling remains ready for traces that do contain those rows.

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

trace-analyze.py (CPU analysis engine, Python, stdlib only)
  ├── summary    → text or JSON
  ├── timeline   → time-bucketed view
  ├── calltree   → call hierarchy
  ├── collapsed  → universal interchange format ──→ any flamegraph tool
  ├── flamegraph → built-in SVG (fallback)
  └── diff       → before/after comparison

trace-gpu.py     ──→ Metal System Trace GPU summaries (state, cadence, ownership)
trace-shader.py  ──→ Shader-profiler info, hotspots, callsites, collapsed stacks, SVG
trace-memory.py  ──→ RSS/VM/leak/growth analysis for launch or attach modes
trace-flamegraph.sh ──→ inferno (preferred) or flamegraph.pl or builtin
trace-shader-flamegraph.sh ──→ shader collapsed stacks → inferno/flamegraph.pl/builtin (static SVG)
trace-shader-speedscope.sh ──→ shader collapsed stacks → speedscope (interactive)
trace-speedscope.sh ──→ CPU collapsed stacks → speedscope (interactive web UI)
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

## AI Agent Skill

This project follows the [Agent Skills](https://agentskills.io) open standard. The `SKILL.md` file is read natively by:

- **[Pi](https://github.com/mariozechner/pi-coding-agent)** — `~/.pi/agent/skills/instruments/`
- **[Cursor](https://cursor.com)** — `~/.cursor/skills/instruments/`
- **[Claude Code](https://code.claude.com)** — `~/.claude/skills/instruments/`

Run `./install.sh` to symlink into all detected agents, or manually:

```bash
ln -s ~/Work/xtrace-skill ~/.pi/agent/skills/instruments
ln -s ~/Work/xtrace-skill ~/.cursor/skills/instruments
ln -s ~/Work/xtrace-skill ~/.claude/skills/instruments
```

## License

MIT
