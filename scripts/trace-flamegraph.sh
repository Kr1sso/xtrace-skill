#!/bin/bash
# trace-flamegraph.sh — Generate a flamegraph from a .trace file
# Uses inferno (preferred), flamegraph.pl (fallback), or built-in generator (last resort)
set -eo pipefail

# Resolve through symlinks to find the real scripts directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: trace-flamegraph.sh [options] <trace-file>

Generate an SVG flamegraph from an Instruments .trace file.
For interactive viewing, use trace-speedscope.sh instead.

Uses the best available tool:
  1. inferno-flamegraph  (cargo install inferno)     — best quality
  2. flamegraph.pl       (brendangregg/FlameGraph)   — classic
  3. built-in generator  (trace-analyze.py)           — zero-dependency fallback

Options:
  -o, --output FILE     Output SVG path (default: flamegraph.svg)
  -t, --title TEXT      Chart title (default: auto from trace)
  -w, --width PX        SVG width in pixels (default: 1200)
  --time-range RANGE    Analyze only a time window (e.g. '2.5s-3.0s')
  --process NAME        Filter to a specific process
  --thread NAME         Filter to a specific thread
  --color-by SCHEME     Color: 'module' or 'heat' (default: heat, inferno ignores this)
  --tool TOOL           Force a specific tool: inferno, flamegraph.pl, builtin
  -h, --help            Show this help

Examples:
  trace-flamegraph.sh recording.trace -o profile.svg
  trace-flamegraph.sh -o spike.svg --time-range 2s-5s recording.trace
  xtrace ./app | trace-speedscope -     # ← for interactive viewing
EOF
    exit "${1:-1}"
}

# ── Defaults ─────────────────────────────────────────────────────────────────
OUTPUT="flamegraph.svg"
TITLE=""
WIDTH=1200
TIME_RANGE=""
PROCESS=""
THREAD=""
COLOR_BY="heat"
FORCE_TOOL=""
TRACE_FILE=""

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)   OUTPUT="$2"; shift 2 ;;
        -t|--title)    TITLE="$2"; shift 2 ;;
        -w|--width)    WIDTH="$2"; shift 2 ;;
        --time-range)  TIME_RANGE="$2"; shift 2 ;;
        --process)     PROCESS="$2"; shift 2 ;;
        --thread)      THREAD="$2"; shift 2 ;;
        --color-by)    COLOR_BY="$2"; shift 2 ;;
        --tool)        FORCE_TOOL="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        -)             TRACE_FILE="-"; shift ;;
        -*)            echo "Error: Unknown option: $1" >&2; usage 1 ;;
        *)             TRACE_FILE="$1"; shift ;;
    esac
done

# Support piping: trace ./app | trace-flamegraph -
if [ "$TRACE_FILE" = "-" ]; then
    TRACE_FILE=$(head -1 | tr -d '[:space:]')
fi

if [ -z "$TRACE_FILE" ]; then
    echo "Error: No trace file specified." >&2
    usage 1
fi

if [ ! -e "$TRACE_FILE" ]; then
    echo "Error: Trace file not found: $TRACE_FILE" >&2
    exit 1
fi

# ── Auto-detect title ────────────────────────────────────────────────────────
if [ -z "$TITLE" ]; then
    TITLE="Flamegraph — $(basename "$TRACE_FILE" .trace)"
fi

# ── Select tool ──────────────────────────────────────────────────────────────
TOOL=""
if [ -n "$FORCE_TOOL" ]; then
    TOOL="$FORCE_TOOL"
else
    if command -v inferno-flamegraph &>/dev/null && command -v inferno-collapse-xctrace &>/dev/null; then
        TOOL="inferno"
    elif command -v flamegraph.pl &>/dev/null; then
        TOOL="flamegraph.pl"
    else
        TOOL="builtin"
    fi
fi

echo "Tool: $TOOL" >&2

# ── Generate flamegraph ──────────────────────────────────────────────────────
case "$TOOL" in
    inferno)
        # inferno has native xctrace support — best path
        # If we need filtering (time-range, process, thread), use our collapsed output
        if [ -n "$TIME_RANGE" ] || [ -n "$PROCESS" ] || [ -n "$THREAD" ]; then
            echo "Using trace-analyze.py collapsed (filtered) → inferno-flamegraph" >&2
            FILTER_ARGS=()
            [ -n "$TIME_RANGE" ] && FILTER_ARGS+=(--time-range "$TIME_RANGE")
            [ -n "$PROCESS" ]    && FILTER_ARGS+=(--process "$PROCESS")
            [ -n "$THREAD" ]     && FILTER_ARGS+=(--thread "$THREAD")

            python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_FILE" "${FILTER_ARGS[@]}" \
                | inferno-flamegraph \
                    --title "$TITLE" \
                    --width "$WIDTH" \
                > "$OUTPUT"
        else
            echo "Using xctrace export → inferno-collapse-xctrace → inferno-flamegraph" >&2
            xctrace export --input "$TRACE_FILE" \
                --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
                | inferno-collapse-xctrace \
                | inferno-flamegraph \
                    --title "$TITLE" \
                    --width "$WIDTH" \
                > "$OUTPUT"
        fi
        ;;

    flamegraph.pl)
        echo "Using trace-analyze.py collapsed → flamegraph.pl" >&2
        FILTER_ARGS=()
        [ -n "$TIME_RANGE" ] && FILTER_ARGS+=(--time-range "$TIME_RANGE")
        [ -n "$PROCESS" ]    && FILTER_ARGS+=(--process "$PROCESS")
        [ -n "$THREAD" ]     && FILTER_ARGS+=(--thread "$THREAD")

        python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_FILE" "${FILTER_ARGS[@]}" \
            | flamegraph.pl \
                --title "$TITLE" \
                --width "$WIDTH" \
            > "$OUTPUT"
        ;;

    builtin)
        echo "Using built-in SVG generator (install inferno for better results)" >&2
        FLAME_ARGS=(-o "$OUTPUT" --title "$TITLE" --width "$WIDTH" --color-by "$COLOR_BY")
        [ -n "$TIME_RANGE" ] && FLAME_ARGS+=(--time-range "$TIME_RANGE")
        [ -n "$PROCESS" ]    && FLAME_ARGS+=(--process "$PROCESS")
        [ -n "$THREAD" ]     && FLAME_ARGS+=(--thread "$THREAD")

        python3 "$SCRIPT_DIR/trace-analyze.py" flamegraph "$TRACE_FILE" "${FLAME_ARGS[@]}"
        ;;

    *)
        echo "Error: Unknown tool: $TOOL" >&2
        echo "Available: inferno, flamegraph.pl, builtin" >&2
        exit 1
        ;;
esac

# ── Report ───────────────────────────────────────────────────────────────────
if [ -f "$OUTPUT" ]; then
    SIZE=$(du -sh "$OUTPUT" 2>/dev/null | cut -f1)
    echo "" >&2
    echo "Flamegraph: $OUTPUT ($SIZE)" >&2
else
    echo "Error: Failed to generate flamegraph" >&2
    exit 1
fi
