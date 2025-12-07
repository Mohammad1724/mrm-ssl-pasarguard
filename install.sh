#!/bin/bash

# Installer for Modular MRM Manager (Local Version)
INSTALL_DIR="/opt/mrm-manager"

# FIXED: Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo -e "${BLUE}Installing MRM Manager from local files...${NC}"
echo -e "${BLUE}Source: $SCRIPT_DIR${NC}"
mkdir -p "$INSTALL_DIR"

# Required files
REQUIRED_FILES=(
    "utils.sh"
    "ssl.sh"
    "node.sh"
    "theme.sh"
    "site.sh"
    "inbound.sh"
    "backup.sh"
    "monitor.sh"
    "domain_separator.sh"
    "port_manager.sh"
    "main.sh"
)

# Optional files
OPTIONAL_FILES=(
    "index.html"
)

# Check if all required files exist
MISSING=0
for FILE in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$FILE" ]; then
        echo -e "${RED}✘ Missing required file: $FILE${NC}"
        MISSING=1
    fi
done

if [ $MISSING -eq 1 ]; then
    echo -e "${RED}Please make sure all files are in the same folder as install.sh${NC}"
    exit 1
fi

# Install required files
for FILE in "${REQUIRED_FILES[@]}"; do
    cp "$SCRIPT_DIR/$FILE" "$INSTALL_DIR/$FILE"
    chmod +x "$INSTALL_DIR/$FILE"
    echo -e "${GREEN}✔ Installed: $FILE${NC}"
done

# Install optional files
for FILE in "${OPTIONAL_FILES[@]}"; do
    if [ -f "$SCRIPT_DIR/$FILE" ]; then
        cp "$SCRIPT_DIR/$FILE" "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Installed (optional): $FILE${NC}"
    fi
done

# Create shortcut command
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
chmod +x /usr/local/bin/mrm

echo ""
echo -e "${GREEN}✔ Installation Complete!${NC}"
echo -e "${YELLOW}Type 'mrm' to run the manager.${NC}"
echo ""

# Run
bash "$INSTALL_DIR/main.sh"