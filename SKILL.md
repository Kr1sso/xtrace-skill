---
name: instruments
description: "Profile macOS applications using Instruments/xctrace. Record CPU traces, analyze hotspots, generate flamegraphs, compare profiles, drill into time windows."
---

# Instruments Profiling Skill

Unix-style CPU profiling for macOS. Composable tools that pipe together.

## Quick Start

```bash
xtrace ./my_app                                    # record + print summary
xtrace ./my_app | trace-speedscope -               # → interactive analysis (best)
cmake --build . && xtrace ./build/app              # build then profile
```

`xtrace` records a trace, prints summary to stderr, outputs trace path to stdout. All tools accept `-` to read the trace path from stdin.

## Scripts

| Script | Purpose |
|---|---|
| **`xtrace`** | Record + summarize. Prefix any command. Path to stdout. Auto-fallback for GPU/IO-bound workloads. |
| `trace-record.sh` | Record with full control (attach, wait-for, system-wide, templates) |
| `trace-analyze.py` | Analysis engine: summary, timeline, calltree, collapsed, diff. Reads .trace and sample output. |
| `trace-speedscope.sh` | **Interactive visualization** (speedscope web UI) |
| `trace-flamegraph.sh` | Generate SVG flamegraph file (for sharing/archiving) |
| `trace-diff-flamegraph.sh` | Differential red/blue SVG between two traces |
| `trace-check.sh` | Verify environment |
| `sample-quick.sh` | Lightweight profiling via macOS `sample` (no Xcode needed). Supports `--launch`. |

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

## Dev Loop

```bash
# 1. Profile
BASELINE=$(xtrace -d 10 ./build/my_app --benchmark)
# → reads summary from stderr, e.g. "computeHash() is 24% self time"

# 2. Visualize interactively
trace-speedscope.sh "$BASELINE"

# 3. Save baseline for comparison
./scripts/trace-analyze.py summary "$BASELINE" --json > /tmp/before.json

# 4. Fix the hotspot, rebuild, re-profile
cmake --build .
AFTER=$(xtrace -d 10 ./build/my_app --benchmark)
./scripts/trace-analyze.py summary "$AFTER" --json > /tmp/after.json

# 5. Compare
./scripts/trace-analyze.py diff /tmp/before.json /tmp/after.json
```

### LLM Pattern

```bash
TRACE=$(./scripts/xtrace -d 10 --no-summary ./build/my_app)
./scripts/trace-analyze.py summary "$TRACE" --json --top 20 > profile.json
./scripts/trace-analyze.py calltree "$TRACE" --min-pct 3.0
```

Read the JSON, identify hotspot, make changes, rebuild, re-profile, diff.

## Recording

`xtrace` covers launch mode. For attach/wait/system-wide, use `trace-record.sh`:

```bash
./scripts/trace-record.sh -d 10 -p <PID>                    # attach by PID
./scripts/trace-record.sh -d 10 -n MyApp                    # attach by name
./scripts/trace-record.sh --wait-for MyApp -d 10             # wait for spawn, then attach
./scripts/trace-record.sh --wait-for MyApp --wait-timeout 60 -d 10
./scripts/trace-record.sh -d 10 -a                           # system-wide
./scripts/trace-record.sh -t 'System Trace' -d 10 -- ./app  # different template
```

## Templates

| Template | When | Resolution |
|---|---|---|
| **Time Profiler** | General CPU profiling (default) | 1ms sampling |
| System Trace | Thread contention, syscalls, scheduling | Microsecond |
| Processor Trace | Every function call, instruction-level | Every branch |
| CPU Counters | IPC, cache misses, branch mispredictions | Per-event |
| Allocations | Memory leaks, allocation patterns | Per-allocation |

## Analysis

All subcommands support `--process`, `--thread`, `--time-range`, and `-` for stdin.

### summary
```bash
./scripts/trace-analyze.py summary <trace> [--top N] [--by self|total] [--json]
```

### timeline
```bash
./scripts/trace-analyze.py timeline <trace> [--window SIZE] [--adaptive] [--top N] [--json]
```
Confidence: `██` high (>50 samples), `▓░` medium (20-50), `░░` low (<20). `← SPIKE` = >2× median.

### calltree
```bash
./scripts/trace-analyze.py calltree <trace> [--depth N] [--min-pct PCT]
```

### collapsed
```bash
./scripts/trace-analyze.py collapsed <trace> [--with-module]
```
`frame1;frame2;...frameN count` — universal input for flamegraph tools.

### diff
```bash
./scripts/trace-analyze.py diff <before.json> <after.json> [--threshold PCT]
```

## Visualization

**Interactive (use this):**
```bash
xtrace ./app | trace-speedscope -                        # pipe directly
trace-speedscope.sh /tmp/my.trace                        # from file
trace-speedscope.sh /tmp/my.trace --time-range 3.2s-3.5s # time window
```

Speedscope opens in browser with time-ordered view, left-heavy view, sandwich view, zoom, search.

**SVG files (for sharing/CI/archiving only):**
```bash
trace-flamegraph.sh recording.trace -o profile.svg
trace-diff-flamegraph.sh before.trace after.trace -o diff.svg
```

## Interpreting Results

| Pattern | Meaning | Action |
|---|---|---|
| High self time | Function body is bottleneck | Optimize algorithm, data layout |
| High inclusive, low self | Calls something expensive | Look at callees |
| `<deduplicated_symbol>` | Compiler-merged bodies | Normal for V8/system code |
| `0x1a2b3c...` | Missing debug symbols | Rebuild with `-g` |
| `_platform_mem*` | Memory ops dominating | Check data layout, sizes |
| `malloc`/`free` heavy | Allocation churn | Pool, arena, reduce allocations |

## GPU/IO-Bound Workloads

`xtrace` automatically handles GPU-bound and IO-bound workloads:

1. Records with Time Profiler (captures running threads at 1ms sampling)
2. If the trace has no CPU samples (process spent all time waiting), falls back to macOS `sample` command
3. `sample` captures ALL thread states (running + waiting + blocked), so it always produces data
4. `trace-analyze.py` transparently reads both `.trace` bundles and `sample` output files

```bash
# GPU-bound app — xtrace auto-falls back to sample if needed
xtrace ./build/gpu_app --benchmark

# Or use sample directly for launch + profile
sample-quick.sh --launch -d 10 -- ./build/gpu_app --benchmark

# All analysis tools work on sample output too
trace-analyze.py summary /tmp/sample_gpu_app_*.txt --top 20
trace-analyze.py calltree /tmp/sample_gpu_app_*.txt --min-pct 3
trace-analyze.py collapsed /tmp/sample_gpu_app_*.txt | inferno-flamegraph > flame.svg
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `xctrace not found` | `xcode-select --install` |
| No samples | `xtrace` auto-falls back to `sample`. Or use `sample-quick.sh --launch` directly |
| Unsymbolicated frames | Rebuild with `-g`, ensure `.dSYM` present |
| Processor Trace errors | System Settings → Privacy & Security → Developer Tools |
| Empty trace from GPU app | Normal — Time Profiler only samples running threads. Fallback handles this automatically |
