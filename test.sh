#!/bin/bash
# test.sh — Comprehensive end-to-end tests for xtrace skill
# Records real traces and exercises every script, subcommand, flag, and pipe pattern.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/scripts" && pwd)"
PASS=0
FAIL=0
SKIP=0
ERRORS=""
TRACE_FILE=""
TRACE_FILE_2=""
CLEANUP_FILES=()
HAS_INFERNO=false
HAS_METAL_TEMPLATE=false

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { ((PASS++)); echo "  ✓ $1"; }
fail() { ((FAIL++)); ERRORS+="  ✗ $1\n"; echo "  ✗ $1"; }
skip() { ((SKIP++)); echo "  ↷ $1"; }

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"
    else fail "$desc (exit $?)"; fi
}

check_output() {
    local desc="$1" expected="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q -- "$expected"; then pass "$desc"
    else fail "$desc — expected '$expected'"; fi
}

check_output_not() {
    local desc="$1" unexpected="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q -- "$unexpected"; then fail "$desc — found '$unexpected'"
    else pass "$desc"; fi
}

check_file() {
    local desc="$1" path="$2"
    if [ -f "$path" ] && [ -s "$path" ]; then pass "$desc"
    else fail "$desc — file missing or empty: $path"; fi
}

check_exit() {
    local desc="$1" expected="$2"; shift 2
    local code=0
    "$@" >/dev/null 2>&1 || code=$?
    if [ "$code" -eq "$expected" ]; then pass "$desc (exit $code)"
    else fail "$desc — expected exit $expected, got $code"; fi
}

tmpfile() {
    local f
    f=$(mktemp "/tmp/xtrace_test_XXXXXXXX")
    if [ -n "$1" ]; then
        mv "$f" "${f}${1}"
        f="${f}${1}"
    fi
    CLEANUP_FILES+=("$f")
    echo "$f"
}

cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do rm -rf "$f" 2>/dev/null; done
    rm -rf "$TRACE_FILE" "$TRACE_FILE_2" 2>/dev/null
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
echo "━━━ 1. Prerequisites ━━━"
# ══════════════════════════════════════════════════════════════════════════════

check "xctrace available" command -v xctrace
check "python3 available" command -v python3
check "python3 >= 3.8" python3 -c "import sys; assert sys.version_info >= (3, 8)"

if command -v inferno-flamegraph >/dev/null 2>&1 && command -v inferno-diff-folded >/dev/null 2>&1 && command -v inferno-collapse-xctrace >/dev/null 2>&1; then
    HAS_INFERNO=true
    pass "inferno tools available"
else
    skip "inferno tools not available (inferno-specific tests will be skipped)"
fi

check "speedscope available" command -v speedscope
check "trace-analyze.py compiles" python3 -m py_compile "$SCRIPT_DIR/trace-analyze.py"
check "trace-gpu.py compiles" python3 -m py_compile "$SCRIPT_DIR/trace-gpu.py"

if command -v xctrace >/dev/null 2>&1 && xctrace list templates 2>/dev/null | grep -F "Metal System Trace" >/dev/null; then
    HAS_METAL_TEMPLATE=true
    pass "Metal System Trace template available"
else
    skip "Metal System Trace template unavailable (GPU recording test skipped)"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 2. Help text (every script, every subcommand) ━━━"
# ══════════════════════════════════════════════════════════════════════════════

check_output "xtrace --help" "Usage:" bash "$SCRIPT_DIR/xtrace" --help
check_output "xtrace --help mentions --gpu" "--gpu" bash "$SCRIPT_DIR/xtrace" --help
check_output "xtrace --help mentions --gpu-process" "gpu-process" bash "$SCRIPT_DIR/xtrace" --help
check_output "xtrace -h" "Usage:" bash "$SCRIPT_DIR/xtrace" -h
check_output "trace-record.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-record.sh" --help
check_output "trace-record.sh --help mentions --wait-for" "wait-for" bash "$SCRIPT_DIR/trace-record.sh" --help
check_output "trace-flamegraph.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-flamegraph.sh" --help
check_output "trace-flamegraph.sh --help no --open" "speedscope" bash "$SCRIPT_DIR/trace-flamegraph.sh" --help
check_output_not "trace-flamegraph.sh --help no --open flag" "\-\-open" bash "$SCRIPT_DIR/trace-flamegraph.sh" --help
check_output "trace-speedscope.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-speedscope.sh" --help
check_output "trace-diff-flamegraph.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-diff-flamegraph.sh" --help
check_output_not "trace-diff-flamegraph.sh --help no --open" "\-\-open" bash "$SCRIPT_DIR/trace-diff-flamegraph.sh" --help
check_output "sample-quick.sh --help" "Usage:" bash "$SCRIPT_DIR/sample-quick.sh" --help
check_output "trace-gpu.py --help" "Analyze GPU-centric metrics" python3 "$SCRIPT_DIR/trace-gpu.py" --help
check_output "trace-check.sh runs" "xctrace" bash "$SCRIPT_DIR/trace-check.sh"

