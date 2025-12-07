#!/bin/bash

# Installer for MRM Manager v1.0 (Hybrid: Local + Online)
INSTALL_DIR="/opt/mrm-manager"
REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main"

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

echo -e "${BLUE}Installing MRM Manager v3.3...${NC}"
mkdir -p "$INSTALL_DIR"

# List of files to install
FILES=(
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

# Optional files
OPT_FILES=(
    "index.html"
)

# Function to install a file
install_file() {
    local FILE=$1
    local IS_OPTIONAL=$2
    
    # 1. Try Local Install (Current Directory)
    if [ -f "./$FILE" ]; then
        cp "./$FILE" "$INSTALL_DIR/$FILE"
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Installed (Local): $FILE${NC}"
        return 0
    fi

    # 2. Try Online Install (Download from GitHub)
    echo -ne "Downloading $FILE... "
    if curl -s -f -o "$INSTALL_DIR/$FILE" "$REPO_URL/$FILE"; then
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}Failed!${NC}"
        if [ "$IS_OPTIONAL" != "true" ]; then
            return 1
        fi
    fi
}

# Main Installation Loop
echo -e "${YELLOW}Checking source...${NC}"

# Check connection if local files are missing
if [ ! -f "./utils.sh" ]; then
    echo -e "${BLUE}Local files not found. Attempting download from GitHub...${NC}"
    curl -s --head "$REPO_URL/main.sh" | head -n 1 | grep "200" > /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Cannot connect to GitHub repo.${NC}"
        echo -e "Check your internet connection or REPO_URL."
        exit 1
    fi
fi

# Install Core Files
for FILE in "${FILES[@]}"; do
    install_file "$FILE" "false"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Critical Error: Failed to install $FILE${NC}"
        exit 1
    fi
done

# Install Optional Files
for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true"
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