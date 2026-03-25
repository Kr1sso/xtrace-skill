#!/bin/bash
# trace-check.sh — Verify system readiness for Instruments profiling
# Checks: xctrace, architecture, sample, Python 3, optional tools, SIP status

set -euo pipefail

# ── Color codes ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

PASS=0
WARN=0
FAIL=0

ok()   { echo -e "${GREEN}✓${NC} $*"; PASS=$((PASS + 1)); }
warn() { echo -e "${YELLOW}!${NC} $*"; WARN=$((WARN + 1)); }
fail() { echo -e "${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); }
header() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

# ── xctrace ──────────────────────────────────────────────────────────────────
header "Core Tools"

if command -v xctrace &>/dev/null; then
    VERSION=$(xctrace version 2>&1 || true)
    ok "xctrace found: $VERSION"
else
    fail "xctrace not found. Install Xcode or Command Line Tools."
    echo "  Run: xcode-select --install"
fi

# ── Architecture ─────────────────────────────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ok "Apple Silicon ($ARCH) — Processor Trace hardware supported"
else
    warn "Intel ($ARCH) — Processor Trace not available (requires Apple Silicon)"
fi

# ── Processor Trace enablement ───────────────────────────────────────────────
header "Processor Trace"

# Processor Trace requires Developer Tools to be enabled in
# System Settings → Privacy & Security → Developer Tools.
# We can check if DevToolsSecurity is enabled as a proxy.
if command -v DevToolsSecurity &>/dev/null; then
    DTS=$(DevToolsSecurity 2>&1 || true)
    if echo "$DTS" | grep -qi "enabled"; then
        ok "Developer Tools security: enabled"
    else
        warn "Developer Tools security may not be enabled"
        echo "  Enable in: System Settings → Privacy & Security → Developer Tools"
        echo "  Or run: sudo DevToolsSecurity -enable"
    fi
else
    warn "Cannot check Developer Tools security status"
fi

# Check if Processor Trace template is available
if command -v xctrace &>/dev/null; then
    if xctrace list templates 2>/dev/null | grep "Processor Trace" >/dev/null; then
        ok "Processor Trace template available"
    else
        warn "Processor Trace template not found in available templates"
    fi
fi

# ── sample command ───────────────────────────────────────────────────────────
header "Sampling Tools"

if command -v sample &>/dev/null; then
    ok "sample command available (lightweight CPU profiling)"
else
    fail "sample command not found"
fi

# ── Python 3 ─────────────────────────────────────────────────────────────────
header "Python"

if command -v python3 &>/dev/null; then
    PY_VERSION=$(python3 --version 2>&1)
    # Extract version numbers for comparison
    PY_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo "0")
    PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo "0")
    if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 8 ]; then
        ok "$PY_VERSION (>= 3.8 required)"
    else
        fail "$PY_VERSION — Python 3.8+ required for trace-analyze.py"
    fi
else
    fail "Python 3 not found. Required for trace-analyze.py"
fi

# Check key stdlib modules we depend on
if command -v python3 &>/dev/null; then
    if python3 -c "import xml.etree.ElementTree, json, argparse, collections, textwrap" 2>/dev/null; then
        ok "Required Python stdlib modules available"
    else
        fail "Some required Python stdlib modules are missing"
    fi
fi

# ── Optional tools ───────────────────────────────────────────────────────────
header "Optional Tools"

if command -v inferno-flamegraph &>/dev/null; then
    ok "inferno-flamegraph found (Rust flamegraph renderer)"
else
    warn "inferno-flamegraph not found — install with: cargo install inferno"
fi

if command -v flamegraph.pl &>/dev/null; then
    ok "flamegraph.pl found (Brendan Gregg's FlameGraph)"
else
    warn "flamegraph.pl not found — install from: https://github.com/brendangregg/FlameGraph"
fi

if command -v speedscope &>/dev/null; then
    ok "speedscope found (interactive flamegraph viewer)"
else
    warn "speedscope not found — install with: npm install -g speedscope"
fi

# ── Available templates ──────────────────────────────────────────────────────
header "Instruments Templates"

if command -v xctrace &>/dev/null; then
    echo "Available templates:"
    xctrace list templates 2>/dev/null | head -30 || echo "  (could not list templates)"
    TOTAL=$(xctrace list templates 2>/dev/null | wc -l | tr -d ' ')
    if [ "$TOTAL" -gt 30 ]; then
        echo "  ... ($TOTAL total, showing first 30)"
    fi
else
    echo "  (xctrace not available — cannot list templates)"
fi

# ── SIP status ───────────────────────────────────────────────────────────────
header "System Integrity Protection"

SIP=$(csrutil status 2>&1 || true)
echo "$SIP"
if echo "$SIP" | grep -q "enabled"; then
    ok "SIP enabled (normal — most profiling works fine with SIP on)"
elif echo "$SIP" | grep -q "disabled"; then
    warn "SIP disabled (all profiling features available, but system less secure)"
else
    warn "Could not determine SIP status"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
header "Summary"

echo -e "  ${GREEN}✓ $PASS passed${NC}  ${YELLOW}! $WARN warnings${NC}  ${RED}✗ $FAIL failed${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}System is ready for profiling.${NC}"
    exit 0
elif [ "$FAIL" -le 2 ] && [ "$PASS" -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}System partially ready — some features may not work.${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}System not ready — fix the failures above.${NC}"
    exit 1
fi
