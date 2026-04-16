#!/bin/bash
# trace-record.sh — Record an Instruments trace using xctrace
# Wraps xctrace record with ergonomic defaults and path resolution.

set -euo pipefail

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: trace-record.sh [options] [-- command args...]

Record an Instruments trace using xctrace.

Options:
  -t, --template NAME     Template name (default: 'Time Profiler')
  -i, --instrument NAME   Add Instrument by name (repeatable). If provided without -t,
                          records a custom instrument set instead of the default template.
  --shader-timeline       Enable Metal Shader Timeline by patching a GPU template on the fly.
                          Best with: -t 'Metal System Trace' or -t 'Game Performance'.
  -d, --duration SECONDS  Time limit (default: 10s). Accepts: 10, 10s, 2.5s, 500ms, 10m
  -o, --output PATH       Output .trace path (auto-generated if omitted)
  -p, --pid PID           Attach to process by PID
  -n, --name NAME         Attach to process by name
  --wait-for NAME         Wait for a process to spawn, then attach
  --wait-timeout SECS     Max seconds to wait (default: 30)
  -a, --all               Trace all processes (system-wide)
  -e, --env KEY=VAL       Environment variable for launched process (repeatable)
  --malloc-logging        Force MallocStackLogging for launched process
  --no-malloc-logging     Disable MallocStackLogging even for memory templates
  --stdout                Forward target stdout to terminal
  --stderr                Forward target stderr to terminal
  -h, --help              Show this help

Examples:
  trace-record.sh -d 10 -- ./my_app --arg1
  trace-record.sh -d 5 -p 12345
  trace-record.sh -t 'System Trace' -d 10 -n MyApp
  trace-record.sh -d 10 -a
  trace-record.sh --wait-for MyApp -d 10       # wait for MyApp to spawn, then profile
  trace-record.sh -t 'Processor Trace' -d 3 -- ./my_binary
  trace-record.sh -e DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib -- ./app
  trace-record.sh --instrument GPU --instrument 'Metal Application' -d 10 -- ./my_metal_app
  trace-record.sh -t 'Game Performance' --instrument 'Metal GPU Counters' -- ./my_game
  trace-record.sh -t 'Metal System Trace' --shader-timeline -d 10 -- ./my_shader_app

Notes:
  - xctrace requires absolute paths for launched binaries (auto-resolved).
  - Exit code 54 from xctrace means the target exited before the time limit — treated as success.
  - The .trace file path is printed to stdout (for scripting). All other output goes to stderr.
EOF
    exit "${1:-1}"
}

# ── Defaults ─────────────────────────────────────────────────────────────────
TEMPLATE="Time Profiler"
TEMPLATE_EXPLICIT=false
INSTRUMENTS=()
DURATION="10s"
OUTPUT=""
PID=""
NAME=""
WAIT_FOR=""
WAIT_TIMEOUT=30
ALL_PROCS=false
ENV_VARS=()
FORWARD_STDOUT=false
FORWARD_STDERR=false
SHADER_TIMELINE=false
BASE_TEMPLATE=""
TEMPLATE_PATCH_TEMP=""
MALLOC_LOGGING=auto
LAUNCH_CMD=()
SUDO_PREFIX=()

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--template)
            TEMPLATE="$2"; TEMPLATE_EXPLICIT=true; shift 2 ;;
        -i|--instrument)
            INSTRUMENTS+=("$2"); shift 2 ;;
        -d|--duration)
            DURATION="$2"; shift 2 ;;
        -o|--output)
            OUTPUT="$2"; shift 2 ;;
        -p|--pid)
            PID="$2"; shift 2 ;;
        -n|--name)
            NAME="$2"; shift 2 ;;
        --wait-for)
            WAIT_FOR="$2"; shift 2 ;;
        --wait-timeout)
            WAIT_TIMEOUT="$2"; shift 2 ;;
        -a|--all)
            ALL_PROCS=true; shift ;;
        -e|--env)
            ENV_VARS+=("$2"); shift 2 ;;
        --shader-timeline)
            SHADER_TIMELINE=true; shift ;;
        --malloc-logging)
            MALLOC_LOGGING=true; shift ;;
        --no-malloc-logging)
            MALLOC_LOGGING=false; shift ;;
        --stdout)
            FORWARD_STDOUT=true; shift ;;
        --stderr)
            FORWARD_STDERR=true; shift ;;
        -h|--help)
            usage 0 ;;
        --)
            shift; LAUNCH_CMD=("$@"); break ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            usage 1 ;;
        *)
            echo "Error: Unexpected argument: $1" >&2
            echo "  Use -- before the command to launch." >&2
            usage 1 ;;
    esac
