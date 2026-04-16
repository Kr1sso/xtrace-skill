---
name: instruments
description: "Profile macOS applications using Instruments/xctrace. Record CPU and GPU traces, analyze hotspots and GPU utilization, generate flamegraphs, compare profiles, drill into time windows. Detect memory leaks, track memory growth, analyze heap allocations."
---

# Instruments Profiling Skill

Unix-style profiling for macOS. Composable tools that pipe together.

## Quick Start

```bash
# CPU profiling
xtrace ./my_app                                    # record + print CPU summary
xtrace --cpu ./my_app                              # explicit CPU template
xtrace ./my_app | trace-speedscope -               # → interactive analysis (best)

# GPU profiling (Metal System Trace)
xtrace --gpu ./my_app                              # GPU summary + CPU hotspot summary
xtrace --gpu --gpu-process my_app ./launcher       # override process filter when launcher name differs
xtrace --gpu --shader-timeline ./my_shader_app     # enable real shader hotspot / callsite tooling
TRACE=$(xtrace --gpu --shader-timeline --no-summary ./my_shader_app)
trace-shader-speedscope.sh "$TRACE"                # interactive shader stack explorer
trace-shader-speedscope.sh -o shader.folded "$TRACE"  # keep the folded stacks too

# Broader Metal profiling
xtrace -t 'Game Performance' ./my_metal_app        # GPU + shader inventory + driver activity
xtrace --instrument GPU --instrument 'Metal Application' ./my_metal_app

# Memory analysis
trace-memory.py summary -- ./my_app                # memory overview
trace-memory.py leaks -- ./my_app                  # detect leaks
trace-memory.py growth -d 30 -- ./my_app           # track growth over time
xtrace -t Allocations ./my_app                     # Instruments trace + memory summary

# Programmatic GPU trace capture from an app using MTLCaptureManager
# .gputrace bundles do NOT come from xctrace/Instruments CLI recording.
# You need host-project code that calls MTLCaptureManager (or Xcode GUI capture).
MTL_CAPTURE_ENABLED=1 ./build/examples/metal_compute_demo \
  --capture-only /tmp/metal_compute_demo.gputrace --seconds 0.2
trace-gputrace.py info /tmp/metal_compute_demo.gputrace
```

## `.gputrace` mental model

- **`xctrace` / Instruments CLI → `.trace`**
- **`MTLCaptureManager` or Xcode Metal Debugger → `.gputrace`**

So when a user asks for a `.gputrace`, make sure the **host project has capture code inside it** (or direct them to the Xcode GUI workflow). The tools in this repo can inspect `.gputrace` bundles, but they cannot synthesize one from an arbitrary external process.

## Scripts

| Script | Purpose |
|---|---|
| **`xtrace`** | Record + summarize. Prefix any command. Supports CPU (`--cpu`), Metal templates, `--shader-timeline`, and custom `--instrument` sets. |
| `trace-record.sh` | Record with full control (attach, wait-for, system-wide, templates, custom instruments, shader timeline patching) |
| `trace-analyze.py` | CPU analysis: summary, timeline, calltree, collapsed, diff, info |
| **`trace-gpu.py`** | **GPU / Metal analysis: state residency, command buffers, encoders, shader inventory/timeline, latency, ownership, counters** |
| **`trace-gputrace.py`** | **Inspect `.gputrace` bundles captured via `MTLCaptureManager`: metadata, resources, labels, shader names, buffer decoding, HTML reports. It inspects existing bundles; it does not create them.** |
| **`trace-shader.py`** | **Shader-profiler analysis: info, hotspots, callsites, collapsed stacks, SVG flamegraphs** |
| `trace-shader-flamegraph.sh` | Generate static SVG shader flamegraphs from shader-profiler rows |
| `trace-shader-speedscope.sh` | Open shader collapsed stacks in speedscope for interactive inspection |
| `trace-template.py` | Patch GPU templates so Shader Timeline is enabled from the CLI |
| **`trace-memory.py`** | **Memory analysis: summary, leaks, growth, regions, heap** |
| `trace-speedscope.sh` | Interactive visualization (speedscope web UI) |
| `trace-flamegraph.sh` | Generate SVG flamegraph file |
| `trace-diff-flamegraph.sh` | Differential red/blue SVG between two traces |
| `trace-check.sh` | Verify environment |
| `sample-quick.sh` | Lightweight profiling via macOS `sample` |

## Prerequisites

```bash
./install.sh    # installs to PATH, registers skills, prompts for optional tools
```

**Required:** Xcode or Command Line Tools, Python 3.8+
**Recommended:** speedscope (`npm install -g speedscope`), inferno (`cargo install inferno`)

**Debug symbols per toolchain:**

| Toolchain | Flag |
|---|---|
| C/C++ | `-g -O2` or `-gline-tables-only -O2` |
| Swift | `swift build -c release -Xswiftc -g` |
| Rust | `CARGO_PROFILE_RELEASE_DEBUG=true cargo build --release` |
| Node.js | V8 builtins automatic; JS needs `--perf-basic-prof` |
| Xcode | Debug has symbols; Release needs dSYM in build settings |
| CMake | `-DCMAKE_BUILD_TYPE=RelWithDebInfo` |

