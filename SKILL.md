---
name: instruments
description: "Profile macOS applications using Instruments/xctrace from the command line. Record CPU traces, analyze hotspots, generate flamegraphs, compare before/after profiles, and visualize performance over time."
---

# Instruments Profiling Skill

Unix-style CPU profiling for macOS. Composable tools that pipe together.

## The `xtrace` Command

**Profile any command — just prefix it with `xtrace`, like `time`.**

```bash
xtrace ./my_app --benchmark
```

This records a trace, prints a summary to stderr, and outputs the trace path to stdout. Pipe it to anything:

```bash
xtrace ./my_app | trace-flamegraph -            # → flamegraph SVG
xtrace ./my_app | trace-speedscope -            # → interactive UI in browser
xtrace -d 5 ./my_app | trace-flamegraph - --open  # 5s trace, open in browser
cmake --build . && xtrace ./my_app              # build then profile
TRACE=$(xtrace ./my_app)                        # save path for later
```

All tools accept `-` to read the trace path from stdin.

## Scripts

| Script | Stdin | Purpose |
|---|---|---|
| **`xtrace`** | — | **Record + summarize.** Prefix any command. Path to stdout. |
| `trace-record.sh` | — | Record only (more options: attach, system-wide, template) |
| `trace-analyze.py` | `-` | **Analysis engine**: summary, timeline, calltree, collapsed, diff |
| `trace-flamegraph.sh` | `-` | Flamegraph SVG (auto-picks inferno > flamegraph.pl > builtin) |
| `trace-speedscope.sh` | `-` | Open in speedscope interactive web UI |
| `trace-diff-flamegraph.sh` | — | Differential red/blue flamegraph between two traces |
| `trace-check.sh` | — | Verify environment |
| `sample-quick.sh` | — | Lightweight profiling via macOS `sample` (no Xcode needed) |

## Prerequisites

```bash
./scripts/trace-check.sh     # verify environment
cargo install inferno         # recommended: best flamegraphs
npm install -g speedscope     # recommended: interactive UI
```

**Required:** Xcode or Command Line Tools, Python 3.8+

**For debug symbols:** compile with `-g` or ensure `.dSYM` present. Per-toolchain:

| Toolchain | How to get symbols |
|---|---|
| **C/C++** (clang/gcc) | `-g -O2` or `-gline-tables-only -O2` |
| **Swift** | `swift build -c release -Xswiftc -g` |
| **Rust** | `CARGO_PROFILE_RELEASE_DEBUG=true cargo build --release` |
| **Node.js** | Symbols for V8 builtins are automatic; JS frames show as hex (use `--perf-basic-prof`) |
| **Xcode projects** | Debug build includes symbols; for Release, enable dSYM in build settings |

## Dev Loop

The typical profile-guided optimization loop:

```bash
# 1. Build your project
cmake --build . --config Release

# 2. Profile it
xtrace -d 10 ./build/my_app --benchmark | trace-flamegraph - --open

# 3. Read the summary (printed to stderr), identify the hotspot
#    → "computeHash() is 24% self time"

# 4. Fix the hotspot, rebuild, re-profile
cmake --build . && xtrace -d 10 ./build/my_app --benchmark > /tmp/after.trace

# 5. Compare before vs after
./scripts/trace-analyze.py diff /tmp/before.json /tmp/after.json
./scripts/trace-diff-flamegraph.sh /tmp/before.trace /tmp/after.trace --open
```

### LLM Integration Pattern

When an LLM is optimizing code:

```bash
# Profile and get machine-readable output
TRACE=$(./scripts/xtrace -d 10 --no-summary ./build/my_app)
./scripts/trace-analyze.py summary "$TRACE" --json --top 20 > profile.json
./scripts/trace-analyze.py calltree "$TRACE" --min-pct 3.0

# The LLM reads the JSON/text, identifies the hotspot, makes changes, rebuilds, re-profiles
```

## Recording Options

`xtrace` handles the simple case. For more control, use `trace-record.sh`:

```bash
# Attach to a running process
./scripts/trace-record.sh -d 10 -p <PID>
./scripts/trace-record.sh -d 10 -n MyApp

# Wait for a process to spawn (e.g. after a build starts it), then attach
./scripts/trace-record.sh --wait-for MyApp -d 10
./scripts/trace-record.sh --wait-for MyApp --wait-timeout 60 -d 10

# System-wide
./scripts/trace-record.sh -d 10 -a

# Different template
./scripts/trace-record.sh -t 'System Trace' -d 10 -- ./my_app

# With environment variables
./scripts/trace-record.sh -e MALLOC_STACK_LOGGING=1 -d 10 -- ./my_app
```

