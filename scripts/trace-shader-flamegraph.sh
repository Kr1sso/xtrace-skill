#!/bin/bash
# trace-shader-flamegraph.sh — Generate a shader flamegraph from an Instruments .trace
set -eo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

usage() {
    cat >&2 <<'EOF'
Usage: trace-shader-flamegraph.sh [options] <trace-file>

Generate an SVG shader flamegraph from Metal shader-profiler rows inside an Instruments .trace.
For the interactive shader speedscope view, use trace-shader-speedscope.sh.

Uses the best available tool:
  1. inferno-flamegraph  (cargo install inferno)
  2. flamegraph.pl       (brendangregg/FlameGraph)
  3. trace-shader.py flamegraph (built-in fallback)

Options:
  -o, --output FILE     Output SVG path (default: shader-flamegraph.svg)
  -t, --title TEXT      Chart title (default: auto from trace)
  -w, --width PX        SVG width in pixels (default: 1400)
  --process NAME        Optional process filter override
  --stage NAME          Filter to shader stage substring
  --shader NAME         Filter to shader name substring
  --time-range RANGE    Analyze only a time window (e.g. '2s-3s')
  --tool TOOL           Force a specific tool: inferno, flamegraph.pl, builtin
  -h, --help            Show this help

Examples:
  trace-shader-flamegraph.sh recording.trace -o shader.svg
  trace-shader-flamegraph.sh --stage fragment recording.trace
  trace-shader-speedscope.sh recording.trace
EOF
    exit "${1:-1}"
}

OUTPUT="shader-flamegraph.svg"
TITLE=""
WIDTH=1400
PROCESS=""
STAGE=""
SHADER=""
TIME_RANGE=""
FORCE_TOOL=""
TRACE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)   OUTPUT="$2"; shift 2 ;;
        -t|--title)    TITLE="$2"; shift 2 ;;
        -w|--width)    WIDTH="$2"; shift 2 ;;
        --process)     PROCESS="$2"; shift 2 ;;
        --stage)       STAGE="$2"; shift 2 ;;
        --shader)      SHADER="$2"; shift 2 ;;
        --time-range)  TIME_RANGE="$2"; shift 2 ;;
        --tool)        FORCE_TOOL="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        -)             TRACE_FILE="-"; shift ;;
        -*)            echo "Error: Unknown option: $1" >&2; usage 1 ;;
        *)             TRACE_FILE="$1"; shift ;;
    esac
done

if [ "$TRACE_FILE" = "-" ]; then
    TRACE_FILE=$(head -1 | tr -d '\n\r')
fi

if [ -z "$TRACE_FILE" ]; then
    echo "Error: No trace file specified." >&2
    usage 1
fi

if [ ! -e "$TRACE_FILE" ]; then
    echo "Error: Trace file not found: $TRACE_FILE" >&2
    exit 1
fi

if [ -z "$TITLE" ]; then
    TITLE="Shader Flamegraph — $(basename "$TRACE_FILE" .trace)"
fi

TOOL=""
if [ -n "$FORCE_TOOL" ]; then
    TOOL="$FORCE_TOOL"
else
    if command -v inferno-flamegraph &>/dev/null; then
        TOOL="inferno"
    elif command -v flamegraph.pl &>/dev/null; then
        TOOL="flamegraph.pl"
    else
        TOOL="builtin"
    fi
fi

echo "Tool: $TOOL" >&2

FILTER_ARGS=()
[ -n "$PROCESS" ]    && FILTER_ARGS+=(--process "$PROCESS")
[ -n "$STAGE" ]      && FILTER_ARGS+=(--stage "$STAGE")
[ -n "$SHADER" ]     && FILTER_ARGS+=(--shader "$SHADER")
[ -n "$TIME_RANGE" ] && FILTER_ARGS+=(--time-range "$TIME_RANGE")

case "$TOOL" in
    inferno)
        python3 "$SCRIPT_DIR/trace-shader.py" collapsed "$TRACE_FILE" "${FILTER_ARGS[@]}" \
            | inferno-flamegraph --title "$TITLE" --width "$WIDTH" > "$OUTPUT"
        ;;
    flamegraph.pl)
        python3 "$SCRIPT_DIR/trace-shader.py" collapsed "$TRACE_FILE" "${FILTER_ARGS[@]}" \
            | flamegraph.pl --title "$TITLE" --width "$WIDTH" > "$OUTPUT"
        ;;
    builtin)
        python3 "$SCRIPT_DIR/trace-shader.py" flamegraph "$TRACE_FILE" -o "$OUTPUT" -t "$TITLE" -w "$WIDTH" "${FILTER_ARGS[@]}"
        ;;
    *)
        echo "Error: Unknown tool: $TOOL" >&2
        echo "Available: inferno, flamegraph.pl, builtin" >&2
        exit 1
        ;;
esac

if [ -f "$OUTPUT" ]; then
    SIZE=$(du -sh "$OUTPUT" 2>/dev/null | cut -f1)
    echo "" >&2
    echo "Shader flamegraph: $OUTPUT ($SIZE)" >&2
else
    echo "Error: Failed to generate shader flamegraph" >&2
    exit 1
fi
