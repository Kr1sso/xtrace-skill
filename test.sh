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
check "trace-gputrace.py compiles" python3 -m py_compile "$SCRIPT_DIR/trace-gputrace.py"
check "trace-template.py compiles" python3 -m py_compile "$SCRIPT_DIR/trace-template.py"
check "trace-shader.py compiles" python3 -m py_compile "$SCRIPT_DIR/trace-shader.py"

if command -v xctrace >/dev/null 2>&1 && xctrace list templates 2>/dev/null | grep -F "Metal System Trace" >/dev/null; then
    HAS_METAL_TEMPLATE=true
    pass "Metal System Trace template available"

    METAL_TEMPLATE_PATH=$(find /Applications/Xcode.app/Contents/Applications/Instruments.app -type f -name 'Metal System Trace.tracetemplate' 2>/dev/null | head -1 || true)
    if [ -n "$METAL_TEMPLATE_PATH" ] && [ -f "$METAL_TEMPLATE_PATH" ]; then
        PATCHED_TEMPLATE=$(tmpfile .tracetemplate)
        if python3 "$SCRIPT_DIR/trace-template.py" enable-shader-timeline "$METAL_TEMPLATE_PATH" -o "$PATCHED_TEMPLATE" >/dev/null 2>&1; then
            pass "trace-template.py patches Metal System Trace"
            check "patched template has shaderprofiler enabled" python3 -c "import plistlib; objs=plistlib.load(open('$PATCHED_TEMPLATE','rb'))['\$objects']; found=False
for o in objs:
    if isinstance(o, dict) and 'NS.keys' in o and 'NS.objects' in o:
        try:
            keys=[objs[u.data] for u in o['NS.keys']]
        except Exception:
            continue
        for idx, key in enumerate(keys):
            if key == 'shaderprofiler':
                ref=o['NS.objects'][idx]
                val=objs[ref.data] if hasattr(ref, 'data') else ref
                found = found or (val is True)
assert found"
        else
            fail "trace-template.py failed to patch Metal System Trace"
        fi
    else
        skip "Metal System Trace template path not found (template patch test skipped)"
    fi
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
check_output "xtrace --help mentions --instrument" "instrument" bash "$SCRIPT_DIR/xtrace" --help
check_output "xtrace --help mentions --shader-timeline" "shader-timeline" bash "$SCRIPT_DIR/xtrace" --help
check_output "xtrace -h" "Usage:" bash "$SCRIPT_DIR/xtrace" -h
check_output "trace-record.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-record.sh" --help
check_output "trace-record.sh --help mentions --wait-for" "wait-for" bash "$SCRIPT_DIR/trace-record.sh" --help
check_output "trace-record.sh --help mentions --instrument" "instrument" bash "$SCRIPT_DIR/trace-record.sh" --help
check_output "trace-record.sh --help mentions --shader-timeline" "shader-timeline" bash "$SCRIPT_DIR/trace-record.sh" --help
check_output "trace-flamegraph.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-flamegraph.sh" --help
check_output "trace-flamegraph.sh --help no --open" "speedscope" bash "$SCRIPT_DIR/trace-flamegraph.sh" --help
check_output_not "trace-flamegraph.sh --help no --open flag" "\-\-open" bash "$SCRIPT_DIR/trace-flamegraph.sh" --help
check_output "trace-speedscope.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-speedscope.sh" --help
check_output "trace-diff-flamegraph.sh --help" "Usage:" bash "$SCRIPT_DIR/trace-diff-flamegraph.sh" --help
check_output_not "trace-diff-flamegraph.sh --help no --open" "\-\-open" bash "$SCRIPT_DIR/trace-diff-flamegraph.sh" --help
check_output "sample-quick.sh --help" "Usage:" bash "$SCRIPT_DIR/sample-quick.sh" --help
check_output "trace-gpu.py --help" "Analyze GPU-centric metrics" python3 "$SCRIPT_DIR/trace-gpu.py" --help
check_output "trace-gputrace.py --help" ".gputrace" python3 "$SCRIPT_DIR/trace-gputrace.py" --help
check_output "trace-template.py --help" "enable-shader-timeline" python3 "$SCRIPT_DIR/trace-template.py" --help
check_output "trace-shader.py --help" "hotspots" python3 "$SCRIPT_DIR/trace-shader.py" --help
check_output "trace-shader-flamegraph.sh --help" "shader flamegraph" bash "$SCRIPT_DIR/trace-shader-flamegraph.sh" --help
check_output "trace-shader-speedscope.sh --help" "shader collapsed stacks" bash "$SCRIPT_DIR/trace-shader-speedscope.sh" --help
check_output "trace-check.sh runs" "xctrace" bash "$SCRIPT_DIR/trace-check.sh"