## Template Selection

| Template | When to Use | Resolution |
|---|---|---|
| **Time Profiler** | General CPU profiling (default, start here) | 1ms sampling |
| **System Trace** | Thread contention, syscalls, scheduling | Microsecond |
| **Processor Trace** | Every function call, instruction-level | Every branch |
| **CPU Counters** | IPC, cache misses, branch mispredictions | Per-event |
| **Allocations** | Memory leaks, allocation patterns | Per-allocation |

## Analysis (trace-analyze.py)

All subcommands support `--process`, `--thread`, `--time-range` filters, and `-` for stdin.

### summary — Find the hotspots

```bash
./scripts/trace-analyze.py summary <trace> [--top N] [--by self|total] [--json]
```

### timeline — CPU usage over time

```bash
./scripts/trace-analyze.py timeline <trace> [--window SIZE] [--adaptive] [--top N] [--json]
```

Buckets with sparklines and confidence: `██` high, `▓░` medium, `░░` low. `← SPIKE` marks outliers.

### calltree — Call hierarchy

```bash
./scripts/trace-analyze.py calltree <trace> [--depth N] [--min-pct PCT]
```

### collapsed — Universal interchange format

```bash
./scripts/trace-analyze.py collapsed <trace> [--module]
```

`frame1;frame2;...frameN count` — feeds every flamegraph tool in existence.

### diff — Before vs after

```bash
./scripts/trace-analyze.py diff <before.json> <after.json> [--threshold PCT]
```

## Flamegraphs

```bash
# One-shot: record + flamegraph
xtrace ./my_app | trace-flamegraph - --open

# From existing trace
./scripts/trace-flamegraph.sh recording.trace -w 2400 --open

# Time window only
./scripts/trace-flamegraph.sh recording.trace --time-range 3.2s-3.5s --open

# Differential (red=hotter, blue=cooler)
./scripts/trace-diff-flamegraph.sh before.trace after.trace --open

# Interactive (speedscope — best for human analysis)
xtrace ./my_app | trace-speedscope -
```

## Pipe Examples

```bash
# Build → profile → flamegraph
make -j8 && xtrace ./build/app | trace-flamegraph - -o profile.svg --open

# Profile → drill into spike → flamegraph of just that window
TRACE=$(xtrace -d 10 ./my_app)
./scripts/trace-analyze.py timeline "$TRACE" --window 100ms
./scripts/trace-flamegraph.sh "$TRACE" --time-range 3.2s-3.5s --open

# Profile → JSON summary for scripting
xtrace --no-summary ./my_app | xargs ./scripts/trace-analyze.py summary --json >profile.json

# Quick check with sample (no Xcode needed)
./scripts/sample-quick.sh MyApp 5
```

## Time Resolution & Confidence

- **Time Profiler**: 1ms sampling, nanosecond timestamps
- **Processor Trace**: instruction-level (every branch), needs Developer Tools enabled in System Settings
- Timeline buckets: as fine as 1ms, but need ~100ms for statistical reliability at 1ms sampling
- `--adaptive` mode auto-sizes windows and detects phase transitions

## Interpreting Results

| Pattern | Meaning | Action |
|---|---|---|
| High self time | Function body is the bottleneck | Optimize algorithm, data layout |
| High inclusive, low self | Calls something expensive | Look at callees |
| `<deduplicated_symbol>` | Compiler-merged function bodies | Normal for V8/system code |
| `0x1a2b3c...` addresses | Missing debug symbols | Rebuild with `-g` |
| `_platform_mem*` | Memory operations dominating | Check data layout, sizes |
| `malloc`/`free` heavy | Allocation churn | Pool, arena, or reduce allocations |

## Troubleshooting

| Problem | Fix |
|---|---|
| `xctrace not found` | `xcode-select --install` |
| No samples | Ensure workload is CPU-active during recording |
| Unsymbolicated frames | Rebuild with `-g`, ensure `.dSYM` present |
| Processor Trace errors | System Settings → Privacy & Security → Developer Tools |
| `inferno not found` | `cargo install inferno` |
| `speedscope not found` | `npm install -g speedscope` |
| SVG opens in wrong app | Scripts use `open -a Safari`; set browser as default for .svg |