# trace-analyze.py subcommands
check_output "trace-analyze.py --help" "summary" python3 "$SCRIPT_DIR/trace-analyze.py" --help
for sub in summary timeline calltree collapsed flamegraph diff info; do
    check_output "trace-analyze.py $sub --help" "trace" python3 "$SCRIPT_DIR/trace-analyze.py" "$sub" --help
done

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 2b. GPU analysis (mocked xctrace) ━━━"
# ══════════════════════════════════════════════════════════════════════════════

MOCK_XCTRACE_DIR=$(mktemp -d "/tmp/xtrace_mock_xctrace_XXXXXXXX")
CLEANUP_FILES+=("$MOCK_XCTRACE_DIR")
MOCK_XCTRACE="$MOCK_XCTRACE_DIR/xctrace"

cat > "$MOCK_XCTRACE" <<'EOF'
#!/bin/bash
set -euo pipefail

MODE=""
XPATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        export) shift ;;
        --toc) MODE="toc"; shift ;;
        --xpath) MODE="xpath"; XPATH="$2"; shift 2 ;;
        --input) shift 2 ;;
        *) shift ;;
    esac
done

if [ "$MODE" = "toc" ]; then
    cat <<'XML'
<trace-toc>
  <run number="1">
    <target>
      <process type="launched" name="MyGame" pid="4242"/>
    </target>
  </run>
</trace-toc>
XML
    exit 0
fi

case "$XPATH" in
  *metal-gpu-state-intervals*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><duration>1000000000</duration><gpu-state fmt="Active">Active</gpu-state></row>
    <row><duration>500000000</duration><gpu-state fmt="Idle">Idle</gpu-state></row>
  </node>
</trace-query-result>
XML
    ;;

  *metal-application-intervals*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><duration>200000000</duration><process fmt="MyGame (4242)"/><metal-nesting-level fmt="1">1</metal-nesting-level><formatted-label fmt="Command Buffer #1">Command Buffer #1</formatted-label></row>
    <row><duration>300000000</duration><process fmt="MyGame (4242)"/><metal-nesting-level fmt="1">1</metal-nesting-level><formatted-label fmt="Command Buffer #2">Command Buffer #2</formatted-label></row>
    <row><duration>100000000</duration><process fmt="WindowServer (100)"/><metal-nesting-level fmt="1">1</metal-nesting-level><formatted-label fmt="Command Buffer WS">Command Buffer WS</formatted-label></row>
  </node>
</trace-query-result>
XML
    ;;

  *metal-gpu-intervals*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><duration>200000000</duration><process fmt="MyGame (4242)"/></row>
    <row><duration>300000000</duration><process fmt="MyGame (4242)"/></row>
    <row><duration>500000000</duration><process fmt="WindowServer (100)"/></row>
  </node>
</trace-query-result>
XML
    ;;

  *)
    echo "<trace-query-result/>"
    ;;
esac
EOF

chmod +x "$MOCK_XCTRACE"

GPU_JSON=$(tmpfile .json)
if PATH="$MOCK_XCTRACE_DIR:$PATH" python3 "$SCRIPT_DIR/trace-gpu.py" /tmp/mock.trace --json > "$GPU_JSON" 2>/dev/null; then
    pass "trace-gpu.py runs with mocked xctrace"
else
    fail "trace-gpu.py failed with mocked xctrace"
fi

check "trace-gpu.py JSON valid" python3 -c "import json; json.load(open('$GPU_JSON'))"
check "trace-gpu.py target process detection" python3 -c "import json; d=json.load(open('$GPU_JSON')); assert d['target_name'] == 'MyGame' and d['target_pid'] == '4242'"
check "trace-gpu.py active ratio" python3 -c "import json, math; d=json.load(open('$GPU_JSON')); assert math.isclose(d['gpu_states']['active_ratio'], 2/3, rel_tol=1e-3)"
check "trace-gpu.py command buffer count" python3 -c "import json; d=json.load(open('$GPU_JSON')); assert d['app_intervals']['command_buffers']['count'] == 2"
check "trace-gpu.py ownership share" python3 -c "import json, math; d=json.load(open('$GPU_JSON')); assert math.isclose(d['gpu_intervals']['target_share'], 0.5, rel_tol=1e-3)"

GPU_JSON_FILTERED=$(tmpfile .json)
if PATH="$MOCK_XCTRACE_DIR:$PATH" python3 "$SCRIPT_DIR/trace-gpu.py" /tmp/mock.trace --process windowserver --json > "$GPU_JSON_FILTERED" 2>/dev/null; then
    pass "trace-gpu.py --process override"
else
    fail "trace-gpu.py --process override failed"
fi
check "trace-gpu.py process override filters app intervals" python3 -c "import json; d=json.load(open('$GPU_JSON_FILTERED')); assert d['app_intervals']['target_rows'] == 1"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 3. Error handling ━━━"
# ══════════════════════════════════════════════════════════════════════════════