done

# ── Validate target mode ────────────────────────────────────────────────────
MODE_COUNT=0
[ -n "$PID" ] && ((MODE_COUNT++))
[ -n "$NAME" ] && ((MODE_COUNT++))
[ -n "$WAIT_FOR" ] && ((MODE_COUNT++))
[ "$ALL_PROCS" = true ] && ((MODE_COUNT++))
[ ${#LAUNCH_CMD[@]} -gt 0 ] && ((MODE_COUNT++))

if [ "$MODE_COUNT" -eq 0 ]; then
    echo "Error: No target specified. Use one of: --pid, --name, --wait-for, --all, or -- <command>" >&2
    usage 1
fi

if [ "$MODE_COUNT" -gt 1 ]; then
    echo "Error: Multiple targets specified. Use exactly one of: --pid, --name, --wait-for, --all, or -- <command>" >&2
    exit 1
fi

# ── Wait-for mode: poll until process appears ────────────────────────────────
if [ -n "$WAIT_FOR" ]; then
    echo "Waiting for process '$WAIT_FOR' to appear (timeout: ${WAIT_TIMEOUT}s)..." >&2
    ELAPSED=0
    FOUND_PID=""
    MY_PID=$$
    MY_PPID=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
    while [ "$ELAPSED" -lt "$WAIT_TIMEOUT" ]; do
        FOUND_PID=$(pgrep -x "$WAIT_FOR" 2>/dev/null | head -1 || true)
        if [ -z "$FOUND_PID" ]; then
            # Fallback to pattern match, but exclude our own process tree to avoid
            # matching "trace-record.sh --wait-for MyApp" itself
            FOUND_PID=$(pgrep -f "$WAIT_FOR" 2>/dev/null | grep -v -e "^${MY_PID}$" -e "^${MY_PPID}$" | head -1 || true)
        fi
        if [ -n "$FOUND_PID" ]; then
            echo "Found '$WAIT_FOR' with PID $FOUND_PID" >&2
            PID="$FOUND_PID"
            break
        fi
        sleep 1
        ELAPSED=$((ELAPSED + 1))
    done
    if [ -z "$FOUND_PID" ]; then
        echo "Error: Timed out waiting for '$WAIT_FOR' after ${WAIT_TIMEOUT}s" >&2
        exit 1
    fi
fi

# ── Validate xctrace ────────────────────────────────────────────────────────
if ! command -v xctrace &>/dev/null; then
    echo "Error: xctrace not found. Install Xcode or Command Line Tools." >&2
    echo "  Run: xcode-select --install" >&2
    exit 1
fi

resolve_template_path() {
    local template="$1"
    local developer_dir instruments_app found

    if [ -f "$template" ]; then
        realpath "$template" 2>/dev/null || echo "$template"
        return 0
    fi

    developer_dir=$(xcode-select -p 2>/dev/null || true)
    if [ -n "$developer_dir" ]; then
        instruments_app="$(cd "$developer_dir/.." 2>/dev/null && pwd)/Applications/Instruments.app"
        if [ -d "$instruments_app" ]; then
            found=$(find "$instruments_app" -type f -name "$template.tracetemplate" 2>/dev/null | head -1 || true)
            if [ -n "$found" ]; then
                echo "$found"
                return 0
            fi
        fi
    fi

    instruments_app="/Applications/Xcode.app/Contents/Applications/Instruments.app"
    found=$(find "$instruments_app" -type f -name "$template.tracetemplate" 2>/dev/null | head -1 || true)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

enable_shader_timeline_template() {
    local base_template="$1"
    local helper_dir helper patched_name patched_template

    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TEMPLATE_PATCH_TEMP=$(mktemp -d "/tmp/trace-template.XXXXXX")
    patched_name="$(basename "$base_template" .tracetemplate)_shader_timeline.tracetemplate"
    patched_template="$TEMPLATE_PATCH_TEMP/$patched_name"

    python3 "$helper_dir/trace-template.py" enable-shader-timeline "$base_template" -o "$patched_template" --quiet
    echo "$patched_template"
}

# If custom instruments were provided without an explicit template, let xctrace
# build a custom recording from the instrument set alone.
if [ ${#INSTRUMENTS[@]} -gt 0 ] && [ "$TEMPLATE_EXPLICIT" = false ]; then
    TEMPLATE=""
fi

# Shader timeline needs a Metal-capable template. If the caller asked for it but
# didn't choose a template explicitly, default to Metal System Trace.
if [ "$SHADER_TIMELINE" = true ] && [ -z "$TEMPLATE" ]; then
    TEMPLATE="Metal System Trace"
fi

# ── Validate template / instruments ─────────────────────────────────────────
if [ -n "$TEMPLATE" ]; then
    if [ ! -e "$TEMPLATE" ] && ! xctrace list templates 2>/dev/null | grep -F "$TEMPLATE" >/dev/null; then
        echo "Error: Unknown template '$TEMPLATE'" >&2
        echo "" >&2
        echo "Available templates:" >&2
        xctrace list templates 2>&1 >&2
        exit 1
    fi
fi

if [ "$SHADER_TIMELINE" = true ]; then
    if [ -z "$TEMPLATE" ]; then
        echo "Error: --shader-timeline requires a Metal-capable template." >&2
        echo "  Try: -t 'Metal System Trace' or -t 'Game Performance'" >&2
        exit 1
    fi

    BASE_TEMPLATE=$(resolve_template_path "$TEMPLATE" || true)
    if [ -z "$BASE_TEMPLATE" ]; then
        echo "Error: Could not resolve template path for '$TEMPLATE' to enable shader timeline." >&2
        exit 1
    fi
    TEMPLATE=$(enable_shader_timeline_template "$BASE_TEMPLATE")
fi

if [ ${#INSTRUMENTS[@]} -gt 0 ]; then
    INSTRUMENT_LIST=$(xctrace list instruments 2>/dev/null || true)
    for INSTRUMENT in "${INSTRUMENTS[@]}"; do
        if ! printf '%s\n' "$INSTRUMENT_LIST" | grep -F "$INSTRUMENT" >/dev/null; then
            echo "Error: Unknown instrument '$INSTRUMENT'" >&2
            echo "" >&2
            echo "Available instruments:" >&2
            xctrace list instruments 2>&1 >&2
            exit 1
        fi
    done
fi

# ── Parse duration ───────────────────────────────────────────────────────────
# Accept: 10, 10s, 2.5s, 10m, 500ms — normalize to xctrace integer format
# xctrace requires integer values, so 2.5s → 2500ms, 1.5m → 90s, etc.
parse_duration() {
    local input="$1"
    if [[ "$input" =~ ^([0-9]*\.?[0-9]+)(ms|s|m)?$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        : "${unit:=s}"  # bare number → seconds

        # If the value has a decimal point, convert to a smaller unit
        if [[ "$num" == *.* ]]; then
            case "$unit" in
                ms) # Already smallest unit — truncate to integer
                    num=$(printf "%.0f" "$num")
                    echo "${num}ms" ;;
                s)  # Convert to ms: 2.5s → 2500ms
                    num=$(printf "%.0f" "$(echo "$num * 1000" | bc)")
                    echo "${num}ms" ;;
                m)  # Convert to seconds: 1.5m → 90s
                    num=$(printf "%.0f" "$(echo "$num * 60" | bc)")
                    echo "${num}s" ;;
            esac
        else
            case "$unit" in
                ms) echo "${num}ms" ;;
                m)  echo "${num}m" ;;
                s)  echo "${num}s" ;;
            esac
        fi
    else
        echo "Error: Invalid duration format: '$input'. Use: 10, 10s, 2.5s, 10m, or 500ms" >&2
        exit 1
    fi
}

DURATION=$(parse_duration "$DURATION")

# ── Auto-enable malloc logging for memory templates ──────────────────────────
if [ "$MALLOC_LOGGING" = "auto" ]; then
    case "$TEMPLATE" in
        Allocations|Leaks|"Game Memory")
            MALLOC_LOGGING=true ;;
        *)
            MALLOC_LOGGING=false ;;
    esac
fi

if [ "$MALLOC_LOGGING" = true ] && [ ${#LAUNCH_CMD[@]} -gt 0 ]; then
    ENV_VARS+=("MallocStackLogging=1")
    echo "MallocStackLogging enabled for '$TEMPLATE' template" >&2
fi

# ── Resolve binary path (xctrace requires absolute paths) ───────────────────
if [ ${#LAUNCH_CMD[@]} -gt 0 ]; then
    BINARY="${LAUNCH_CMD[0]}"
    if [[ "$BINARY" != /* ]]; then
        # Try command lookup first (for PATH binaries), then realpath (for ./relative)
        RESOLVED=""
        if command -v "$BINARY" &>/dev/null; then
            RESOLVED=$(command -v "$BINARY")
        elif [ -e "$BINARY" ]; then
            RESOLVED=$(realpath "$BINARY" 2>/dev/null || true)
        fi

        if [ -z "$RESOLVED" ] || [ ! -e "$RESOLVED" ]; then
            echo "Error: Cannot find executable: $BINARY" >&2
            exit 1
        fi

        if [ ! -x "$RESOLVED" ]; then
            echo "Error: Not executable: $RESOLVED" >&2
            exit 1
        fi

        LAUNCH_CMD[0]="$RESOLVED"
    else
        if [ ! -x "$BINARY" ]; then
            echo "Error: Not executable: $BINARY" >&2
            exit 1
        fi
    fi
fi

# ── Generate output path ────────────────────────────────────────────────────
if [ -z "$OUTPUT" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    if [ ${#LAUNCH_CMD[@]} -gt 0 ]; then
        BIN_NAME=$(basename "${LAUNCH_CMD[0]}")
        OUTPUT="trace_${BIN_NAME}_${TIMESTAMP}.trace"
    elif [ -n "$PID" ]; then
        OUTPUT="trace_pid${PID}_${TIMESTAMP}.trace"
    elif [ -n "$NAME" ]; then
        SAFE_NAME=$(echo "$NAME" | tr -cs '[:alnum:]_-' '_')
        OUTPUT="trace_${SAFE_NAME}_${TIMESTAMP}.trace"
    else
        OUTPUT="trace_system_${TIMESTAMP}.trace"
    fi
fi

# ── Build xctrace command ───────────────────────────────────────────────────
CMD=(xctrace record --time-limit "$DURATION" --output "$OUTPUT" --no-prompt)

if [ -n "$TEMPLATE" ]; then
    CMD+=(--template "$TEMPLATE")
fi

if [ ${#INSTRUMENTS[@]} -gt 0 ]; then
    for INSTRUMENT in "${INSTRUMENTS[@]}"; do
        CMD+=(--instrument "$INSTRUMENT")
    done
fi

if [ ${#ENV_VARS[@]} -gt 0 ]; then
    for ENV in "${ENV_VARS[@]}"; do
        CMD+=(--env "$ENV")
    done
fi

[ "$FORWARD_STDOUT" = true ] && CMD+=(--target-stdout -)
[ "$FORWARD_STDERR" = true ] && CMD+=(--target-stderr -)

if [ -n "$PID" ]; then
    CMD+=(--attach "$PID")
elif [ -n "$NAME" ]; then
    CMD+=(--attach "$NAME")
elif [ "$ALL_PROCS" = true ]; then
    CMD+=(--all-processes)
else
    CMD+=(--launch -- "${LAUNCH_CMD[@]}")
fi

# ── Print plan ───────────────────────────────────────────────────────────────
DISPLAY_TEMPLATE="$TEMPLATE"
if [ -n "$BASE_TEMPLATE" ]; then
    DISPLAY_TEMPLATE="$BASE_TEMPLATE"
fi
if [ "$SHADER_TIMELINE" = true ]; then
    DISPLAY_TEMPLATE="$DISPLAY_TEMPLATE + Shader Timeline"
fi

if [ -n "$TEMPLATE" ] && [ ${#INSTRUMENTS[@]} -gt 0 ]; then
    echo "Recording with template '$DISPLAY_TEMPLATE' + instruments (${INSTRUMENTS[*]}) for $DURATION..." >&2
elif [ -n "$TEMPLATE" ]; then
    echo "Recording with '$DISPLAY_TEMPLATE' for $DURATION..." >&2
elif [ ${#INSTRUMENTS[@]} -gt 0 ]; then
    echo "Recording with instruments (${INSTRUMENTS[*]}) for $DURATION..." >&2
else
    echo "Recording with default configuration for $DURATION..." >&2
fi
echo "Output: $OUTPUT" >&2
echo "Command: ${CMD[*]}" >&2
echo "" >&2

# ── Execute ──────────────────────────────────────────────────────────────────
# If attaching to a root-owned process, acquire sudo via GUI dialog
SUDO_PREFIX=()
if [ -n "$PID" ]; then
    HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sudo-askpass.sh"
    if [ -f "$HELPER" ]; then
        source "$HELPER"
        if process_needs_sudo "$PID"; then
            ensure_sudo_if_needed "$PID"
            SUDO_PREFIX=(sudo)
        fi
    fi
elif [ -n "$NAME" ]; then
    # Resolve name to PID to check ownership
    RESOLVED_PID=$(pgrep -x "$NAME" 2>/dev/null | head -1 || true)
    if [ -n "$RESOLVED_PID" ]; then
        HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sudo-askpass.sh"
        if [ -f "$HELPER" ]; then
            source "$HELPER"
            if process_needs_sudo "$RESOLVED_PID"; then
                ensure_sudo_if_needed "$RESOLVED_PID"
                SUDO_PREFIX=(sudo)
            fi
        fi
    fi
fi

# Capture xctrace output to parse for the actual output path
XCTRACE_OUTPUT_FILE=$(mktemp)

_cleanup() {
    # Kill any xctrace child processes still running (e.g. if script is killed externally)
    local kids
    kids=$(jobs -p 2>/dev/null) || true
    if [ -n "$kids" ]; then
        kill $kids 2>/dev/null || true
        wait $kids 2>/dev/null || true
    fi
    rm -f "$XCTRACE_OUTPUT_FILE"
    if [ -n "$TEMPLATE_PATCH_TEMP" ] && [ -d "$TEMPLATE_PATCH_TEMP" ]; then
        rm -rf "$TEMPLATE_PATCH_TEMP"
    fi
}
trap _cleanup EXIT INT TERM

set +e
if [ ${#SUDO_PREFIX[@]} -gt 0 ]; then
    "${SUDO_PREFIX[@]}" "${CMD[@]}" 2>&1 | tee "$XCTRACE_OUTPUT_FILE" >&2
else
    "${CMD[@]}" 2>&1 | tee "$XCTRACE_OUTPUT_FILE" >&2
fi
EXIT_CODE=${PIPESTATUS[0]}
set -e

# Exit code 54 means the target process exited before the time limit — that's OK
if [ "$EXIT_CODE" -ne 0 ] && [ "$EXIT_CODE" -ne 54 ]; then
    echo "Error: xctrace exited with code $EXIT_CODE" >&2
    exit "$EXIT_CODE"
fi

# ── Find actual output file ─────────────────────────────────────────────────
# xctrace may print: "Output file saved as: /path/to/file.trace"
ACTUAL_OUTPUT=""

# Try to parse from xctrace output
SAVED_LINE=$(grep -i "Output file saved as" "$XCTRACE_OUTPUT_FILE" 2>/dev/null || true)
if [ -n "$SAVED_LINE" ]; then
    # Extract path after the colon
    ACTUAL_OUTPUT=$(echo "$SAVED_LINE" | sed 's/.*Output file saved as:[[:space:]]*//' | tr -d '\r')
fi

# Fall back to the requested output path
if [ -z "$ACTUAL_OUTPUT" ] || [ ! -e "$ACTUAL_OUTPUT" ]; then
    if [ -e "$OUTPUT" ]; then
        ACTUAL_OUTPUT="$OUTPUT"
    fi
fi

# If still not found, look for recently created .trace files in the output directory
if [ -z "$ACTUAL_OUTPUT" ] || [ ! -e "$ACTUAL_OUTPUT" ]; then
    OUTPUT_DIR=$(dirname "$OUTPUT")
    [ -z "$OUTPUT_DIR" ] && OUTPUT_DIR="."
    RECENT=$(find "$OUTPUT_DIR" -maxdepth 1 -name "*.trace" -newer "$XCTRACE_OUTPUT_FILE" 2>/dev/null | head -1)
    if [ -n "$RECENT" ]; then
        ACTUAL_OUTPUT="$RECENT"
    fi
fi

if [ -z "$ACTUAL_OUTPUT" ] || [ ! -e "$ACTUAL_OUTPUT" ]; then
    echo "Warning: Could not locate output .trace file" >&2
    exit 1
fi

# ── Print trace path to stdout (for scripting) ──────────────────────────────
# Convert to absolute path for unambiguous reference
ACTUAL_OUTPUT=$(cd "$(dirname "$ACTUAL_OUTPUT")" && echo "$(pwd)/$(basename "$ACTUAL_OUTPUT")")
echo "$ACTUAL_OUTPUT"

# ── Extract target PID ───────────────────────────────────────────────────────
TARGET_PID=""
PID_LINE=$(grep -i 'Launching process\|pid:' "$XCTRACE_OUTPUT_FILE" 2>/dev/null | head -1 || true)
if [ -n "$PID_LINE" ]; then
    TARGET_PID=$(echo "$PID_LINE" | grep -oE 'pid:?\s*[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
fi
if [ -n "$PID" ]; then
    TARGET_PID="$PID"
fi

# Write PID to sidecar file for downstream tools
if [ -n "$TARGET_PID" ]; then
    echo "$TARGET_PID" > "${ACTUAL_OUTPUT}.pid" 2>/dev/null || true
fi

# Print size info to stderr
HAS_METAL_INSTRUMENTS=false
for INSTRUMENT in "${INSTRUMENTS[@]-}"; do
    LOWER_INSTRUMENT=$(printf '%s' "$INSTRUMENT" | tr '[:upper:]' '[:lower:]')
    case "$LOWER_INSTRUMENT" in
        *metal*|*gpu*|*realitykit*)
            HAS_METAL_INSTRUMENTS=true
            break
            ;;
    esac
done

TRACE_SIZE=$(du -sh "$ACTUAL_OUTPUT" 2>/dev/null | cut -f1)
ANALYZE_TEMPLATE="$TEMPLATE"
if [ -n "$BASE_TEMPLATE" ]; then
    ANALYZE_TEMPLATE="$(basename "$BASE_TEMPLATE" .tracetemplate)"
fi

echo "" >&2
echo "Trace saved: $ACTUAL_OUTPUT ($TRACE_SIZE)" >&2
case "$ANALYZE_TEMPLATE" in
    Allocations|Leaks|"Game Memory")
        echo "Analyze with: trace-memory.py summary -- <command>" >&2
        echo "  Or attach: trace-memory.py summary -p <PID>" >&2
        echo "  Leak check: trace-memory.py leaks -- <command>" >&2
        echo "  Open in Instruments.app for full allocation details" >&2
        ;;
    "Metal System Trace"|"Game Performance"|"Game Performance Overview"|"RealityKit Trace")
        echo "Analyze with: trace-gpu.py \"$ACTUAL_OUTPUT\"" >&2
        echo "  CPU side (when present): trace-analyze.py summary \"$ACTUAL_OUTPUT\"" >&2
        if [ "$SHADER_TIMELINE" = true ]; then
            echo "  Shader hotspots: trace-shader.py hotspots \"$ACTUAL_OUTPUT\"" >&2
            echo "  Shader flamegraph: trace-shader-flamegraph.sh \"$ACTUAL_OUTPUT\" -o shader.svg" >&2
            echo "  Shader speedscope: trace-shader-speedscope.sh \"$ACTUAL_OUTPUT\"" >&2
        fi
        ;;
    *)
        if [ "$HAS_METAL_INSTRUMENTS" = true ]; then
            echo "Analyze with: trace-gpu.py \"$ACTUAL_OUTPUT\"" >&2
            echo "  CPU side (when present): trace-analyze.py summary \"$ACTUAL_OUTPUT\"" >&2
            if [ "$SHADER_TIMELINE" = true ]; then
                echo "  Shader hotspots: trace-shader.py hotspots \"$ACTUAL_OUTPUT\"" >&2
                echo "  Shader flamegraph: trace-shader-flamegraph.sh \"$ACTUAL_OUTPUT\" -o shader.svg" >&2
                echo "  Shader speedscope: trace-shader-speedscope.sh \"$ACTUAL_OUTPUT\"" >&2
            fi
        else
            echo "Analyze with: trace-analyze.py \"$ACTUAL_OUTPUT\"" >&2
        fi
        ;;
esac

exit 0
