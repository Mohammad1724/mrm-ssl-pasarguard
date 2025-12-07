#!/bin/bash

INSTALL_DIR="/opt/mrm-manager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${BLUE}Installing MRM Manager v3.3...${NC}"
echo -e "${BLUE}Source: $SCRIPT_DIR${NC}"
mkdir -p "$INSTALL_DIR"

REQUIRED_FILES=(
    "utils.sh"
    "ui.sh"
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

OPTIONAL_FILES=(
    "index.html"
)

MISSING=0
for FILE in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$FILE" ]; then
        echo -e "${RED}✘ Missing: $FILE${NC}"
        MISSING=1
    fi
done

if [ $MISSING -eq 1 ]; then
    echo -e "${RED}Please ensure all files are present.${NC}"
    exit 1
fi

for FILE in "${REQUIRED_FILES[@]}"; do
    cp "$SCRIPT_DIR/$FILE" "$INSTALL_DIR/$FILE"
    chmod +x "$INSTALL_DIR/$FILE"
    echo -e "${GREEN}✔ $FILE${NC}"
done

for FILE in "${OPTIONAL_FILES[@]}"; do
    if [ -f "$SCRIPT_DIR/$FILE" ]; then
        cp "$SCRIPT_DIR/$FILE" "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ $FILE (optional)${NC}"
    fi
done

ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
chmod +x /usr/local/bin/mrm

echo ""
echo -e "${GREEN}✔ Installation Complete!${NC}"
echo -e "${YELLOW}Type 'mrm' to run.${NC}"
echo ""

bash "$INSTALL_DIR/main.sh"