## CPU Profiling

### Dev Loop

```bash
# 1. Profile
BASELINE=$(xtrace -d 10 ./build/my_app --benchmark)

# 2. Visualize interactively
trace-speedscope.sh "$BASELINE"

# 3. Save baseline for comparison
trace-analyze.py summary "$BASELINE" --json > /tmp/before.json

# 4. Fix the hotspot, rebuild, re-profile
cmake --build .
AFTER=$(xtrace -d 10 ./build/my_app --benchmark)
trace-analyze.py summary "$AFTER" --json > /tmp/after.json

# 5. Compare
trace-analyze.py diff /tmp/before.json /tmp/after.json
```

### LLM Pattern

```bash
TRACE=$(xtrace -d 10 --no-summary ./build/my_app)
trace-analyze.py summary "$TRACE" --json --top 20 > profile.json
trace-analyze.py calltree "$TRACE" --min-pct 3.0
```

### Recording

```bash
trace-record.sh -d 10 -p <PID>                    # attach by PID
trace-record.sh -d 10 -n MyApp                    # attach by name
trace-record.sh --wait-for MyApp -d 10             # wait for spawn
trace-record.sh -d 10 -a                           # system-wide
trace-record.sh -t 'System Trace' -d 10 -- ./app  # different template
```

### Analysis Subcommands

All support `--process`, `--thread`, `--time-range`, and `-` for stdin.

```bash
trace-analyze.py summary <trace> [--top N] [--by self|total] [--json]
trace-analyze.py timeline <trace> [--window SIZE] [--adaptive] [--json]
trace-analyze.py calltree <trace> [--depth N] [--min-pct PCT]
trace-analyze.py collapsed <trace> [--with-module]
trace-analyze.py info <trace> [--json]              # show trace metadata & contents
trace-analyze.py diff <before.json> <after.json> [--threshold PCT]
```

### Visualization

```bash
xtrace ./app | trace-speedscope -                    # interactive (best)
trace-flamegraph.sh recording.trace -o profile.svg   # SVG file
trace-diff-flamegraph.sh before.trace after.trace -o diff.svg
```

## GPU Profiling (Metal)

### Quick GPU Loop

```bash
# One-command GPU profiling (Metal System Trace)
xtrace --gpu -d 10 ./my_app --benchmark

# Enable Shader Timeline for real shader tooling
TRACE=$(xtrace --gpu --shader-timeline --no-summary -d 10 ./my_shader_app)
trace-shader.py info "$TRACE"
trace-shader.py hotspots "$TRACE"
trace-shader-flamegraph.sh "$TRACE" -o shader.svg
trace-shader-speedscope.sh "$TRACE"

# Broader Metal/game trace
xtrace -t 'Game Performance' -d 10 ./my_metal_app

# Custom Metal instrument set
trace-record.sh --instrument GPU --instrument 'Metal Application' -d 10 -- ./my_metal_app

# Record now, analyze later
TRACE=$(xtrace --gpu --no-summary -d 10 ./my_app)
trace-gpu.py "$TRACE"                                # human summary
trace-gpu.py "$TRACE" --json > gpu_report.json      # machine-readable

# Launcher process differs from worker process name
xtrace --gpu --gpu-process my_worker ./launcher
```

### Deep GPU + CPU Correlation

```bash
trace-record.sh -t 'Metal System Trace' -d 10 -- ./my_app
trace-record.sh -t 'Metal System Trace' --shader-timeline -d 10 -- ./my_shader_app
trace-record.sh --instrument GPU --instrument 'Metal Application' -d 10 -- ./my_metal_app
trace-gpu.py recording.trace
trace-shader.py hotspots recording.trace
trace-analyze.py summary recording.trace --top 20
```

`trace-gpu.py` reports:
- **GPU state utilization**: Active vs Idle ratios
- **GPU performance states**: Minimum/Medium/etc. residency when the trace contains them
- **Metal app activity**: application intervals, command-buffer submissions, encoder cadence
- **Shader visibility**: shader inventory, plus shader-timeline rows when the trace exposes them
- **Latency correlation**: CPU→GPU start latency and submission→completion latency
- **GPU ownership**: target process share vs competing processes (WindowServer, browser GPU helpers, etc.)
- **Driver/counter insight**: driver phases plus GPU-counter metadata / aggregated intervals when available

`trace-shader.py` adds the real shader-profiler layer when Shader Timeline rows are present:
- **Shader hotspots** from `metal-shader-profiler-intervals`
- **Callsite / PC trees** from shader-profiler rows and samples
- **Collapsed stacks / flamegraphs** via `trace-shader.py collapsed`, `trace-shader-flamegraph.sh`, or `trace-shader-speedscope.sh`

Some devices and templates expose shader/counter metadata without interval rows. The tools surface that explicitly instead of failing silently.

## Memory Analysis

### Quick Memory Check

```bash
# Overview of memory usage
trace-memory.py summary -- ./my_app --benchmark

# Check for leaks (with allocation backtraces)
trace-memory.py leaks -- ./my_app

# Analyze a running process
trace-memory.py summary -p <PID>
trace-memory.py leaks -p <PID>
```