# trace-analyze.py subcommands
check_output "trace-analyze.py --help" "summary" python3 "$SCRIPT_DIR/trace-analyze.py" --help
for sub in summary timeline calltree collapsed flamegraph diff info; do
    check_output "trace-analyze.py $sub --help" "trace" python3 "$SCRIPT_DIR/trace-analyze.py" "$sub" --help
done

# trace-shader.py subcommands
for sub in info hotspots callsites collapsed flamegraph; do
    check_output "trace-shader.py $sub --help" "trace" python3 "$SCRIPT_DIR/trace-shader.py" "$sub" --help
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
    <info>
      <summary>
        <intruments-recording-settings>
          <instrument name="Metal Application">
            <array>
              <dictionary>
                <key name="GPU">
                  <value>Counter Set: Demo</value>
                  <value>Shader Timeline: Enabled</value>
                  <value>Induced GPU Performance State: Default</value>
                </key>
              </dictionary>
            </array>
          </instrument>
        </intruments-recording-settings>
      </summary>
    </info>
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

  *metal-application-command-buffer-submissions*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><start-time>1000</start-time><duration>120000000</duration><duration>90000000</duration><uint32>1</uint32><uint32>1</uint32><process fmt="MyGame (4242)"/><thread fmt="Main Thread"/><narrative fmt="Committed &quot; Frame 1 &quot; with 1 encoders"/><metal-command-buffer-id>111</metal-command-buffer-id></row>
    <row><start-time>2000</start-time><duration>180000000</duration><duration>150000000</duration><uint32>1</uint32><uint32>2</uint32><process fmt="MyGame (4242)"/><thread fmt="Main Thread"/><narrative fmt="Committed &quot; Frame 2 &quot; with 1 encoders"/><metal-command-buffer-id>222</metal-command-buffer-id></row>
    <row><start-time>3000</start-time><duration>50000000</duration><duration>40000000</duration><uint32>1</uint32><uint32>3</uint32><process fmt="WindowServer (100)"/><thread fmt="Compositor"/><narrative fmt="Committed &quot; WS &quot; with 1 encoders"/><metal-command-buffer-id>333</metal-command-buffer-id></row>
  </node>
</trace-query-result>
XML
    ;;

  *metal-application-encoders-list*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><start-time>1100</start-time><duration>90000000</duration><thread fmt="Main Thread"/><process fmt="MyGame (4242)"/><gpu-frame-number fmt="Frame 1">1</gpu-frame-number><metal-object-label fmt="Frame 1">Frame 1</metal-object-label><metal-object-label fmt="[0] Frame 1">[0] Frame 1</metal-object-label><metal-object-label fmt="computeKernel">computeKernel</metal-object-label><metal-object-label fmt="[0] computeKernel">[0] computeKernel</metal-object-label><metal-event-name fmt="Encoding">Encoding</metal-event-name><metal-command-buffer-id>111</metal-command-buffer-id><metal-command-buffer-id>911</metal-command-buffer-id></row>
    <row><start-time>2100</start-time><duration>150000000</duration><thread fmt="Main Thread"/><process fmt="MyGame (4242)"/><gpu-frame-number fmt="Frame 2">2</gpu-frame-number><metal-object-label fmt="Frame 2">Frame 2</metal-object-label><metal-object-label fmt="[0] Frame 2">[0] Frame 2</metal-object-label><metal-object-label fmt="computeKernel">computeKernel</metal-object-label><metal-object-label fmt="[0] computeKernel">[0] computeKernel</metal-object-label><metal-event-name fmt="Encoding">Encoding</metal-event-name><metal-command-buffer-id>222</metal-command-buffer-id><metal-command-buffer-id>922</metal-command-buffer-id></row>
    <row><start-time>3100</start-time><duration>40000000</duration><thread fmt="Compositor"/><process fmt="WindowServer (100)"/><gpu-frame-number fmt="Frame 3">3</gpu-frame-number><metal-object-label fmt="WS">WS</metal-object-label><metal-object-label fmt="[0] WS">[0] WS</metal-object-label><metal-object-label fmt="blit">blit</metal-object-label><metal-object-label fmt="[0] blit">[0] blit</metal-object-label><metal-event-name fmt="Encoding">Encoding</metal-event-name><metal-command-buffer-id>333</metal-command-buffer-id><metal-command-buffer-id>933</metal-command-buffer-id></row>
  </node>
