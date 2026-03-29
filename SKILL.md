---
name: instruments
description: "Profile macOS applications using Instruments/xctrace. Record CPU traces, analyze hotspots, generate flamegraphs, compare profiles, drill into time windows. Detect memory leaks, track memory growth, analyze heap allocations."
---

# Instruments Profiling Skill

Unix-style profiling for macOS. Composable tools that pipe together.

## Quick Start

```bash
# CPU profiling
xtrace ./my_app                                    # record + print summary
xtrace ./my_app | trace-speedscope -               # → interactive analysis (best)

# Memory analysis
trace-memory.py summary -- ./my_app                # memory overview
trace-memory.py leaks -- ./my_app                   # detect leaks
trace-memory.py growth -d 30 -- ./my_app            # track growth over time
xtrace -t Allocations ./my_app                      # Instruments trace + memory summary
```

## Scripts

| Script | Purpose |
|---|---|
| **`xtrace`** | Record + summarize. Prefix any command. Auto-detects template type. |
| `trace-record.sh` | Record with full control (attach, wait-for, system-wide, templates) |
| `trace-analyze.py` | CPU analysis: summary, timeline, calltree, collapsed, diff, info |
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

`xtrace` automatically handles GPU/IO-bound workloads — falls back to `sample` if Time Profiler returns no data.

```bash
xtrace ./build/gpu_app --benchmark      # auto-fallback
sample-quick.sh --launch -d 10 -- ./build/gpu_app  # direct sample
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `xctrace not found` | `xcode-select --install` |
| No samples | `xtrace` auto-falls back to `sample` |
| Unsymbolicated frames | Rebuild with `-g` |
| Allocations trace empty in CLI | Normal — use `trace-memory.py` or open in Instruments.app |
| `leaks` needs backtraces | Launch with `MallocStackLogging=1` (automatic in trace-memory.py) |
| Permission denied for vmmap | Run with `sudo` or profile your own processes |
| Process exits too fast | Increase duration or add a sleep/wait in target app |
