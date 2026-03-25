#!/bin/bash
# trace-diff-flamegraph.sh — Generate a differential (red/blue) flamegraph between two traces
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
Usage: trace-diff-flamegraph.sh [options] <before.trace> <after.trace>

Generate a differential flamegraph showing what got hotter (red) and cooler (blue).

Options:
  -o, --output FILE     Output SVG path (default: diff_flamegraph.svg)
  -t, --title TEXT      Chart title
  -w, --width PX        SVG width (default: 1200)
  --time-range RANGE    Analyze only a time window in both traces
  --process NAME        Filter to a specific process
  --thread NAME         Filter to a specific thread
  -h, --help            Show this help

Requires: inferno (cargo install inferno)

Examples:
  trace-diff-flamegraph.sh baseline.trace optimized.trace
  trace-diff-flamegraph.sh -o diff.svg -w 2400 baseline.trace optimized.trace
EOF
    exit "${1:-1}"
}

OUTPUT="diff_flamegraph.svg"
TITLE=""
WIDTH=1200
TIME_RANGE=""
PROCESS=""
THREAD=""
BEFORE=""
AFTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)   OUTPUT="$2"; shift 2 ;;
        -t|--title)    TITLE="$2"; shift 2 ;;
        -w|--width)    WIDTH="$2"; shift 2 ;;
        --time-range)  TIME_RANGE="$2"; shift 2 ;;
        --process)     PROCESS="$2"; shift 2 ;;
        --thread)      THREAD="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        -*)            echo "Error: Unknown option: $1" >&2; usage 1 ;;
        *)
            if [ -z "$BEFORE" ]; then
                BEFORE="$1"
            elif [ -z "$AFTER" ]; then
                AFTER="$1"
            else
                echo "Error: Too many arguments." >&2; usage 1
            fi
            shift ;;
    esac
done

if [ -z "$BEFORE" ] || [ -z "$AFTER" ]; then
    echo "Error: Two trace files required (before and after)." >&2
    usage 1
fi

for f in "$BEFORE" "$AFTER"; do
    if [ ! -e "$f" ]; then
        echo "Error: Trace file not found: $f" >&2
        exit 1
    fi
done

if ! command -v inferno-diff-folded &>/dev/null || ! command -v inferno-flamegraph &>/dev/null; then
    echo "Error: inferno not found. Install with: cargo install inferno" >&2
    exit 1
fi

[ -z "$TITLE" ] && TITLE="Diff: $(basename "$BEFORE" .trace) → $(basename "$AFTER" .trace)"

# Build filter args
FILTER_ARGS=()
[ -n "$TIME_RANGE" ] && FILTER_ARGS+=(--time-range "$TIME_RANGE")
[ -n "$PROCESS" ]    && FILTER_ARGS+=(--process "$PROCESS")
[ -n "$THREAD" ]     && FILTER_ARGS+=(--thread "$THREAD")

BEFORE_FOLDED=$(mktemp /tmp/before_XXXXXX.folded)
AFTER_FOLDED=$(mktemp /tmp/after_XXXXXX.folded)
trap 'rm -f "$BEFORE_FOLDED" "$AFTER_FOLDED"' EXIT

echo "Exporting baseline collapsed stacks..." >&2
python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$BEFORE" "${FILTER_ARGS[@]}" > "$BEFORE_FOLDED"

echo "Exporting optimized collapsed stacks..." >&2
python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$AFTER" "${FILTER_ARGS[@]}" > "$AFTER_FOLDED"

echo "Generating differential flamegraph..." >&2
inferno-diff-folded "$BEFORE_FOLDED" "$AFTER_FOLDED" \
    | inferno-flamegraph \
        --title "$TITLE" \
        --width "$WIDTH" \
        --negate \
    > "$OUTPUT"

if [ -f "$OUTPUT" ]; then
    SIZE=$(du -sh "$OUTPUT" 2>/dev/null | cut -f1)
    echo "" >&2
    echo "Diff flamegraph: $OUTPUT ($SIZE)" >&2
    echo "  Red = hotter (regression), Blue = cooler (improvement)" >&2
else
    echo "Error: Failed to generate diff flamegraph." >&2
    exit 1
fi