</trace-query-result>
XML
    ;;

  *metal-command-buffer-completed*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><start-time>401000000</start-time><metal-command-buffer-id>111</metal-command-buffer-id></row>
    <row><start-time>602000000</start-time><metal-command-buffer-id>222</metal-command-buffer-id></row>
    <row><start-time>700000000</start-time><metal-command-buffer-id>333</metal-command-buffer-id></row>
  </node>
</trace-query-result>
XML
    ;;

  *metal-shader-profiler-shader-list*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><start-time>1234</start-time><metal-object-label fmt="computeKernel (2)">computeKernel (2)</metal-object-label><metal-object-label fmt="mainLoop">mainLoop</metal-object-label><metal-object-label fmt="ComputePipeline">ComputePipeline</metal-object-label><uint64>2</uint64><uint64>4096</uint64><uint64>4608</uint64><string fmt="Compute">Compute</string><process fmt="MyGame (4242)"/></row>
  </node>
</trace-query-result>
XML
    ;;

  *metal-shader-profiler-intervals*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><start-time>100000000</start-time><duration>300000</duration><metal-object-label fmt="computeKernel (2)">computeKernel (2)</metal-object-label><metal-object-label fmt="mainLoop">mainLoop</metal-object-label><metal-object-label fmt="ComputePipeline">ComputePipeline</metal-object-label><metal-object-label fmt="Compute">Compute</metal-object-label><gpu-event-name fmt="ShaderTimeline">ShaderTimeline</gpu-event-name><percent fmt="75.0%">75.0</percent><percent fmt="50.0%">50.0</percent><process fmt="MyGame (4242)"/><metal-device-name fmt="M4 Max">M4 Max</metal-device-name><gpu-channel-name fmt="Compute">Compute</gpu-channel-name><metal-nesting-level fmt="0">0</metal-nesting-level></row>
    <row><start-time>120000000</start-time><duration>120000</duration><metal-object-label fmt="computeKernel (2)">computeKernel (2)</metal-object-label><metal-object-label fmt="helper">helper</metal-object-label><metal-object-label fmt="ComputePipeline">ComputePipeline</metal-object-label><metal-object-label fmt="Compute">Compute</metal-object-label><gpu-event-name fmt="ShaderTimeline">ShaderTimeline</gpu-event-name><percent fmt="25.0%">25.0</percent><percent fmt="15.0%">15.0</percent><process fmt="MyGame (4242)"/><metal-device-name fmt="M4 Max">M4 Max</metal-device-name><gpu-channel-name fmt="Compute">Compute</gpu-channel-name><metal-nesting-level fmt="1">1</metal-nesting-level></row>
    <row><start-time>130000000</start-time><duration>90000</duration><metal-object-label fmt="WindowServerShader (9)">WindowServerShader (9)</metal-object-label><metal-object-label fmt="wsMain">wsMain</metal-object-label><metal-object-label fmt="WS">WS</metal-object-label><metal-object-label fmt="Fragment">Fragment</metal-object-label><gpu-event-name fmt="ShaderTimeline">ShaderTimeline</gpu-event-name><percent fmt="10.0%">10.0</percent><percent fmt="5.0%">5.0</percent><process fmt="WindowServer (100)"/><metal-device-name fmt="M4 Max">M4 Max</metal-device-name><gpu-channel-name fmt="Fragment">Fragment</gpu-channel-name><metal-nesting-level fmt="0">0</metal-nesting-level></row>
  </node>
