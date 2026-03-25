#!/bin/bash
# install.sh — Install xtrace scripts to PATH and register with AI coding agents
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REFERENCE="$SCRIPT_DIR/agent-rules/xtrace-reference.md"
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

# ── Helper: install a rule file (skip if already exists and not ours) ────────
install_rule() {
    local dest="$1"
    local header="$2"  # optional header to prepend (e.g. YAML frontmatter)
    local dir
    dir=$(dirname "$dest")
    mkdir -p "$dir"

    # If file exists and wasn't created by us, don't overwrite
    if [ -f "$dest" ] && ! grep -q "xtrace" "$dest" 2>/dev/null; then
        echo -e "  ${YELLOW}!${NC} $(basename "$dest") exists, not overwriting (add xtrace section manually)"
        return 1
    fi

    if [ -n "$header" ]; then
        printf '%s\n' "$header" > "$dest"
        cat "$REFERENCE" >> "$dest"
    else
        cp "$REFERENCE" "$dest"
    fi
    return 0
}

# ── Register with AI coding agents ──────────────────────────────────────────
echo ""
echo -e "${BOLD}AI Agent Integration:${NC}"

# ── Pi ───────────────────────────────────────────────────────────────────────
PI_SKILL_DIR="$HOME/.pi/agent/skills/instruments"
if [ -d "$HOME/.pi/agent/skills" ]; then
    if [ -L "$PI_SKILL_DIR" ]; then
        echo -e "  ${GREEN}✓${NC} Pi: already symlinked"
    elif [ -d "$PI_SKILL_DIR" ]; then
        rm -rf "$PI_SKILL_DIR"
        ln -s "$SCRIPT_DIR" "$PI_SKILL_DIR"
        echo -e "  ${GREEN}✓${NC} Pi: reinstalled skill → $PI_SKILL_DIR"
    else
        ln -s "$SCRIPT_DIR" "$PI_SKILL_DIR"
        echo -e "  ${GREEN}✓${NC} Pi: installed skill → $PI_SKILL_DIR"
    fi
else
    echo -e "  ${CYAN}·${NC} Pi: not detected"
fi

# ── Claude Code ──────────────────────────────────────────────────────────────
if [ -d "$HOME/.claude" ] || command -v claude &>/dev/null; then
    DEST="$HOME/.claude/commands/profile.md"
    HEADER="Profile a process or command using xtrace.
When the user runs /profile, follow the Dev Loop below.
"
    if install_rule "$DEST" "$HEADER"; then
        echo -e "  ${GREEN}✓${NC} Claude Code: /profile command"
    fi
else
    echo -e "  ${CYAN}·${NC} Claude Code: not detected"
fi

# ── Cursor ───────────────────────────────────────────────────────────────────
if [ -d "$HOME/.cursor" ]; then
    DEST="$HOME/.cursor/rules/xtrace-profiling.mdc"
    HEADER='---
description: CPU profiling on macOS using xtrace (Instruments/xctrace wrapper)
globs: ["*.c", "*.cpp", "*.swift", "*.rs", "*.m", "*.mm", "*.py", "*.js", "*.ts"]
alwaysApply: false
---
'
    if install_rule "$DEST" "$HEADER"; then
        echo -e "  ${GREEN}✓${NC} Cursor: rule installed"
    fi
else
    echo -e "  ${CYAN}·${NC} Cursor: not detected"
fi

# ── Windsurf ─────────────────────────────────────────────────────────────────
if [ -d "$HOME/.windsurf" ]; then
    DEST="$HOME/.windsurf/rules/xtrace-profiling.md"
    if install_rule "$DEST" ""; then
        echo -e "  ${GREEN}✓${NC} Windsurf: rule installed"
    fi
else
    echo -e "  ${CYAN}·${NC} Windsurf: not detected"
fi

# ── Zed ──────────────────────────────────────────────────────────────────────
if [ -d "$HOME/.config/zed" ] || command -v zed &>/dev/null; then
    DEST="$HOME/.config/zed/rules/xtrace-profiling.md"
    if install_rule "$DEST" ""; then
        echo -e "  ${GREEN}✓${NC} Zed: rule installed"
    fi
else
    echo -e "  ${CYAN}·${NC} Zed: not detected"
fi

# ── Aider ────────────────────────────────────────────────────────────────────
if command -v aider &>/dev/null; then
    DEST="$HOME/.aider/xtrace-profiling.md"
    if install_rule "$DEST" ""; then
        echo -e "  ${GREEN}✓${NC} Aider: convention installed"
    fi
else
    echo -e "  ${CYAN}·${NC} Aider: not detected"
fi

# ── Cline ────────────────────────────────────────────────────────────────────
if command -v code &>/dev/null; then
    echo -e "  ${CYAN}·${NC} Cline: add to custom instructions or create .clinerules in your project"
    echo "      Reference: $REFERENCE"
else
    echo -e "  ${CYAN}·${NC} Cline: not detected"
fi

# ── GitHub Copilot ───────────────────────────────────────────────────────────
if command -v gh &>/dev/null && gh extension list 2>/dev/null | grep -q copilot; then
    DEST="$HOME/.github/copilot-instructions.md"
    if install_rule "$DEST" ""; then
        echo -e "  ${GREEN}✓${NC} GitHub Copilot: instructions installed"
    fi
else
    echo -e "  ${CYAN}·${NC} GitHub Copilot: not detected"
fi

# ── Optional tools ───────────────────────────────────────────────────────────
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
