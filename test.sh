#!/bin/bash
# test.sh — End-to-end tests for xtrace skill
# Records a real trace and verifies all tools work correctly.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/scripts" && pwd)"
PASS=0
FAIL=0
ERRORS=""

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { ((PASS++)); echo "  ✓ $1"; }
fail() { ((FAIL++)); ERRORS+="  ✗ $1\n"; echo "  ✗ $1"; }

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc (exit $?)"
    fi
}

check_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local output
    output=$("$@" 2>&1)
    if echo "$output" | grep -q "$expected"; then
        pass "$desc"
    else
        fail "$desc — expected '$expected' in output"
    fi
}

check_file() {
    local desc="$1"
    local path="$2"
    if [ -f "$path" ] && [ -s "$path" ]; then
        pass "$desc"
    else
        fail "$desc — file missing or empty: $path"
    fi
}

# ── Prerequisites ────────────────────────────────────────────────────────────
echo "━━━ Prerequisites ━━━"

check "xctrace available" command -v xctrace
check "python3 available" command -v python3
check "python3 >= 3.8" python3 -c "import sys; assert sys.version_info >= (3, 8)"
check "trace-analyze.py compiles" python3 -m py_compile "$SCRIPT_DIR/trace-analyze.py"

echo ""
echo "━━━ Script Help ━━━"

check_output "xtrace --help" "Usage:" bash "$SCRIPT_DIR/xtrace" --help
check_output "trace-record.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-record.sh" --help
check_output "trace-flamegraph.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-flamegraph.sh" --help
check_output "trace-speedscope.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-speedscope.sh" --help
check_output "trace-diff-flamegraph.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-diff-flamegraph.sh" --help
check_output "sample-quick.sh --help" "Usage:" bash "$SCRIPT_DIR/sample-quick.sh" --help
check_output "trace-analyze.py --help" "summary" python3 "$SCRIPT_DIR/trace-analyze.py" --help
check_output "trace-analyze.py summary --help" "top" python3 "$SCRIPT_DIR/trace-analyze.py" summary --help
check_output "trace-analyze.py timeline --help" "window" python3 "$SCRIPT_DIR/trace-analyze.py" timeline --help
check_output "trace-analyze.py calltree --help" "depth" python3 "$SCRIPT_DIR/trace-analyze.py" calltree --help
check_output "trace-analyze.py collapsed --help" "module" python3 "$SCRIPT_DIR/trace-analyze.py" collapsed --help
check_output "trace-analyze.py flamegraph --help" "output" python3 "$SCRIPT_DIR/trace-analyze.py" flamegraph --help
check_output "trace-analyze.py diff --help" "threshold" python3 "$SCRIPT_DIR/trace-analyze.py" diff --help

echo ""
echo "━━━ trace-check.sh ━━━"

check_output "trace-check runs" "xctrace" bash "$SCRIPT_DIR/trace-check.sh"

echo ""
echo "━━━ Recording ━━━"

TRACE_FILE="/tmp/xtrace_test_$(date +%s).trace"

# Record a 3-second trace of /usr/bin/yes
echo "  Recording 3s trace of /usr/bin/yes..."
TRACE_PATH=$(bash "$SCRIPT_DIR/trace-record.sh" -d 3 -o "$TRACE_FILE" -- /usr/bin/yes 2>/dev/null)

if [ -n "$TRACE_PATH" ] && [ -e "$TRACE_PATH" ]; then
    pass "trace-record.sh produced trace: $TRACE_PATH"
else
    fail "trace-record.sh failed to produce trace"
    echo ""
    echo "━━━ RESULTS ━━━"
    echo "  $PASS passed, $FAIL failed"
    echo "Cannot continue without a trace file."
    exit 1
fi

echo ""
echo "━━━ Analysis: summary ━━━"

SUMMARY_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --top 10 2>&1)
if echo "$SUMMARY_OUT" | grep -q "Samples"; then
    pass "summary produces output"
else
    fail "summary output missing 'Samples'"
fi

if echo "$SUMMARY_OUT" | grep -q "Module"; then
    pass "summary shows module breakdown"
else
    fail "summary missing module breakdown"
fi

# JSON output
JSON_FILE="/tmp/xtrace_test_summary.json"
python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --json > "$JSON_FILE" 2>/dev/null
if python3 -c "import json; json.load(open('$JSON_FILE'))" 2>/dev/null; then
    pass "summary --json produces valid JSON"
else
    fail "summary --json produces invalid JSON"
fi

if python3 -c "import json; d=json.load(open('$JSON_FILE')); assert 'functions' in d and 'modules' in d" 2>/dev/null; then
    pass "JSON has functions and modules keys"
else
    fail "JSON missing functions or modules"
fi

echo ""
echo "━━━ Analysis: timeline ━━━"