</trace-query-result>
XML
    ;;

  *gpu-shader-profiler-interval*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><start-time>100000000</start-time><duration>160000</duration><uint64>4128</uint64><uint32>1</uint32><uint32>0</uint32></row>
    <row><start-time>120000000</start-time><duration>80000</duration><uint64>4184</uint64><uint32>1</uint32><uint32>0</uint32></row>
  </node>
</trace-query-result>
XML
    ;;

  *gpu-shader-profiler-sample*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><event-time>100000000</event-time><uint64-array><uint64>4096</uint64><uint64>4128</uint64><uint64>4184</uint64></uint64-array><uint32>3</uint32></row>
    <row><event-time>110000000</event-time><uint64-array><uint64>4096</uint64><uint64>4128</uint64></uint64-array><uint32>2</uint32></row>
  </node>
</trace-query-result>
XML
    ;;

  *os-signpost*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><event-time>1000</event-time><process fmt="MyGame (4242)"/><event-type fmt="Event">Event</event-type><signpost-name fmt="FunctionCompiled">FunctionCompiled</signpost-name><os-log-metadata fmt="Name= computeKernel Label= mainLoop Type= compute ID= 0 UniqueID= 2 RequestHash= demo Addr= 4,096 Size= 512">Name= computeKernel Label= mainLoop Type= compute ID= 0 UniqueID= 2 RequestHash= demo Addr= 4,096 Size= 512</os-log-metadata></row>
    <row><event-time>1200</event-time><process fmt="MyGame (4242)"/><event-type fmt="Event">Event</event-type><signpost-name fmt="ComputePipelineLabel">ComputePipelineLabel</signpost-name><os-log-metadata fmt="Label= ComputePipeline ID= 2">Label= ComputePipeline ID= 2</os-log-metadata></row>
  </node>
</trace-query-result>
XML
    ;;

  *gpu-performance-state-intervals*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><duration>700000000</duration><gpu-performance-state fmt="Minimum">Minimum</gpu-performance-state></row>
    <row><duration>300000000</duration><gpu-performance-state fmt="Medium">Medium</gpu-performance-state></row>
  </node>
</trace-query-result>
XML
    ;;

  *metal-gpu-intervals*)
    cat <<'XML'
