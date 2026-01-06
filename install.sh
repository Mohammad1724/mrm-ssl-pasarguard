#!/bin/bash

# ==========================================
# MRM Manager Installer v3.2
# ==========================================

INSTALL_DIR="/opt/mrm-manager"
REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/manager"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      MRM Manager Installer v3.2              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Create directories
echo -e "${BLUE}[1/4] Creating directories...${NC}"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/inbound"

# Core Files List
FILES=(
    "utils.sh"
    "ui.sh"
    "ssl.sh"
    "backup.sh"
    "domain_separator.sh"
    "site.sh"
    "theme.sh"
    "migrator.sh"
    "mirza.sh"
    "main.sh"
)

# Inbound Module Files
INBOUND_FILES=(
    "inbound/main.sh"
    "inbound/lib.sh"
    "inbound/create.sh"
    "inbound/manage.sh"
    "inbound/tools.sh"
)

# Optional files
OPT_FILES=(
    "index.html"
)

install_file() {
    local FILE=$1
    local IS_OPTIONAL=$2
    local TARGET_PATH="$INSTALL_DIR/$FILE"
    
    # Create subdirectory if needed
    local DIR=$(dirname "$TARGET_PATH")
    mkdir -p "$DIR"

    # Try Local Install
    if [ -f "./$FILE" ]; then
        cp "./$FILE" "$TARGET_PATH"
        chmod +x "$TARGET_PATH"
        echo -e "  ${GREEN}✔${NC} Installed (Local): $FILE"
        return 0
    fi

    # Try Online Install
    if curl -s -L -f -o "$TARGET_PATH" "$REPO_URL/$FILE" 2>/dev/null; then
        chmod +x "$TARGET_PATH"
        echo -e "  ${GREEN}✔${NC} Downloaded: $FILE"
        return 0
    else
        if [ "$IS_OPTIONAL" == "true" ]; then
            echo -e "  ${YELLOW}⚠${NC} Skipped optional: $FILE"
            return 0
        else
            echo -e "  ${RED}✘${NC} Failed: $FILE"
            return 1
        fi
    fi
}

# Install Core Files
echo -e "${BLUE}[2/4] Installing core files...${NC}"
for FILE in "${FILES[@]}"; do
    if ! install_file "$FILE" "false"; then
        echo -e "${RED}CRITICAL ERROR: Installation failed at $FILE${NC}"
        exit 1
    fi
done

# Install Inbound Module
echo -e "${BLUE}[3/4] Installing inbound module...${NC}"
for FILE in "${INBOUND_FILES[@]}"; do
    if ! install_file "$FILE" "false"; then
        echo -e "${RED}CRITICAL ERROR: Installation failed at $FILE${NC}"
        exit 1
    fi
done

# Install Optional Files
echo -e "${BLUE}[4/4] Installing optional files...${NC}"
for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true"
done

# Cleanup old files
echo ""
echo -e "${YELLOW}Cleaning up old files...${NC}"
rm -f "$INSTALL_DIR/inbound.sh" 2>/dev/null && echo -e "  ${GREEN}✔${NC} Removed old inbound.sh"
rm -f "$INSTALL_DIR/node.sh" 2>/dev/null
rm -f "$INSTALL_DIR/port_manager.sh" 2>/dev/null

# Create shortcut command
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
chmod +x /usr/local/bin/mrm

# Summary
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        ${GREEN}✔ Installation Complete!${CYAN}              ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  Installed files:                            ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    • Core modules: ${GREEN}${#FILES[@]}${NC}                        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    • Inbound module: ${GREEN}${#INBOUND_FILES[@]}${NC} files               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${YELLOW}Type 'mrm' to run the manager${NC}              ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Run
read -p "Run MRM Manager now? (y/n): " RUN_NOW
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    bash "$INSTALL_DIR/main.sh"
fi