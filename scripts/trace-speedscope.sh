#!/bin/bash
# trace-speedscope.sh — Open a .trace file in speedscope for interactive analysis
set -eo pipefail

# Resolve through symlinks to find the real scripts directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

usage() {
    cat >&2 <<'EOF'
Usage: trace-speedscope.sh [options] <trace-file>

Open an Instruments .trace file in speedscope for interactive profiling.
Speedscope provides: left-heavy view, sandwich view, time-ordered view, zoom/pan.

Options:
  --time-range RANGE    Analyze only a time window (e.g. '2.5s-3.0s')
  --process NAME        Filter to a specific process
  --thread NAME         Filter to a specific thread
  -h, --help            Show this help

Requires: speedscope (npm install -g speedscope)

Examples:
  trace-speedscope.sh recording.trace
  trace-speedscope.sh --time-range 2s-5s recording.trace
  trace-speedscope.sh --thread "Main Thread" recording.trace
EOF
    exit "${1:-1}"
}

TIME_RANGE=""
PROCESS=""
THREAD=""
TRACE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --time-range)  TIME_RANGE="$2"; shift 2 ;;
        --process)     PROCESS="$2"; shift 2 ;;
        --thread)      THREAD="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        -)             TRACE_FILE="-"; shift ;;
        -*)            echo "Error: Unknown option: $1" >&2; usage 1 ;;
        *)             TRACE_FILE="$1"; shift ;;
    esac
done

# Support piping: trace ./app | trace-speedscope -
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

# Generate collapsed stacks (with optional filters)
FILTER_ARGS=()
[ -n "$TIME_RANGE" ] && FILTER_ARGS+=(--time-range "$TIME_RANGE")
[ -n "$PROCESS" ]    && FILTER_ARGS+=(--process "$PROCESS")
[ -n "$THREAD" ]     && FILTER_ARGS+=(--thread "$THREAD")

TMPFILE=$(mktemp /tmp/trace_collapsed_XXXXXX.txt)
trap 'rm -f "$TMPFILE"' EXIT

echo "Exporting collapsed stacks..." >&2
python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_FILE" "${FILTER_ARGS[@]}" > "$TMPFILE"

STACK_COUNT=$(wc -l < "$TMPFILE" | tr -d ' ')
echo "Opening speedscope with $STACK_COUNT unique stacks..." >&2
speedscope "$TMPFILE"