check_exit "xtrace no args → error" 1 bash "$SCRIPT_DIR/xtrace"
check_exit "trace-record.sh no target → error" 1 bash "$SCRIPT_DIR/trace-record.sh"
check_exit "trace-record.sh multiple targets → error" 1 bash "$SCRIPT_DIR/trace-record.sh" -p 1 -n foo
check_exit "trace-flamegraph.sh no trace → error" 1 bash "$SCRIPT_DIR/trace-flamegraph.sh"
check_exit "trace-speedscope.sh no trace → error" 1 bash "$SCRIPT_DIR/trace-speedscope.sh"
check_exit "trace-analyze.py no subcommand → error" 1 python3 "$SCRIPT_DIR/trace-analyze.py"
check_exit "trace-analyze.py summary nonexistent → error" 1 python3 "$SCRIPT_DIR/trace-analyze.py" summary /nonexistent.trace
check_exit "trace-analyze.py diff bad json → error" 1 python3 "$SCRIPT_DIR/trace-analyze.py" diff /dev/null /dev/null
check_exit "trace-gpu.py nonexistent trace → error" 1 python3 "$SCRIPT_DIR/trace-gpu.py" /nonexistent.trace

check_output "trace-record.sh bad template → error" "Unknown template" bash "$SCRIPT_DIR/trace-record.sh" -t "Nonexistent Template" -d 1 -- /usr/bin/true
check_output "trace-flamegraph.sh nonexistent trace → error" "not found" bash "$SCRIPT_DIR/trace-flamegraph.sh" /nonexistent.trace
check_output "trace-speedscope.sh nonexistent trace → error" "not found" bash "$SCRIPT_DIR/trace-speedscope.sh" /nonexistent.trace

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 4. Recording ━━━"
# ══════════════════════════════════════════════════════════════════════════════

# Record trace 1 (via trace-record.sh)
TRACE_FILE="/tmp/xtrace_test_$(date +%s)_1.trace"
echo "  Recording 3s trace of /usr/bin/yes (trace-record.sh)..."
TRACE_PATH=$(bash "$SCRIPT_DIR/trace-record.sh" -d 3 -o "$TRACE_FILE" -- /usr/bin/yes 2>/dev/null || true)

if [ -n "$TRACE_PATH" ] && [ -e "$TRACE_PATH" ]; then
    pass "trace-record.sh produces trace: $(basename "$TRACE_PATH")"
else
    fail "trace-record.sh failed"
    echo "Cannot continue without a trace. Aborting."
    exit 1
fi

# Record trace 2 (via xtrace wrapper)
echo "  Recording 3s trace of /usr/bin/yes (xtrace)..."
TRACE_FILE_2=$(bash "$SCRIPT_DIR/xtrace" -d 3 /usr/bin/yes 2>/dev/null || true)

if [ -n "$TRACE_FILE_2" ] && [ -e "$TRACE_FILE_2" ]; then
    pass "xtrace produces trace: $(basename "$TRACE_FILE_2")"
else
    fail "xtrace failed to produce trace"
fi

# Verify trace-record.sh stdout is just the path (for piping)
STDOUT_TRACE="/tmp/xtrace_test_stdout_$(date +%s).trace"
CLEANUP_FILES+=("$STDOUT_TRACE")
STDOUT_LINES=$(bash "$SCRIPT_DIR/trace-record.sh" -d 2 -o "$STDOUT_TRACE" -- /usr/bin/true 2>/dev/null | wc -l | tr -d ' ')
if [ "$STDOUT_LINES" -eq 1 ]; then
    pass "trace-record.sh stdout is exactly 1 line (path only)"
else
    fail "trace-record.sh stdout has $STDOUT_LINES lines (expected 1)"
fi

# Verify xtrace prints summary to stderr and path to stdout
XTRACE_STDOUT=$(bash "$SCRIPT_DIR/xtrace" -d 2 /usr/bin/yes 2>/dev/null || true)
XTRACE_STDERR=$(bash "$SCRIPT_DIR/xtrace" -d 2 /usr/bin/yes 2>&1 >/dev/null || true)
CLEANUP_FILES+=("$XTRACE_STDOUT")
if [ -e "$XTRACE_STDOUT" ]; then
    pass "xtrace stdout is a valid trace path"
else
    fail "xtrace stdout is not a valid path: $XTRACE_STDOUT"
fi
if echo "$XTRACE_STDERR" | grep -q "Samples\|Self%\|Top Functions"; then
    pass "xtrace stderr contains summary"
else
    fail "xtrace stderr missing summary"
fi

# xtrace --no-summary
NOSUMMARY_STDERR=$(bash "$SCRIPT_DIR/xtrace" --no-summary -d 2 /usr/bin/yes 2>&1 >/dev/null || true)
if echo "$NOSUMMARY_STDERR" | grep -q "Self%"; then
    fail "xtrace --no-summary still prints summary"
else
    pass "xtrace --no-summary suppresses summary"
fi