### Track Memory Growth

```bash
# Watch memory over 30 seconds with 2s snapshots
trace-memory.py growth -d 30 --interval 2 -- ./my_app --serve

# JSON for programmatic analysis
trace-memory.py growth -d 30 --json -- ./my_app > memory_growth.json
```

### Detailed Analysis

```bash
# All VM regions with sizes
trace-memory.py regions -p <PID>

# Heap allocations by class/type
trace-memory.py heap -p <PID>

# Combine with Instruments recording
xtrace -t Allocations -- ./my_app    # records trace + shows memory summary
xtrace -t Leaks -- ./my_app           # records trace + shows leak report
```

### Memory + Instruments Workflow

```bash
# 1. Quick CLI check
trace-memory.py leaks -- ./my_app
# → Found 3 leaks!

# 2. Record Instruments trace for deep analysis
trace-record.sh -t Allocations -d 30 -- ./my_app
# → Open .trace in Instruments.app for allocation timeline, call trees

# 3. Track memory over time
trace-memory.py growth -d 60 --json -- ./my_app > growth.json
# → Identify which regions are growing

# 4. Inspect trace metadata
trace-analyze.py info recording.trace
```

### LLM Pattern for Memory

```bash
# Quick leak check
trace-memory.py leaks --json -- ./my_app > leaks.json

# Memory overview
trace-memory.py summary --json -p <PID> > memory.json

# Growth tracking
trace-memory.py growth -d 20 --json -- ./my_app > growth.json
```

## Templates

| Template | When | Tool | Resolution |
|---|---|---|---|
| **Time Profiler** | General CPU profiling (default) | trace-analyze.py | 1ms sampling |
| **Metal System Trace** | GPU utilization, command-buffer cadence, shader inventory, CPU/GPU correlation | **trace-gpu.py** + trace-analyze.py | Event intervals |
| **Metal System Trace + Shader Timeline** | Real shader hotspots / callsites / shader flamegraphs | **trace-shader.py** + `trace-shader-flamegraph.sh` + `trace-shader-speedscope.sh` | Event intervals + shader-profiler rows |
| **Game Performance** | Broader Metal/game traces: GPU state, shader inventory, driver activity, counters metadata | **trace-gpu.py** | Mixed |
| **Game Performance Overview** | High-level graphics/Metal overview metrics when available | **trace-gpu.py** | Metric intervals |
| System Trace | Thread contention, syscalls | Instruments.app | Microsecond |
| Processor Trace | Every function call | trace-analyze.py | Every branch |
| CPU Counters | IPC, cache misses | Instruments.app | Per-event |
| **Allocations** | Memory usage, allocation patterns | **trace-memory.py** | Per-allocation |
| **Leaks** | Memory leaks | **trace-memory.py** | Per-allocation |
| Game Memory | Game memory budgets | trace-memory.py | Per-allocation |

## Interpreting Results

### CPU Patterns

| Pattern | Meaning | Action |
|---|---|---|
| High self time | Function body is bottleneck | Optimize algorithm |
| High inclusive, low self | Calls something expensive | Look at callees |
| `malloc`/`free` heavy | Allocation churn | Pool, arena, reduce allocations |

### Memory Patterns

| Pattern | Meaning | Action |
|---|---|---|
| Growing RSS over time | Memory leak or unbounded cache | Run `leaks`, check growth regions |
| Large IOKit/IOAccelerator | GPU memory (Metal/MLX) | Check GPU buffer lifecycle |
| High dirty, low resident | Swapping pressure | Reduce working set |
| MALLOC_LARGE growing | Large heap allocations | Check for unbounded collections |
| Many leaks from one stack | Systematic leak pattern | Fix the allocation/release pair |

## GPU/IO-Bound Workloads

- In **CPU mode** (`Time Profiler`), `xtrace` auto-falls back to `sample` if CPU samples are empty.
- In **GPU mode** (`--gpu` / `Metal System Trace`), `xtrace` keeps the Metal trace and runs `trace-gpu.py` summary (no sample fallback).

```bash
# CPU mode with automatic sample fallback when needed
xtrace ./build/gpu_app --benchmark

# Explicit GPU trace mode
xtrace --gpu ./build/gpu_app --benchmark

# Direct sample usage
sample-quick.sh --launch -d 10 -- ./build/gpu_app
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `xctrace not found` | `xcode-select --install` |
| No CPU samples in Time Profiler | `xtrace` auto-falls back to `sample` in CPU mode |
| Unsymbolicated frames | Rebuild with `-g` |
| Missing GPU rows in `trace-gpu.py` | Ensure template is `Metal System Trace` (`xtrace --gpu ...`) |
| Allocations trace empty in CLI | Normal — use `trace-memory.py` or open in Instruments.app |
| `leaks` needs backtraces | Launch with `MallocStackLogging=1` (automatic in trace-memory.py) |
| Permission denied for vmmap | Run with `sudo` or profile your own processes |
| Process exits too fast | Increase duration or add a sleep/wait in target app |
