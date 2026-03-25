#!/bin/bash
# install.sh — Install xtrace scripts to PATH and register with AI coding agents
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}xtrace installer${NC}"
echo ""

# ── Determine install location ───────────────────────────────────────────────
INSTALL_DIR=""

for dir in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
    if echo "$PATH" | tr ':' '\n' | grep -qx "$dir"; then
        INSTALL_DIR="$dir"
        break
    fi
done

if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/.local/bin"
    echo -e "${YELLOW}!${NC} $INSTALL_DIR is not in your PATH."
    echo "  Add to your shell profile (~/.zshrc or ~/.bashrc):"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

mkdir -p "$INSTALL_DIR"
echo -e "Installing to: ${BOLD}$INSTALL_DIR${NC}"
echo ""

# ── Symlink all scripts to PATH ─────────────────────────────────────────────
SCRIPTS=(xtrace trace-record.sh trace-analyze.py trace-flamegraph.sh
         trace-speedscope.sh trace-diff-flamegraph.sh trace-check.sh sample-quick.sh)

for script in "${SCRIPTS[@]}"; do
    SRC="$SCRIPT_DIR/scripts/$script"
    case "$script" in
        xtrace|trace-analyze.py) DEST_NAME="$script" ;;
        *.sh) DEST_NAME="${script%.sh}" ;;
        *) DEST_NAME="$script" ;;
    esac
    DEST="$INSTALL_DIR/$DEST_NAME"
    if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
        echo -e "  ${YELLOW}!${NC} $DEST exists and is not a symlink — skipping"
        continue
    fi
    ln -sf "$SRC" "$DEST"
    echo -e "  ${GREEN}✓${NC} $DEST_NAME"
done

# ── Register with AI coding agents ──────────────────────────────────────────
echo ""
echo -e "${BOLD}AI Agent Integration:${NC}"

# ── Pi (mariozechner/pi-coding-agent) ────────────────────────────────────────
# Pi skills live in ~/.pi/agent/skills/<name>/
PI_SKILL_DIR="$HOME/.pi/agent/skills/instruments"
if [ -d "$HOME/.pi/agent/skills" ]; then
    if [ -L "$PI_SKILL_DIR" ]; then
        echo -e "  ${GREEN}✓${NC} Pi: already symlinked"
    elif [ -d "$PI_SKILL_DIR" ]; then
        echo -e "  ${YELLOW}!${NC} Pi: $PI_SKILL_DIR exists as directory"
        echo "      rm -rf $PI_SKILL_DIR && ln -s $SCRIPT_DIR $PI_SKILL_DIR"
    else
        ln -s "$SCRIPT_DIR" "$PI_SKILL_DIR"
        echo -e "  ${GREEN}✓${NC} Pi: installed as skill → $PI_SKILL_DIR"
    fi
else
    echo -e "  ${CYAN}·${NC} Pi: not detected (~/.pi/agent/skills/ not found)"
fi

# ── Claude Code (Anthropic) ─────────────────────────────────────────────────
# Claude Code reads .claude/commands/ for custom slash commands
# and CLAUDE.md / .claude/settings.json for project instructions
CLAUDE_COMMANDS="$HOME/.claude/commands"
if [ -d "$HOME/.claude" ] || command -v claude &>/dev/null; then
    mkdir -p "$CLAUDE_COMMANDS"
    cat > "$CLAUDE_COMMANDS/profile.md" <<'CLAUDE_CMD'
Profile a process or command using xtrace (macOS Instruments wrapper).

Usage: /profile <command or PID>

Steps:
1. If the argument is a number, attach to that PID: `trace-record.sh -d 10 -p <PID>`
2. Otherwise, launch and profile: `xtrace -d 10 <command>`
3. Run `trace-analyze.py summary <trace> --top 20` to show hotspots
4. Run `trace-analyze.py calltree <trace> --min-pct 3` for call hierarchy
5. Ask what to optimize based on the results
CLAUDE_CMD
    echo -e "  ${GREEN}✓${NC} Claude Code: /profile command → $CLAUDE_COMMANDS/profile.md"