TIMELINE_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --window 500ms 2>&1)
if echo "$TIMELINE_OUT" | grep -q "Spark"; then
    pass "timeline produces bucketed output"
else
    fail "timeline output missing bucketed data"
fi

ADAPTIVE_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --adaptive 2>&1)
if echo "$ADAPTIVE_OUT" | grep -q "PHASE"; then
    pass "timeline --adaptive detects phases"
else
    fail "timeline --adaptive missing phase detection"
fi

echo ""
echo "━━━ Analysis: calltree ━━━"

TREE_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" calltree "$TRACE_PATH" 2>&1)
if echo "$TREE_OUT" | grep -q "├\|└"; then
    pass "calltree produces tree output"
else
    fail "calltree missing tree characters"
fi

echo ""
echo "━━━ Analysis: collapsed ━━━"

COLLAPSED_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_PATH" 2>&1)
if echo "$COLLAPSED_OUT" | grep -q ";"; then
    pass "collapsed produces semicolon-delimited stacks"
else
    fail "collapsed output missing semicolons"
fi

STACK_COUNT=$(echo "$COLLAPSED_OUT" | wc -l | tr -d ' ')
if [ "$STACK_COUNT" -gt 0 ]; then
    pass "collapsed has $STACK_COUNT unique stacks"
else
    fail "collapsed produced 0 stacks"
fi

echo ""
echo "━━━ Analysis: diff ━━━"

DIFF_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" diff "$JSON_FILE" "$JSON_FILE" 2>&1)
if echo "$DIFF_OUT" | grep -q "UNCHANGED\|DIFF"; then
    pass "diff produces comparison output"
else
    fail "diff output missing comparison data"
fi

echo ""
echo "━━━ Analysis: flamegraph (built-in) ━━━"

SVG_FILE="/tmp/xtrace_test_flame.svg"
python3 "$SCRIPT_DIR/trace-analyze.py" flamegraph "$TRACE_PATH" -o "$SVG_FILE" 2>/dev/null
check_file "built-in flamegraph produces SVG" "$SVG_FILE"

if grep -q "<svg" "$SVG_FILE" 2>/dev/null; then
    pass "SVG has valid svg tag"
else
    fail "SVG missing svg tag"
fi

echo ""
echo "━━━ Flamegraph script ━━━"

FLAME_SVG="/tmp/xtrace_test_flamegraph_script.svg"
bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$FLAME_SVG" "$TRACE_PATH" 2>/dev/null
check_file "trace-flamegraph.sh produces SVG" "$FLAME_SVG"

echo ""
echo "━━━ Piping: stdin with - ━━━"

PIPE_OUT=$(echo "$TRACE_PATH" | python3 "$SCRIPT_DIR/trace-analyze.py" summary - --top 5 2>&1)
if echo "$PIPE_OUT" | grep -q "Samples"; then
    pass "trace-analyze.py accepts - from stdin"
else
    fail "trace-analyze.py stdin pipe failed"
fi

PIPE_SVG="/tmp/xtrace_test_pipe.svg"
echo "$TRACE_PATH" | bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$PIPE_SVG" - 2>/dev/null
check_file "trace-flamegraph.sh accepts - from stdin" "$PIPE_SVG"

echo ""
echo "━━━ Time range filter ━━━"

RANGE_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --time-range "0s-2s" 2>&1)
if echo "$RANGE_OUT" | grep -q "Samples"; then
    pass "time-range filter works"
else
    fail "time-range filter failed"
fi

echo ""
echo "━━━ sample-quick.sh ━━━"

/usr/bin/yes > /dev/null 2>&1 &
YES_PID=$!
sleep 0.3

SAMPLE_PATH=$(bash "$SCRIPT_DIR/sample-quick.sh" "$YES_PID" 1 2>/dev/null)
kill "$YES_PID" 2>/dev/null || true
wait "$YES_PID" 2>/dev/null || true

if [ -n "$SAMPLE_PATH" ] && [ -f "$SAMPLE_PATH" ]; then
    pass "sample-quick.sh produces output"
    # Verify it went to /tmp
    if echo "$SAMPLE_PATH" | grep -q "^/tmp/"; then
        pass "sample-quick.sh output in /tmp"
    else
        fail "sample-quick.sh output not in /tmp: $SAMPLE_PATH"
    fi
else
    fail "sample-quick.sh failed to produce output"
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "$JSON_FILE" "$SVG_FILE" "$FLAME_SVG" "$PIPE_SVG" "$SAMPLE_PATH" 2>/dev/null
rm -rf "$TRACE_FILE" 2>/dev/null

# ── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "  Failures:"
    echo -e "$ERRORS"
    exit 1
else
    echo "  All tests passed ✓"
    exit 0
fi
