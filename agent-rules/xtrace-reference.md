# xtrace — macOS CPU Profiling Toolchain

Profile any command by prefixing it with `xtrace` (like `time`). Records an Instruments trace, prints a summary to stderr, outputs the trace file path to stdout.

## Core Usage

```bash
xtrace ./my_app                                    # record + print summary
xtrace -d 10 ./my_app                             # 10 second trace
TRACE=$(xtrace -d 10 ./my_app)                    # save trace path
```

All analysis tools accept `-` to read the trace path from stdin:
```bash
xtrace ./app | trace-flamegraph - --open           # → flamegraph in browser
xtrace ./app | trace-speedscope -                  # → interactive web UI
xtrace ./app | trace-analyze.py summary - --json   # → JSON for scripting
```

## Tools

| Command | Purpose |
|---|---|
| `xtrace` | Record + summarize. Prefix any command. |
| `trace-record.sh` | Record with attach (`-p PID`, `-n name`), `--wait-for`, system-wide (`-a`), templates (`-t`) |
| `trace-analyze.py summary <trace>` | Ranked hotspot list. `--top N`, `--by self\|total`, `--json` |
| `trace-analyze.py timeline <trace>` | Time-bucketed view. `--window 100ms`, `--adaptive` |
| `trace-analyze.py calltree <trace>` | Call hierarchy. `--depth N`, `--min-pct PCT` |
| `trace-analyze.py collapsed <trace>` | Universal `frame;frame count` format for flamegraph tools |
| `trace-analyze.py diff <a.json> <b.json>` | Compare two `summary --json` outputs |
| `trace-flamegraph.sh <trace>` | SVG flamegraph. `-w 2400`, `--open`, `--time-range` |
| `trace-speedscope.sh <trace>` | Interactive web UI (best for human analysis) |
| `trace-diff-flamegraph.sh <a> <b>` | Red/blue differential flamegraph |
| `sample-quick.sh <pid\|name>` | Lightweight profiling (no Xcode needed) |

All trace-analyze.py subcommands support: `--process NAME`, `--thread NAME`, `--time-range START-END`

## Dev Loop

```bash
BASELINE=$(xtrace -d 10 ./build/my_app)
trace-analyze.py summary "$BASELINE" --json > /tmp/before.json
# → fix hotspot, rebuild
AFTER=$(xtrace -d 10 ./build/my_app)
trace-analyze.py summary "$AFTER" --json > /tmp/after.json
trace-analyze.py diff /tmp/before.json /tmp/after.json
```

## Debug Symbols

Without symbols you get hex addresses. Add: `-g` (C/C++), `-Xswiftc -g` (Swift), `CARGO_PROFILE_RELEASE_DEBUG=true` (Rust), `CMAKE_BUILD_TYPE=RelWithDebInfo` (CMake).

## Interpreting Results

- **High self time** → function body is the bottleneck, optimize it directly
- **High inclusive, low self** → calls something expensive, look at callees
- **`<deduplicated_symbol>`** → compiler-merged bodies, normal for V8/system code
- **`0x1a2b3c...`** → missing debug symbols, rebuild with `-g`
- **`malloc`/`free` heavy** → allocation churn, use pools or reduce allocations