<trace-query-result>
  <node>
    <row><start-time>100000000</start-time><duration>200000000</duration><duration>10000000</duration><gpu-channel-name fmt="Compute">Compute</gpu-channel-name><formatted-label fmt="Frame 1:computeKernel">Frame 1:computeKernel</formatted-label><process fmt="MyGame (4242)"/><metal-command-buffer-id>111</metal-command-buffer-id><metal-command-buffer-id>911</metal-command-buffer-id></row>
    <row><start-time>200000000</start-time><duration>300000000</duration><duration>20000000</duration><gpu-channel-name fmt="Compute">Compute</gpu-channel-name><formatted-label fmt="Frame 2:computeKernel">Frame 2:computeKernel</formatted-label><process fmt="MyGame (4242)"/><metal-command-buffer-id>222</metal-command-buffer-id><metal-command-buffer-id>922</metal-command-buffer-id></row>
    <row><start-time>300000000</start-time><duration>500000000</duration><duration>5000000</duration><gpu-channel-name fmt="Blit">Blit</gpu-channel-name><formatted-label fmt="WS:blit">WS:blit</formatted-label><process fmt="WindowServer (100)"/><metal-command-buffer-id>333</metal-command-buffer-id><metal-command-buffer-id>933</metal-command-buffer-id></row>
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
: > /tmp/mock.trace

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
check "trace-gpu.py submission count" python3 -c "import json; d=json.load(open('$GPU_JSON')); assert d['command_buffer_submissions']['count'] == 2"
check "trace-gpu.py encoder count" python3 -c "import json; d=json.load(open('$GPU_JSON')); assert d['encoders']['count'] == 2"
check "trace-gpu.py shader inventory" python3 -c "import json; d=json.load(open('$GPU_JSON')); assert d['shader_inventory']['unique_shaders'] == 1 and d['shader_inventory']['top_shaders'][0][0] == 'computeKernel'"
check "trace-gpu.py lifecycle completion count" python3 -c "import json; d=json.load(open('$GPU_JSON')); assert d['command_buffer_lifecycle']['completed_count'] == 2 and d['command_buffer_lifecycle']['submitted_count'] == 2"
check "trace-gpu.py ownership share" python3 -c "import json, math; d=json.load(open('$GPU_JSON')); assert math.isclose(d['gpu_intervals']['target_share'], 0.5, rel_tol=1e-3)"
check "trace-gpu.py performance states" python3 -c "import json; d=json.load(open('$GPU_JSON')); assert d['performance_states']['available'] and d['performance_states']['by_state_ns']['Minimum'] == 700000000"

GPU_JSON_FILTERED=$(tmpfile .json)
if PATH="$MOCK_XCTRACE_DIR:$PATH" python3 "$SCRIPT_DIR/trace-gpu.py" /tmp/mock.trace --process windowserver --json > "$GPU_JSON_FILTERED" 2>/dev/null; then
    pass "trace-gpu.py --process override"
else
    fail "trace-gpu.py --process override failed"
fi
check "trace-gpu.py process override filters app intervals" python3 -c "import json; d=json.load(open('$GPU_JSON_FILTERED')); assert d['app_intervals']['target_rows'] == 1"

SHADER_JSON=$(tmpfile .json)
if PATH="$MOCK_XCTRACE_DIR:$PATH" python3 "$SCRIPT_DIR/trace-shader.py" info /tmp/mock.trace --json > "$SHADER_JSON" 2>/dev/null; then
    pass "trace-shader.py info runs with mocked xctrace"
else
    fail "trace-shader.py info failed with mocked xctrace"
fi
check "trace-shader.py JSON valid" python3 -c "import json; json.load(open('$SHADER_JSON'))"
check "trace-shader.py detects shader timeline enabled" python3 -c "import json; d=json.load(open('$SHADER_JSON')); assert d['shader_timeline_setting'] is True"
check "trace-shader.py compiled shader count" python3 -c "import json; d=json.load(open('$SHADER_JSON')); assert d['compiled_shaders'] >= 1 and 'computeKernel' in ''.join(d['shader_names'])"

SHADER_HOT_JSON=$(tmpfile .json)
if PATH="$MOCK_XCTRACE_DIR:$PATH" python3 "$SCRIPT_DIR/trace-shader.py" hotspots /tmp/mock.trace --json > "$SHADER_HOT_JSON" 2>/dev/null; then
    pass "trace-shader.py hotspots --json"
else
    fail "trace-shader.py hotspots --json failed"
fi
check "trace-shader.py hotspots mode intervals" python3 -c "import json; d=json.load(open('$SHADER_HOT_JSON')); assert d['mode'] == 'intervals'"
check "trace-shader.py hotspots top function label" python3 -c "import json; d=json.load(open('$SHADER_HOT_JSON')); assert d['rows'][0]['function_label'] == 'mainLoop' and d['rows'][0]['duration_ns'] == 300000"

SHADER_CALLS=$(PATH="$MOCK_XCTRACE_DIR:$PATH" python3 "$SCRIPT_DIR/trace-shader.py" callsites /tmp/mock.trace --depth 5 2>&1 || true)
if echo "$SHADER_CALLS" | grep -q '├\|└'; then pass "trace-shader.py callsites has tree chars"
else fail "trace-shader.py callsites missing tree chars"; fi

