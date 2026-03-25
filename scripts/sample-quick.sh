#!/bin/bash
# sample-quick.sh — Lightweight CPU profiling using macOS `sample` command
# No Xcode required. Works with SIP enabled.

set -euo pipefail

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: sample-quick.sh <pid|process-name> [duration_seconds] [sampling_interval_ms] [output_file]

Lightweight CPU profiling using macOS sample command.
No Xcode required. Default: 10s duration, 1ms interval.

Arguments:
  pid|process-name    Target process (PID number or name to look up)
  duration_seconds    How long to sample (default: 10)
  sampling_interval_ms  Sampling interval in milliseconds (default: 1)
  output_file         Output file path (auto-generated if omitted)

Examples:
  sample-quick.sh 12345
  sample-quick.sh MyApp 5
  sample-quick.sh MyApp 10 1 profile.txt
  sample-quick.sh Safari 3 1

Notes:
  - The output file path is printed to stdout (for scripting).
  - The call graph summary is printed to stderr.
  - Use -mayDie flag to handle processes that may exit during sampling.
EOF
    exit "${1:-1}"
}

# ── Color codes ──────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Parse arguments ──────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Error: Target process required." >&2
    usage 1
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage 0
fi

TARGET="$1"
DURATION="${2:-10}"
INTERVAL="${3:-1}"
OUTPUT="${4:-}"

# ── Validate sample command ──────────────────────────────────────────────────
if ! command -v sample &>/dev/null; then
    echo "Error: 'sample' command not found." >&2
    echo "  The sample command should be available on all macOS installations." >&2
    exit 1
fi

# ── Resolve process name to PID ─────────────────────────────────────────────
PROC_NAME=""
if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    PROC_NAME="$TARGET"
    # Try exact match first
    PID=$(pgrep -x "$TARGET" 2>/dev/null | head -1 || true)
    if [ -z "$PID" ]; then
        # Try partial/pattern match
        PID=$(pgrep -f "$TARGET" 2>/dev/null | head -1 || true)
    fi
    if [ -z "$PID" ]; then
        echo "Error: Process '$TARGET' not found" >&2
        echo "  Make sure the process is running. Check with: ps aux | grep '$TARGET'" >&2
        exit 1
    fi
    echo "Found process '$TARGET' with PID $PID" >&2
    TARGET="$PID"
fi

# ── Validate PID is running ─────────────────────────────────────────────────
if ! kill -0 "$TARGET" 2>/dev/null; then
    echo "Error: PID $TARGET is not running or not accessible" >&2
    echo "  You may need to run with sudo for processes owned by other users." >&2
    exit 1
fi

# Get the process name for display if we don't have it yet
if [ -z "$PROC_NAME" ]; then
    PROC_NAME=$(ps -p "$TARGET" -o comm= 2>/dev/null | xargs basename 2>/dev/null || echo "pid$TARGET")
fi

# ── Generate output filename ────────────────────────────────────────────────
if [ -z "$OUTPUT" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    SAFE_NAME=$(echo "$PROC_NAME" | tr -cs '[:alnum:]_-' '_')
    OUTPUT="sample_${SAFE_NAME}_${TIMESTAMP}.txt"
fi

# ── Run sample ───────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}Sampling${NC} PID $TARGET ($PROC_NAME) for ${DURATION}s at ${INTERVAL}ms intervals..." >&2
echo "Output: $OUTPUT" >&2
echo "" >&2

set +e
sample "$TARGET" "$DURATION" "$INTERVAL" -file "$OUTPUT" -mayDie 2>&1 | \
    grep -v "^$" >&2
SAMPLE_EXIT=${PIPESTATUS[0]}
set -e

# sample may fail if the process exits — that's often OK
if [ "$SAMPLE_EXIT" -ne 0 ]; then
    if [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ]; then
        echo "Warning: sample exited with code $SAMPLE_EXIT but output was captured" >&2
    else
        echo "Error: sample failed with exit code $SAMPLE_EXIT" >&2
        exit "$SAMPLE_EXIT"
    fi
fi

if [ ! -f "$OUTPUT" ]; then
    echo "Error: Output file was not created" >&2
    exit 1
fi

# ── Print output path to stdout (for scripting) ─────────────────────────────
ACTUAL_OUTPUT=$(cd "$(dirname "$OUTPUT")" && echo "$(pwd)/$(basename "$OUTPUT")")
echo "$ACTUAL_OUTPUT"

# ── Print summary to stderr ─────────────────────────────────────────────────
echo "" >&2
echo -e "${BOLD}${CYAN}── Top Functions (by stack top) ──${NC}" >&2

# Extract "Sort by top of stack" section — the most useful quick summary
if grep -q "Sort by top of stack" "$OUTPUT" 2>/dev/null; then
    # Print from "Sort by top of stack" to end of file (or next section)
    sed -n '/Sort by top of stack/,/^$/p' "$OUTPUT" | head -30 >&2
else
    # Fallback: show the heaviest frames from call graph
    echo "(No 'Sort by top of stack' section found — showing call graph head)" >&2
    if grep -q "Call graph:" "$OUTPUT" 2>/dev/null; then
        sed -n '/Call graph:/,/^$/p' "$OUTPUT" | head -25 >&2
    else
        echo "(Could not extract summary from output)" >&2
    fi
fi

# ── File size info ───────────────────────────────────────────────────────────
FILE_SIZE=$(du -sh "$OUTPUT" 2>/dev/null | cut -f1)
SAMPLE_COUNT=$(grep -c "^[[:space:]]*[0-9]" "$OUTPUT" 2>/dev/null || echo "?")
echo "" >&2
echo "Sample output: $ACTUAL_OUTPUT ($FILE_SIZE)" >&2

exit 0
