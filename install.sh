#!/bin/bash

# Installer for Modular MRM Manager (Local Version)
INSTALL_DIR="/opt/mrm-manager"
CURRENT_DIR=$(pwd)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${BLUE}Installing MRM Manager from local files...${NC}"
mkdir -p "$INSTALL_DIR"

# Function to copy files
install_file() {
    local FILE=$1
    if [ -f "$CURRENT_DIR/$FILE" ]; then
        cp "$CURRENT_DIR/$FILE" "$INSTALL_DIR/$FILE"
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Installed: $FILE${NC}"
    else
        echo -e "${RED}✘ Missing file: $FILE (Make sure you are in the correct folder)${NC}"
    fi
}

# Install Modules
install_file "utils.sh"
install_file "ssl.sh"
install_file "node.sh"
install_file "theme.sh"
install_file "site.sh"
install_file "inbound.sh"
install_file "backup.sh"
install_file "monitor.sh"
install_file "domain_separator.sh"
install_file "port_manager.sh"
install_file "main.sh"

# Create shortcut command
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
chmod +x /usr/local/bin/mrm

echo -e "${GREEN}✔ Shortcut created: type 'mrm' to run${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo ""

# Run
bash "$INSTALL_DIR/main.sh"