SHADER_COLLAPSED=$(PATH="$MOCK_XCTRACE_DIR:$PATH" python3 "$SCRIPT_DIR/trace-shader.py" collapsed /tmp/mock.trace 2>&1 || true)
if echo "$SHADER_COLLAPSED" | grep -q ';'; then pass "trace-shader.py collapsed has semicolons"
else fail "trace-shader.py collapsed missing semicolons"; fi

SHADER_SVG=$(tmpfile .svg)
if PATH="$MOCK_XCTRACE_DIR:$PATH" python3 "$SCRIPT_DIR/trace-shader.py" flamegraph /tmp/mock.trace -o "$SHADER_SVG" >/dev/null 2>&1; then
    pass "trace-shader.py flamegraph runs"
else
    fail "trace-shader.py flamegraph failed"
fi
check_file "trace-shader.py flamegraph produces SVG" "$SHADER_SVG"
check_output "trace-shader.py flamegraph SVG tag" "<svg" grep -n "<svg" "$SHADER_SVG"

SHADER_SVG_WRAPPER=$(tmpfile .svg)
if PATH="$MOCK_XCTRACE_DIR:$PATH" bash "$SCRIPT_DIR/trace-shader-flamegraph.sh" --tool builtin -o "$SHADER_SVG_WRAPPER" /tmp/mock.trace >/dev/null 2>&1; then
    pass "trace-shader-flamegraph.sh runs"
else
    fail "trace-shader-flamegraph.sh failed"
fi
check_file "trace-shader-flamegraph.sh produces SVG" "$SHADER_SVG_WRAPPER"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ 2c. GPU trace bundle parsing (mocked .gputrace) ━━━"
# ══════════════════════════════════════════════════════════════════════════════

MOCK_GPUTRACE=$(mktemp -d "/tmp/xtrace_mock_gputrace_XXXXXX.gputrace")
CLEANUP_FILES+=("$MOCK_GPUTRACE")

python3 - <<'PY' "$MOCK_GPUTRACE"
import plistlib, struct, sys
from pathlib import Path
bundle = Path(sys.argv[1])
(bundle / 'metadata').write_bytes(plistlib.dumps({
    '(uuid)': 'MOCK-UUID',
    'DYCaptureEngine.captured_frames_count': 1,
    'DYCaptureSession.graphics_api': 1,
}, fmt=plistlib.FMT_BINARY))
(bundle / 'capture').write_bytes(b'MTSP\x00\x04\x00\x00Compute Values Buffer\x00MTLBuffer-7-0\x00Window Drawable Texture\x00CAMetalLayer-9-index-14\x00')
(bundle / 'device-resources-demo').write_bytes(
    b'MTSP\x00\x04\x00\x00buffers\x00buffer\x00MTLBuffer-7-0\x00Compute Values Buffer\x00'
    b'textures\x00texture\x00MTLTexture-9-0-mipmap0-slice0\x00Offscreen Target Texture\x00'
    b'functions\x00function\x00stressKernel\x00function\x00windowFragment\x00'
)
(bundle / 'index').write_bytes(b'xdic\x00\x00\x00\x00')
(bundle / 'store0').write_bytes(b'\x78\x9c\x03\x00\x00\x00\x00\x01')
(bundle / 'MTLBuffer-7-0').write_bytes(struct.pack('<8f', *[i * 0.5 for i in range(8)]))
(bundle / 'MTLTexture-9-0-mipmap0-slice0').write_bytes(b'TEX' * 32)
(bundle / 'CAMetalLayer-9-index-14').write_bytes(b'erutpac\x00Window Drawable Texture\x00')
PY

MOCK_GPUTRACE_JSON=$(tmpfile .json)
if python3 "$SCRIPT_DIR/trace-gputrace.py" info "$MOCK_GPUTRACE" --json > "$MOCK_GPUTRACE_JSON" 2>/dev/null; then
    pass "trace-gputrace.py info --json on mock bundle"
else
    fail "trace-gputrace.py info --json failed on mock bundle"
