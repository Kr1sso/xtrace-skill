#!/bin/bash
# trace-shader-speedscope.sh — Open shader collapsed stacks in speedscope
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
Usage: trace-shader-speedscope.sh [options] <trace-file>

Open shader collapsed stacks from an Instruments .trace in speedscope.
This is the interactive counterpart to trace-shader-flamegraph.sh.

Options:
  -o, --output FILE     Write collapsed shader stacks to FILE before opening speedscope
  --process NAME        Optional process filter override
  --stage NAME          Filter to shader stage substring
  --shader NAME         Filter to shader name substring
  --time-range RANGE    Analyze only a time window (e.g. '2s-3s')
  -h, --help            Show this help

Requires: speedscope (npm install -g speedscope)

Examples:
  trace-shader-speedscope.sh recording.trace
  trace-shader-speedscope.sh --stage fragment recording.trace
  trace-shader-speedscope.sh --shader pbrFragment recording.trace
EOF
    exit "${1:-1}"
}

OUTPUT=""
PROCESS=""
STAGE=""
SHADER=""
TIME_RANGE=""
TRACE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)   OUTPUT="$2"; shift 2 ;;
        --process)     PROCESS="$2"; shift 2 ;;
        --stage)       STAGE="$2"; shift 2 ;;
        --shader)      SHADER="$2"; shift 2 ;;
        --time-range)  TIME_RANGE="$2"; shift 2 ;;
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

if ! command -v speedscope &>/dev/null; then
    echo "Error: speedscope not found." >&2
    echo "Install with: npm install -g speedscope" >&2
    exit 1
fi

FILTER_ARGS=()
[ -n "$PROCESS" ]    && FILTER_ARGS+=(--process "$PROCESS")
[ -n "$STAGE" ]      && FILTER_ARGS+=(--stage "$STAGE")
[ -n "$SHADER" ]     && FILTER_ARGS+=(--shader "$SHADER")
[ -n "$TIME_RANGE" ] && FILTER_ARGS+=(--time-range "$TIME_RANGE")

if [ -n "$OUTPUT" ]; then
    TMPFILE="$OUTPUT"
    mkdir -p "$(dirname "$TMPFILE")"
else
    TMPFILE=$(mktemp /tmp/trace_shader_collapsed_XXXXXX.txt)
    trap 'rm -f "$TMPFILE"' EXIT
fi

echo "Exporting shader collapsed stacks..." >&2
python3 "$SCRIPT_DIR/trace-shader.py" collapsed "$TRACE_FILE" "${FILTER_ARGS[@]}" > "$TMPFILE"

STACK_COUNT=$(wc -l < "$TMPFILE" | tr -d ' ')
echo "Opening shader speedscope with $STACK_COUNT unique stacks..." >&2
[ -n "$OUTPUT" ] && echo "Collapsed shader stacks: $TMPFILE" >&2
speedscope "$TMPFILE"
