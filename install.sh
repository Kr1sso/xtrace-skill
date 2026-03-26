#!/bin/bash
# install.sh — Install xtrace to PATH, Pi, and Cursor
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}xtrace installer${NC}"
echo ""

# ── Symlink scripts to PATH ─────────────────────────────────────────────────
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
    echo "  Add to ~/.zshrc or ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

mkdir -p "$INSTALL_DIR"
echo -e "${BOLD}PATH:${NC} $INSTALL_DIR"

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
        echo -e "  ${YELLOW}!${NC} $DEST_NAME — exists, not a symlink, skipping"
        continue
    fi
    ln -sf "$SRC" "$DEST"
    echo -e "  ${GREEN}✓${NC} $DEST_NAME"
done

# ── Helper: symlink skill folder ─────────────────────────────────────────────
install_skill() {
    local skills_dir="$1"
    local name="$2"
    local label="$3"
    local dest="$skills_dir/$name"

    if [ -L "$dest" ]; then
        ln -sf "$SCRIPT_DIR" "$dest"
        echo -e "  ${GREEN}✓${NC} ${label}: updated"
    elif [ -d "$dest" ]; then
        rm -rf "$dest"
        ln -s "$SCRIPT_DIR" "$dest"
        echo -e "  ${GREEN}✓${NC} ${label}: replaced directory with symlink"
    else
        mkdir -p "$skills_dir"
        ln -s "$SCRIPT_DIR" "$dest"
        echo -e "  ${GREEN}✓${NC} ${label}: installed"
    fi
}

# ── Pi skill ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Skills:${NC}"

if [ -d "$HOME/.pi/agent/skills" ]; then
    install_skill "$HOME/.pi/agent/skills" "instruments" "Pi"
else
    echo -e "  ${CYAN}·${NC} Pi: not detected"
fi

# ── Cursor skill (Agent Skills standard) ─────────────────────────────────────
# Cursor reads: ~/.cursor/skills/<name>/ with SKILL.md
if [ -d "$HOME/.cursor" ]; then
    install_skill "$HOME/.cursor/skills" "instruments" "Cursor"
else
    echo -e "  ${CYAN}·${NC} Cursor: not detected"
fi

# ── Claude Code skill ────────────────────────────────────────────────────────
# Claude Code reads: ~/.claude/skills/<name>/ with SKILL.md
# Also reads ~/.cursor/skills/ and ~/.codex/skills/ for compatibility
if [ -d "$HOME/.claude" ] || command -v claude &>/dev/null; then
    mkdir -p "$HOME/.claude/skills"
    install_skill "$HOME/.claude/skills" "instruments" "Claude Code"
else
    echo -e "  ${CYAN}·${NC} Claude Code: not detected"
fi

# ── Optional tools ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Tools:${NC}"

if command -v inferno-flamegraph &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} inferno"
else
    echo -e "  ${YELLOW}!${NC} inferno not found (flamegraph generator)"
    if command -v cargo &>/dev/null; then
        read -rp "  Install inferno via cargo? [y/N] " REPLY
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            cargo install inferno 2>&1 | tail -1
            echo -e "  ${GREEN}✓${NC} inferno installed"
        else
            echo "      Skipped. Install later: cargo install inferno"
        fi
    else
        echo "      Install Rust (https://rustup.rs), then: cargo install inferno"
    fi
fi

if command -v speedscope &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} speedscope"
else
    echo -e "  ${YELLOW}!${NC} speedscope not found (interactive profiler UI)"
    if command -v npm &>/dev/null; then
        read -rp "  Install speedscope via npm? [y/N] " REPLY
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            npm install -g speedscope 2>&1 | tail -1
            echo -e "  ${GREEN}✓${NC} speedscope installed"
        else
            echo "      Skipped. Install later: npm install -g speedscope"
        fi
    else
        echo "      Install Node.js first, then: npm install -g speedscope"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}Done.${NC} Try: ${BOLD}xtrace -d 3 /usr/bin/yes${NC}"
