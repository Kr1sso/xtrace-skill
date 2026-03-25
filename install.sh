#!/bin/bash
# install.sh — Install xtrace scripts and optionally recommended tools
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

# Check common writable PATH locations
for dir in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
    if echo "$PATH" | tr ':' '\n' | grep -qx "$dir"; then
        INSTALL_DIR="$dir"
        break
    fi
done

if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/.local/bin"
    echo -e "${YELLOW}!${NC} $INSTALL_DIR is not in your PATH."
    echo "  Add this to your shell profile (~/.zshrc or ~/.bashrc):"
    echo ""
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

mkdir -p "$INSTALL_DIR"
echo -e "Installing to: ${BOLD}$INSTALL_DIR${NC}"
echo ""

# ── Symlink all scripts ─────────────────────────────────────────────────────
SCRIPTS=(xtrace trace-record.sh trace-analyze.py trace-flamegraph.sh
         trace-speedscope.sh trace-diff-flamegraph.sh trace-check.sh sample-quick.sh)

for script in "${SCRIPTS[@]}"; do
    SRC="$SCRIPT_DIR/scripts/$script"
    # Remove .sh/.py extension for the installed name (keep xtrace and trace-analyze.py as-is)
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
    echo -e "  ${GREEN}✓${NC} $DEST_NAME → $SRC"
done

# ── Install as pi skill ─────────────────────────────────────────────────────
PI_SKILL_DIR="$HOME/.pi/agent/skills/instruments"
if [ -d "$HOME/.pi/agent/skills" ]; then
    echo ""
    echo -e "${BOLD}Pi skill:${NC}"
    if [ -L "$PI_SKILL_DIR" ]; then
        echo -e "  ${GREEN}✓${NC} Already symlinked: $PI_SKILL_DIR"
    elif [ -d "$PI_SKILL_DIR" ]; then
        echo -e "  ${YELLOW}!${NC} $PI_SKILL_DIR exists as directory. Remove it to use symlink:"
        echo "    rm -rf $PI_SKILL_DIR && ln -s $SCRIPT_DIR $PI_SKILL_DIR"
    else
        ln -s "$SCRIPT_DIR" "$PI_SKILL_DIR"
        echo -e "  ${GREEN}✓${NC} Installed: $PI_SKILL_DIR → $SCRIPT_DIR"
    fi
fi

# ── Check optional tools ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Optional tools:${NC}"

if command -v inferno-flamegraph &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} inferno installed"
else
    echo -e "  ${YELLOW}!${NC} inferno not found — install for best flamegraphs:"
    echo "    cargo install inferno"
fi

if command -v speedscope &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} speedscope installed"
else
    echo -e "  ${YELLOW}!${NC} speedscope not found — install for interactive analysis:"
    echo "    npm install -g speedscope"
fi

echo ""
echo -e "${GREEN}${BOLD}Done.${NC} Try: ${BOLD}xtrace -d 3 /usr/bin/yes${NC}"