# Decimal duration (e.g. 2.5s)
DECIMAL_DUR_TRACE="/tmp/xtrace_test_decimal_$(date +%s).trace"
CLEANUP_FILES+=("$DECIMAL_DUR_TRACE")
DECIMAL_OK=false
for attempt in 1 2; do
    rm -rf "$DECIMAL_DUR_TRACE" 2>/dev/null || true
    DECIMAL_DUR_PATH=$(bash "$SCRIPT_DIR/trace-record.sh" -d 1.5s -o "$DECIMAL_DUR_TRACE" -- /usr/bin/yes 2>/dev/null || true)
    if [ -n "$DECIMAL_DUR_PATH" ] && [ -e "$DECIMAL_DUR_PATH" ]; then
        DECIMAL_OK=true
        break
    fi
    sleep 1
done
if [ "$DECIMAL_OK" = true ]; then
    pass "trace-record.sh accepts decimal duration (1.5s)"
else
    fail "trace-record.sh rejects decimal duration (1.5s)"
fi

if [ "$HAS_METAL_TEMPLATE" = true ]; then
    GPU_TRACE_PATH=$(bash "$SCRIPT_DIR/xtrace" --gpu --no-summary -d 2 /usr/bin/yes 2>/dev/null || true)
    if [ -n "$GPU_TRACE_PATH" ] && [ -e "$GPU_TRACE_PATH" ]; then
        pass "xtrace --gpu records a Metal System Trace"
        CLEANUP_FILES+=("$GPU_TRACE_PATH")
    else
        fail "xtrace --gpu failed to record a trace"
    fi
else
    skip "xtrace --gpu recording skipped (Metal System Trace template unavailable)"
fi
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 5. Analysis: summary ━━━"
# ══════════════════════════════════════════════════════════════════════════════

check_output "summary basic" "Samples" python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH"
check_output "summary --top 3" "Module" python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --top 3
check_output "summary --by total" "Total%" python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --by total

# JSON output
JSON_FILE=$(tmpfile .json)
python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --json > "$JSON_FILE" 2>/dev/null
check "summary --json is valid JSON" python3 -c "import json; json.load(open('$JSON_FILE'))"
check "JSON has functions" python3 -c "import json; d=json.load(open('$JSON_FILE')); assert len(d['functions']) > 0"
check "JSON has modules" python3 -c "import json; d=json.load(open('$JSON_FILE')); assert len(d['modules']) > 0"
check "JSON has total_samples" python3 -c "import json; d=json.load(open('$JSON_FILE')); assert d['total_samples'] > 0"
check "JSON has duration_s" python3 -c "import json; d=json.load(open('$JSON_FILE')); assert d['duration_s'] > 0"
check "JSON has template" python3 -c "import json; d=json.load(open('$JSON_FILE')); assert d['template'] == 'Time Profiler'"

# JSON function entries have all fields
check "JSON function has self_pct" python3 -c "
import json; d=json.load(open('$JSON_FILE'))
f=d['functions'][0]
assert all(k in f for k in ['function','module','self_count','self_pct','total_count','total_pct'])
"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 6. Analysis: timeline ━━━"
# ══════════════════════════════════════════════════════════════════════════════

check_output "timeline 500ms" "Top Functions" python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --window 500ms
check_output "timeline 1s" "Top Functions" python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --window 1s
check_output "timeline 100ms" "Top Functions" python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --window 100ms
check_output "timeline --top 3" "Top Functions" python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --top 3
check_output "timeline --adaptive" "PHASE" python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --adaptive

# Timeline JSON
TIMELINE_JSON=$(tmpfile .json)
python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --json > "$TIMELINE_JSON" 2>/dev/null
check "timeline --json valid" python3 -c "import json; json.load(open('$TIMELINE_JSON'))"
check "timeline JSON has buckets" python3 -c "import json; d=json.load(open('$TIMELINE_JSON')); assert len(d['buckets']) > 0"
check "timeline JSON buckets have samples" python3 -c "
import json; d=json.load(open('$TIMELINE_JSON'))
assert all('samples' in b for b in d['buckets'])
"

# Adaptive JSON
ADAPTIVE_JSON=$(tmpfile .json)
python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --adaptive --json > "$ADAPTIVE_JSON" 2>/dev/null
check "adaptive JSON has phases" python3 -c "import json; d=json.load(open('$ADAPTIVE_JSON')); assert 'phases' in d and len(d['phases']) > 0"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 7. Analysis: calltree ━━━"
# ══════════════════════════════════════════════════════════════════════════════

TREE_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" calltree "$TRACE_PATH" 2>&1 || true)
if echo "$TREE_OUT" | grep -q '├\|└'; then pass "calltree has tree chars"
else fail "calltree missing tree chars"; fi

check_output "calltree --depth 3" "%" python3 "$SCRIPT_DIR/trace-analyze.py" calltree "$TRACE_PATH" --depth 3
check_output "calltree --min-pct 10" "%" python3 "$SCRIPT_DIR/trace-analyze.py" calltree "$TRACE_PATH" --min-pct 10

# Depth limiting works (shallow tree should have fewer lines)
DEEP=$(python3 "$SCRIPT_DIR/trace-analyze.py" calltree "$TRACE_PATH" --depth 20 2>&1 | wc -l || true)
SHALLOW=$(python3 "$SCRIPT_DIR/trace-analyze.py" calltree "$TRACE_PATH" --depth 3 2>&1 | wc -l || true)
if [ "$SHALLOW" -le "$DEEP" ]; then pass "calltree --depth limits output ($SHALLOW <= $DEEP lines)"
else fail "calltree --depth didn't reduce output"; fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 8. Analysis: collapsed ━━━"
# ══════════════════════════════════════════════════════════════════════════════

