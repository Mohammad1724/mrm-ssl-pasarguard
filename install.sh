#!/bin/bash

# ==========================================
# MRM Manager Installer v3.0
# ==========================================

INSTALL_DIR="/opt/mrm-manager"
REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/manager"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${BLUE}Installing MRM Manager v3.0...${NC}"
mkdir -p "$INSTALL_DIR"

# Core files only (node.sh and port_manager.sh removed)
FILES=(
    "utils.sh"
    "ui.sh"
    "ssl.sh"
    "backup.sh"
    "inbound.sh"
    "domain_separator.sh"
    "site.sh"
    "theme.sh"
    "migrator.sh"
    "main.sh"
)

# Optional files
OPT_FILES=(
    "index.html"
)

install_file() {
    local FILE=$1
    local IS_OPTIONAL=$2

    # Try Local Install
    if [ -f "./$FILE" ]; then
        cp "./$FILE" "$INSTALL_DIR/$FILE"
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Installed (Local): $FILE${NC}"
        return 0
    fi

    # Try Online Install
    if curl -s -L -f -o "$INSTALL_DIR/$FILE" "$REPO_URL/$FILE"; then
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Downloaded: $FILE${NC}"
        return 0
    else
        if [ "$IS_OPTIONAL" == "true" ]; then
            echo -e "${YELLOW}⚠ Skipped optional: $FILE${NC}"
            return 0
        else
            echo -e "${RED}✘ Failed: $FILE${NC}"
            return 1
        fi
    fi
}

echo -e "${YELLOW}Fetching files...${NC}"

# Install Core Files
for FILE in "${FILES[@]}"; do
    if ! install_file "$FILE" "false"; then
        echo -e "${RED}CRITICAL: Could not install $FILE${NC}"
        exit 1
    fi
done

# Install Optional Files
for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true"
done

# Remove old files if exist
rm -f "$INSTALL_DIR/node.sh" 2>/dev/null
rm -f "$INSTALL_DIR/port_manager.sh" 2>/dev/null

# Create shortcut
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
chmod +x /usr/local/bin/mrm

echo ""
echo -e "${GREEN}✔ Installation Complete!${NC}"
echo -e "${YELLOW}Type 'mrm' to run the manager.${NC}"
echo ""

# Run
bash "$INSTALL_DIR/main.sh"