else
    echo -e "  ${CYAN}·${NC} Claude Code: not detected"
fi

# ── Cursor ───────────────────────────────────────────────────────────────────
# Cursor reads .cursor/rules/ for custom rules and .cursorrules for project context
CURSOR_RULES="$HOME/.cursor/rules"
if [ -d "$HOME/.cursor" ]; then
    mkdir -p "$CURSOR_RULES"
    cat > "$CURSOR_RULES/xtrace-profiling.mdc" <<'CURSOR_RULE'
---
description: CPU profiling on macOS using xtrace (Instruments/xctrace wrapper)
globs: ["*.c", "*.cpp", "*.swift", "*.rs", "*.m", "*.mm"]
alwaysApply: false
---

When the user asks about performance, profiling, or optimization on macOS:

1. Use `xtrace` to profile: `xtrace -d 10 ./binary` (records trace, prints summary)
2. Analyze with `trace-analyze.py summary <trace> --top 20 --json`
3. For time-resolved view: `trace-analyze.py timeline <trace> --window 100ms`
4. For call hierarchy: `trace-analyze.py calltree <trace> --min-pct 3`
5. For flamegraph: `trace-flamegraph.sh <trace> --open`
6. For interactive analysis: `trace-speedscope.sh <trace>`
7. For before/after: `trace-analyze.py diff before.json after.json`

All tools accept `-` from stdin. Pipe: `xtrace ./app | trace-flamegraph - --open`
CURSOR_RULE
    echo -e "  ${GREEN}✓${NC} Cursor: rule → $CURSOR_RULES/xtrace-profiling.mdc"
else
    echo -e "  ${CYAN}·${NC} Cursor: not detected (~/.cursor/ not found)"
fi

# ── Windsurf (Codeium) ──────────────────────────────────────────────────────
# Windsurf reads .windsurf/rules/ for custom rules
WINDSURF_RULES="$HOME/.windsurf/rules"
if [ -d "$HOME/.windsurf" ]; then
    mkdir -p "$WINDSURF_RULES"
    cat > "$WINDSURF_RULES/xtrace-profiling.md" <<'WINDSURF_RULE'
# CPU Profiling with xtrace

When asked about performance or profiling on macOS, use the xtrace toolchain:

- Profile: `xtrace -d 10 ./binary` (prefix any command, like `time`)
- Summary: `trace-analyze.py summary <trace> --top 20`
- Timeline: `trace-analyze.py timeline <trace> --window 100ms --adaptive`
- Flamegraph: `trace-flamegraph.sh <trace> --open`
- Interactive: `trace-speedscope.sh <trace>`
- Compare: `trace-analyze.py diff before.json after.json`
- Pipe: `xtrace ./app | trace-flamegraph - --open`
WINDSURF_RULE
    echo -e "  ${GREEN}✓${NC} Windsurf: rule → $WINDSURF_RULES/xtrace-profiling.md"
else
    echo -e "  ${CYAN}·${NC} Windsurf: not detected"
fi

# ── Zed ──────────────────────────────────────────────────────────────────────
# Zed reads .zed/rules/ or slash commands from extensions
ZED_RULES="$HOME/.config/zed/rules"
if [ -d "$HOME/.config/zed" ] || command -v zed &>/dev/null; then
    mkdir -p "$ZED_RULES"
    cat > "$ZED_RULES/xtrace-profiling.md" <<'ZED_RULE'
When asked about CPU profiling on macOS, use the xtrace toolchain:

- `xtrace -d 10 ./binary` — record + summarize (like `time`)
- `trace-analyze.py summary <trace> --top 20` — find hotspots
- `trace-analyze.py timeline <trace> --window 100ms` — time-bucketed view
- `trace-flamegraph.sh <trace> --open` — flamegraph in browser
- `trace-speedscope.sh <trace>` — interactive analysis
- Pipe: `xtrace ./app | trace-flamegraph - --open`
ZED_RULE
    echo -e "  ${GREEN}✓${NC} Zed: rule → $ZED_RULES/xtrace-profiling.md"
else
    echo -e "  ${CYAN}·${NC} Zed: not detected"
fi

# ── Aider ────────────────────────────────────────────────────────────────────
# Aider reads .aider.conf.yml and conventions from .aider/
AIDER_DIR="$HOME/.aider"
if command -v aider &>/dev/null; then
    mkdir -p "$AIDER_DIR"
    cat > "$AIDER_DIR/xtrace-profiling.md" <<'AIDER_RULE'
# CPU Profiling Convention

For macOS CPU profiling, use the xtrace toolchain (Instruments/xctrace wrapper):

- `xtrace -d 10 ./binary` — record trace + print summary
- `trace-analyze.py summary <trace> --json --top 20` — machine-readable hotspots
- `trace-analyze.py calltree <trace> --min-pct 3` — call hierarchy
- `trace-flamegraph.sh <trace> --open` — flamegraph
- `trace-analyze.py diff before.json after.json` — compare profiles
AIDER_RULE
    echo -e "  ${GREEN}✓${NC} Aider: convention → $AIDER_DIR/xtrace-profiling.md"
else
    echo -e "  ${CYAN}·${NC} Aider: not detected"
fi

# ── Cline (VS Code) ─────────────────────────────────────────────────────────
# Cline reads .clinerules for project-level instructions
# Global custom instructions are in VS Code settings, but we can note it
if command -v code &>/dev/null; then
    echo -e "  ${CYAN}·${NC} Cline/VS Code: add xtrace to your Cline custom instructions in VS Code settings"
    echo "      Or create .clinerules in your project with profiling instructions"
else
    echo -e "  ${CYAN}·${NC} Cline: VS Code not detected"
fi

# ── GitHub Copilot ───────────────────────────────────────────────────────────
# Copilot reads .github/copilot-instructions.md for repo-level context
COPILOT_DIR="$HOME/.github"
if command -v gh &>/dev/null && gh extension list 2>/dev/null | grep -q copilot; then
    mkdir -p "$COPILOT_DIR"
    if [ ! -f "$COPILOT_DIR/copilot-instructions.md" ]; then
        cat > "$COPILOT_DIR/copilot-instructions.md" <<'COPILOT_INST'
## CPU Profiling

For macOS profiling, use the xtrace toolchain:
- `xtrace -d 10 ./binary` — record + summarize
- `trace-analyze.py summary <trace> --top 20` — hotspots
- `trace-flamegraph.sh <trace> --open` — flamegraph
- `trace-speedscope.sh <trace>` — interactive analysis
COPILOT_INST
        echo -e "  ${GREEN}✓${NC} GitHub Copilot: instructions → $COPILOT_DIR/copilot-instructions.md"
    else
        echo -e "  ${YELLOW}!${NC} GitHub Copilot: $COPILOT_DIR/copilot-instructions.md already exists — not overwriting"
        echo "      Add xtrace instructions manually if desired"
    fi
else
    echo -e "  ${CYAN}·${NC} GitHub Copilot: not detected"
fi

# ── Check optional tools ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Optional tools:${NC}"

if command -v inferno-flamegraph &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} inferno installed"
else
    echo -e "  ${YELLOW}!${NC} inferno not found: cargo install inferno"
fi

if command -v speedscope &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} speedscope installed"
else
    echo -e "  ${YELLOW}!${NC} speedscope not found: npm install -g speedscope"
fi

echo ""
echo -e "${GREEN}${BOLD}Done.${NC} Try: ${BOLD}xtrace -d 3 /usr/bin/yes${NC}"