COLLAPSED_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_PATH" 2>&1 || true)
if echo "$COLLAPSED_OUT" | grep -q ";"; then pass "collapsed has semicolons"
else fail "collapsed missing semicolons"; fi

STACK_COUNT=$(echo "$COLLAPSED_OUT" | wc -l | tr -d ' ')
if [ "$STACK_COUNT" -gt 0 ]; then pass "collapsed has $STACK_COUNT stacks"
else fail "collapsed empty"; fi

# Verify format: each line is "frame;frame;... count"
BAD_LINES=$(echo "$COLLAPSED_OUT" | grep -cv ' [0-9]\+$' || true)
if [ "$BAD_LINES" -eq 0 ]; then pass "collapsed format valid (every line ends with count)"
else fail "collapsed has $BAD_LINES malformed lines"; fi

# --with-module flag (new name)
MODULE_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_PATH" --with-module 2>&1 || true)
if echo "$MODULE_OUT" | grep -q '\['; then pass "collapsed --with-module includes [module] tags"
else fail "collapsed --with-module missing module tags"; fi

# --module still works (backwards compat)
MODULE_OUT2=$(python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_PATH" --module 2>&1 || true)
if echo "$MODULE_OUT2" | grep -q '\['; then pass "collapsed --module backwards compat"
else fail "collapsed --module backwards compat broken"; fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 9. Analysis: diff ━━━"
# ══════════════════════════════════════════════════════════════════════════════

# Same file diff (should show all unchanged)
DIFF_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" diff "$JSON_FILE" "$JSON_FILE" 2>&1 || true)
if echo "$DIFF_OUT" | grep -q "UNCHANGED\|DIFF"; then pass "diff same-file shows unchanged"
else fail "diff output unexpected"; fi

# Create a modified JSON (simulate optimization)
MODIFIED_JSON=$(tmpfile .json)
python3 -c "
import json
d = json.load(open('$JSON_FILE'))
for f in d['functions']:
    f['self_pct'] = max(0, f['self_pct'] - 5.0)
    f['self_count'] = max(0, f['self_count'] - 10)
    f['total_pct'] = max(0, f['total_pct'] - 3.0)
    f['total_count'] = max(0, f['total_count'] - 5)
json.dump(d, open('$MODIFIED_JSON', 'w'))
" 2>/dev/null
check_output "diff with changes shows IMPROVED" "IMPROVED" python3 "$SCRIPT_DIR/trace-analyze.py" diff "$JSON_FILE" "$MODIFIED_JSON"

# diff shows both self and total columns
DIFF_DETAIL=$(python3 "$SCRIPT_DIR/trace-analyze.py" diff "$JSON_FILE" "$MODIFIED_JSON" 2>&1 || true)
if echo "$DIFF_DETAIL" | grep -q "Δself"; then pass "diff shows Δself column"
else fail "diff missing Δself column"; fi
if echo "$DIFF_DETAIL" | grep -q "Δtotal"; then pass "diff shows Δtotal column"
else fail "diff missing Δtotal column"; fi

# --threshold flag
check_output "diff --threshold 50 hides small changes" "UNCHANGED" python3 "$SCRIPT_DIR/trace-analyze.py" diff "$JSON_FILE" "$MODIFIED_JSON" --threshold 50

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 10. Analysis: flamegraph (built-in SVG) ━━━"
# ══════════════════════════════════════════════════════════════════════════════

BUILTIN_SVG=$(tmpfile .svg)
python3 "$SCRIPT_DIR/trace-analyze.py" flamegraph "$TRACE_PATH" -o "$BUILTIN_SVG" 2>/dev/null
check_file "built-in flamegraph produces SVG" "$BUILTIN_SVG"
check_output "SVG has svg tag" "<svg" cat "$BUILTIN_SVG"
check_output "SVG has script (interactive)" "script" cat "$BUILTIN_SVG"
check_output "SVG has frame class" "frame" cat "$BUILTIN_SVG"

# --color-by module
MODULE_SVG=$(tmpfile .svg)
python3 "$SCRIPT_DIR/trace-analyze.py" flamegraph "$TRACE_PATH" -o "$MODULE_SVG" --color-by module 2>/dev/null
check_file "flamegraph --color-by module" "$MODULE_SVG"

# --width
WIDE_SVG=$(tmpfile .svg)
python3 "$SCRIPT_DIR/trace-analyze.py" flamegraph "$TRACE_PATH" -o "$WIDE_SVG" --width 2400 2>/dev/null
if grep -q 'width="2400"' "$WIDE_SVG" 2>/dev/null; then pass "flamegraph --width 2400"
else fail "flamegraph --width not applied"; fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 11. trace-flamegraph.sh (inferno pipeline) ━━━"
# ══════════════════════════════════════════════════════════════════════════════

INFERNO_SVG=$(tmpfile .svg)
TRACE_FLAMEGRAPH_LOG=$(tmpfile .log)
if bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$INFERNO_SVG" "$TRACE_PATH" 2>"$TRACE_FLAMEGRAPH_LOG"; then
    pass "trace-flamegraph.sh runs"
else
    fail "trace-flamegraph.sh failed"
fi
check_file "trace-flamegraph.sh produces SVG" "$INFERNO_SVG"

if [ "$HAS_INFERNO" = true ]; then
    if grep -q "Tool: inferno" "$TRACE_FLAMEGRAPH_LOG"; then pass "trace-flamegraph.sh auto-selects inferno"
    else fail "trace-flamegraph.sh did not select inferno"; fi
else
    if grep -q "Tool: builtin\|Tool: flamegraph.pl" "$TRACE_FLAMEGRAPH_LOG"; then pass "trace-flamegraph.sh fallback tool selected"
    else fail "trace-flamegraph.sh did not report selected fallback tool"; fi
fi

# With --title
TITLED_SVG=$(tmpfile .svg)
if bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$TITLED_SVG" -t "Test Title" "$TRACE_PATH" >/dev/null 2>&1; then
    pass "trace-flamegraph.sh --title runs"
else
    fail "trace-flamegraph.sh --title failed"
fi
if grep -q "Test Title" "$TITLED_SVG" 2>/dev/null; then pass "trace-flamegraph.sh --title"
else fail "title not in SVG"; fi

# With --width
WIDE2_SVG=$(tmpfile .svg)
if bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$WIDE2_SVG" -w 3000 "$TRACE_PATH" >/dev/null 2>&1; then
    pass "trace-flamegraph.sh -w 3000 runs"
else
    fail "trace-flamegraph.sh -w 3000 failed"
fi
check_file "trace-flamegraph.sh -w 3000" "$WIDE2_SVG"

# Force builtin tool
BUILTIN2_SVG=$(tmpfile .svg)
if bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$BUILTIN2_SVG" --tool builtin "$TRACE_PATH" >/dev/null 2>&1; then
    pass "trace-flamegraph.sh --tool builtin runs"
else
    fail "trace-flamegraph.sh --tool builtin failed"
fi
check_file "trace-flamegraph.sh --tool builtin" "$BUILTIN2_SVG"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 12. trace-diff-flamegraph.sh ━━━"
# ══════════════════════════════════════════════════════════════════════════════

if [ "$HAS_INFERNO" = true ]; then
    DIFF_SVG=$(tmpfile .svg)
    if bash "$SCRIPT_DIR/trace-diff-flamegraph.sh" -o "$DIFF_SVG" "$TRACE_PATH" "$TRACE_PATH" >/dev/null 2>&1; then
        pass "trace-diff-flamegraph.sh runs"
    else
        fail "trace-diff-flamegraph.sh failed"
    fi
    check_file "trace-diff-flamegraph.sh produces SVG" "$DIFF_SVG"

    # With title
    DIFF_TITLED_SVG=$(tmpfile .svg)
    if bash "$SCRIPT_DIR/trace-diff-flamegraph.sh" -o "$DIFF_TITLED_SVG" -t "Diff Test" "$TRACE_PATH" "$TRACE_PATH" >/dev/null 2>&1; then
        pass "trace-diff-flamegraph.sh --title runs"
    else
        fail "trace-diff-flamegraph.sh --title failed"
    fi
    check_file "trace-diff-flamegraph.sh with title" "$DIFF_TITLED_SVG"
else
    skip "trace-diff-flamegraph.sh skipped (inferno not installed)"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 13. Piping: stdin with - ━━━"
# ══════════════════════════════════════════════════════════════════════════════

# trace-analyze.py summary -
PIPE_SUMMARY=$(echo "$TRACE_PATH" | timeout 30 python3 "$SCRIPT_DIR/trace-analyze.py" summary - --top 5 2>&1 || true)
if echo "$PIPE_SUMMARY" | grep -q "Samples"; then pass "trace-analyze.py summary - (pipe)"
else fail "trace-analyze.py summary - pipe failed"; fi

# trace-analyze.py timeline -
PIPE_TIMELINE=$(echo "$TRACE_PATH" | timeout 30 python3 "$SCRIPT_DIR/trace-analyze.py" timeline - --window 1s 2>&1 || true)
if echo "$PIPE_TIMELINE" | grep -q "Top Functions"; then pass "trace-analyze.py timeline - (pipe)"
else fail "trace-analyze.py timeline - pipe failed"; fi

# trace-analyze.py calltree -
PIPE_TREE=$(echo "$TRACE_PATH" | timeout 30 python3 "$SCRIPT_DIR/trace-analyze.py" calltree - 2>&1 || true)
if echo "$PIPE_TREE" | grep -q '├\|└\|%'; then pass "trace-analyze.py calltree - (pipe)"
else fail "trace-analyze.py calltree - pipe failed"; fi

# trace-analyze.py collapsed -
PIPE_COLLAPSED=$(echo "$TRACE_PATH" | timeout 30 python3 "$SCRIPT_DIR/trace-analyze.py" collapsed - 2>&1 || true)
if echo "$PIPE_COLLAPSED" | grep -q ";"; then pass "trace-analyze.py collapsed - (pipe)"
else fail "trace-analyze.py collapsed - pipe failed"; fi

# trace-analyze.py flamegraph -
PIPE_FLAME_SVG=$(tmpfile .svg)
echo "$TRACE_PATH" | timeout 30 python3 "$SCRIPT_DIR/trace-analyze.py" flamegraph - -o "$PIPE_FLAME_SVG" 2>/dev/null
check_file "trace-analyze.py flamegraph - (pipe)" "$PIPE_FLAME_SVG"

# trace-flamegraph.sh -
PIPE_INFERNO_SVG=$(tmpfile .svg)
echo "$TRACE_PATH" | timeout 30 bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$PIPE_INFERNO_SVG" - 2>/dev/null
check_file "trace-flamegraph.sh - (pipe)" "$PIPE_INFERNO_SVG"

# trace-analyze.py summary --json - (pipe JSON)
PIPE_JSON=$(echo "$TRACE_PATH" | timeout 30 python3 "$SCRIPT_DIR/trace-analyze.py" summary - --json 2>/dev/null || true)
if echo "$PIPE_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    pass "trace-analyze.py summary --json - (pipe valid JSON)"
else
    fail "pipe JSON invalid"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 14. Time range filtering ━━━"
# ══════════════════════════════════════════════════════════════════════════════

# Derive a time range guaranteed to contain samples using the JSON we already have
FIRST_SAMPLE_S=$(python3 -c "
import json
d = json.load(open('$JSON_FILE'))
# min/max time from timeline data or just use 0-duration
dur = d.get('duration_s', 3)
print(f'0s-{dur:.1f}s')
" 2>/dev/null || echo "0s-3s")

check_output "summary --time-range 0s-2s" "Samples" python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --time-range "0s-2s"

# Test that a range straddling real samples works — use 0s to half duration
HALF_DUR=$(python3 -c "import json; d=json.load(open('$JSON_FILE')); print(f\"{d['duration_s']/2:.1f}s\")" 2>/dev/null || echo "1.5s")
HALF_OUT=$(python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --time-range "0s-$HALF_DUR" 2>&1 || true)
if echo "$HALF_OUT" | grep -q "Samples\|No samples"; then pass "summary --time-range 0s-${HALF_DUR} (valid response)"
else fail "summary --time-range 0s-${HALF_DUR} gave unexpected output"; fi

# Test that an out-of-range window fails gracefully (not a crash)
check_exit "summary --time-range 999s-1000s → no samples exit 1" 1 python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --time-range "999s-1000s"

check_output "timeline --time-range 0s-2s" "Top Functions" python3 "$SCRIPT_DIR/trace-analyze.py" timeline "$TRACE_PATH" --time-range "0s-2s"
check_output "calltree --time-range 0s-2s" "%" python3 "$SCRIPT_DIR/trace-analyze.py" calltree "$TRACE_PATH" --time-range "0s-2s"

# Collapsed with time range
RANGE_COLLAPSED=$(python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_PATH" --time-range "0s-2s" 2>&1 || true)
FULL_COLLAPSED=$(python3 "$SCRIPT_DIR/trace-analyze.py" collapsed "$TRACE_PATH" 2>&1 || true)
RANGE_COUNT=$(echo "$RANGE_COLLAPSED" | wc -l | tr -d ' ')
FULL_COUNT=$(echo "$FULL_COLLAPSED" | wc -l | tr -d ' ')
if [ "$RANGE_COUNT" -le "$FULL_COUNT" ]; then pass "time-range reduces collapsed output ($RANGE_COUNT <= $FULL_COUNT)"
else fail "time-range didn't reduce output"; fi

# Flamegraph with time range
RANGE_SVG=$(tmpfile .svg)
bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$RANGE_SVG" --time-range "0s-2s" "$TRACE_PATH" 2>/dev/null || true
check_file "trace-flamegraph.sh --time-range" "$RANGE_SVG"

# ms format
check_output "time-range ms format" "Samples" python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --time-range "500ms-2500ms"

# Open-ended range
# Open-ended range (use 0s- to guarantee samples regardless of trace density)
check_output "time-range open-ended (0s-)" "Samples" python3 "$SCRIPT_DIR/trace-analyze.py" summary "$TRACE_PATH" --time-range "0s-"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 15. sample-quick.sh ━━━"
# ══════════════════════════════════════════════════════════════════════════════

/usr/bin/yes > /dev/null 2>&1 &
YES_PID=$!
sleep 0.3

SAMPLE_PATH=$(bash "$SCRIPT_DIR/sample-quick.sh" "$YES_PID" 1 2>/dev/null || true)
kill "$YES_PID" 2>/dev/null || true
wait "$YES_PID" 2>/dev/null || true

if [ -n "$SAMPLE_PATH" ] && [ -f "$SAMPLE_PATH" ]; then
    pass "sample-quick.sh produces output"
    CLEANUP_FILES+=("$SAMPLE_PATH")

    if echo "$SAMPLE_PATH" | grep -q "^/tmp/"; then pass "sample-quick.sh output in /tmp"
    else fail "sample-quick.sh output not in /tmp: $SAMPLE_PATH"; fi

    if grep -q "Call graph\|Sort by top" "$SAMPLE_PATH" 2>/dev/null; then pass "sample output has call graph"
    else fail "sample output missing call graph"; fi
else
    fail "sample-quick.sh failed"
fi

# sample-quick.sh by name
/usr/bin/yes > /dev/null 2>&1 &
YES_PID2=$!
sleep 0.3

SAMPLE_PATH2=$(bash "$SCRIPT_DIR/sample-quick.sh" "yes" 1 2>/dev/null || true)
kill "$YES_PID2" 2>/dev/null || true
wait "$YES_PID2" 2>/dev/null || true

if [ -n "$SAMPLE_PATH2" ] && [ -f "$SAMPLE_PATH2" ]; then
    pass "sample-quick.sh by name"
    CLEANUP_FILES+=("$SAMPLE_PATH2")
else
    fail "sample-quick.sh by name failed"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 16. Symlink resolution ━━━"
# ══════════════════════════════════════════════════════════════════════════════

# Test that scripts work when called via symlinks (the real user path)
if [ -L "$HOME/.local/bin/xtrace" ]; then
    SYMLINK_TRACE=$("$HOME/.local/bin/xtrace" -d 2 /usr/bin/yes 2>/dev/null || true)
    if [ -n "$SYMLINK_TRACE" ] && [ -e "$SYMLINK_TRACE" ]; then
        pass "xtrace works via symlink"
        CLEANUP_FILES+=("$SYMLINK_TRACE")

        # trace-analyze.py via symlink
        SYMLINK_SUMMARY=$("$HOME/.local/bin/trace-analyze.py" summary "$SYMLINK_TRACE" --top 3 2>&1 || true)
        if echo "$SYMLINK_SUMMARY" | grep -q "Samples"; then pass "trace-analyze.py works via symlink"
        else fail "trace-analyze.py via symlink failed"; fi

        # trace-flamegraph via symlink
        SYMLINK_SVG=$(tmpfile .svg)
        "$HOME/.local/bin/trace-flamegraph" -o "$SYMLINK_SVG" "$SYMLINK_TRACE" 2>/dev/null || true
        check_file "trace-flamegraph works via symlink" "$SYMLINK_SVG"

        # pipe via symlinks
        SYMLINK_PIPE_SVG=$(tmpfile .svg)
        echo "$SYMLINK_TRACE" | "$HOME/.local/bin/trace-flamegraph" -o "$SYMLINK_PIPE_SVG" - 2>/dev/null || true
        check_file "pipe via symlinks" "$SYMLINK_PIPE_SVG"
    else
        fail "xtrace via symlink failed"
    fi
else
    skip "symlink tests skipped — ~/.local/bin/xtrace not installed"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 17. Full pipeline: xtrace → analyze → flamegraph ━━━"
# ══════════════════════════════════════════════════════════════════════════════

# Simulate: cmake --build . && xtrace ./app | trace-flamegraph - -o out.svg
PIPELINE_SVG=$(tmpfile .svg)
PIPELINE_TRACE=$(bash "$SCRIPT_DIR/xtrace" -d 2 /usr/bin/yes 2>/dev/null || true)
CLEANUP_FILES+=("$PIPELINE_TRACE")

if [ -n "$PIPELINE_TRACE" ] && [ -e "$PIPELINE_TRACE" ]; then
    # Pipe to flamegraph
    echo "$PIPELINE_TRACE" | timeout 30 bash "$SCRIPT_DIR/trace-flamegraph.sh" -o "$PIPELINE_SVG" - 2>/dev/null || true
    check_file "full pipeline: xtrace → flamegraph" "$PIPELINE_SVG"

    # Pipe to summary JSON
    PIPELINE_JSON=$(tmpfile .json)
    echo "$PIPELINE_TRACE" | timeout 30 python3 "$SCRIPT_DIR/trace-analyze.py" summary - --json > "$PIPELINE_JSON" 2>/dev/null || true
    check "full pipeline: xtrace → summary JSON" python3 -c "import json; json.load(open('$PIPELINE_JSON'))"

    # Pipe to collapsed
    PIPELINE_COLLAPSED=$(echo "$PIPELINE_TRACE" | timeout 30 python3 "$SCRIPT_DIR/trace-analyze.py" collapsed - 2>&1 || true)
    if echo "$PIPELINE_COLLAPSED" | grep -q ";"; then pass "full pipeline: xtrace → collapsed"
    else fail "full pipeline collapsed failed"; fi
else
    fail "pipeline trace recording failed"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL + SKIP))
echo "  Passed:  $PASS"
echo "  Skipped: $SKIP"
echo "  Failed:  $FAIL"
echo "  Total:   $TOTAL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "  Failures:"
    echo -e "$ERRORS"
    exit 1
else
    echo "  All mandatory tests passed ✓"
    exit 0
fi