fi
check "trace-gputrace.py mock JSON valid" python3 -c "import json; json.load(open('$MOCK_GPUTRACE_JSON'))"
check "trace-gputrace.py mock metadata parsed" python3 -c "import json; d=json.load(open('$MOCK_GPUTRACE_JSON')); assert d['metadata_summary']['uuid'] == 'MOCK-UUID' and d['metadata_summary']['graphics_api'] == 'Metal'"
check "trace-gputrace.py mock resource counts" python3 -c "import json; d=json.load(open('$MOCK_GPUTRACE_JSON')); assert d['resources']['buffer_count'] == 1 and d['resources']['texture_count'] == 1 and d['resources']['surface_count'] == 1"
check "trace-gputrace.py mock shader names" python3 -c "import json; d=json.load(open('$MOCK_GPUTRACE_JSON')); assert 'stressKernel' in d['resources']['shader_inventory']['functions'] and 'windowFragment' in d['resources']['shader_inventory']['functions']"

check_output "trace-gputrace.py resources text output" "Compute Values Buffer" python3 "$SCRIPT_DIR/trace-gputrace.py" resources "$MOCK_GPUTRACE"
check_output "trace-gputrace.py resources surfaces" "Window Drawable Texture" python3 "$SCRIPT_DIR/trace-gputrace.py" resources "$MOCK_GPUTRACE"
check_output "trace-gputrace.py files output" "metadata" python3 "$SCRIPT_DIR/trace-gputrace.py" files "$MOCK_GPUTRACE"
check_output "trace-gputrace.py strings output" "stressKernel" python3 "$SCRIPT_DIR/trace-gputrace.py" strings "$MOCK_GPUTRACE" --limit 20
check_output "trace-gputrace.py buffer decode" "[     0] 0" python3 "$SCRIPT_DIR/trace-gputrace.py" buffer "$MOCK_GPUTRACE" --buffer "Compute Values Buffer" --layout float --index 0-2
check_output "trace-gputrace.py buffer stats" "field0:" python3 "$SCRIPT_DIR/trace-gputrace.py" buffer "$MOCK_GPUTRACE" --buffer "MTLBuffer-7-0" --layout float --index 0-2

MOCK_GPUTRACE_REPORT=$(tmpfile .html)
if python3 "$SCRIPT_DIR/trace-gputrace.py" report "$MOCK_GPUTRACE" -o "$MOCK_GPUTRACE_REPORT" >/dev/null 2>&1; then
    pass "trace-gputrace.py report runs"
else
    fail "trace-gputrace.py report failed"
fi
check_file "trace-gputrace.py report produces HTML" "$MOCK_GPUTRACE_REPORT"
check_output "trace-gputrace.py report has title" "GPU Trace Report" grep -n "GPU Trace Report" "$MOCK_GPUTRACE_REPORT"

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
check_exit "trace-gputrace.py nonexistent bundle → error" 1 python3 "$SCRIPT_DIR/trace-gputrace.py" info /nonexistent.gputrace
check_exit "trace-shader.py nonexistent trace → error" 1 python3 "$SCRIPT_DIR/trace-shader.py" info /nonexistent.trace
check_exit "trace-shader-speedscope.sh no trace → error" 1 bash "$SCRIPT_DIR/trace-shader-speedscope.sh"

check_output "trace-record.sh bad template → error" "Unknown template" bash "$SCRIPT_DIR/trace-record.sh" -t "Nonexistent Template" -d 1 -- /usr/bin/true
check_output "trace-flamegraph.sh nonexistent trace → error" "not found" bash "$SCRIPT_DIR/trace-flamegraph.sh" /nonexistent.trace
check_output "trace-speedscope.sh nonexistent trace → error" "not found" bash "$SCRIPT_DIR/trace-speedscope.sh" /nonexistent.trace
check_output "trace-shader-speedscope.sh nonexistent trace → error" "not found" bash "$SCRIPT_DIR/trace-shader-speedscope.sh" /nonexistent.trace

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
