#!/bin/bash

# Installer for Modular MRM Manager
INSTALL_DIR="/opt/mrm-manager"
REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/manager"

echo "Installing/Updating MRM Manager..."

mkdir -p "$INSTALL_DIR"

# Download Modules
curl -s -o "$INSTALL_DIR/utils.sh" "$REPO_URL/utils.sh"
curl -s -o "$INSTALL_DIR/ssl.sh" "$REPO_URL/ssl.sh"
curl -s -o "$INSTALL_DIR/node.sh" "$REPO_URL/node.sh"
curl -s -o "$INSTALL_DIR/theme.sh" "$REPO_URL/theme.sh"
curl -s -o "$INSTALL_DIR/main.sh" "$REPO_URL/main.sh"

# Make executable
chmod +x "$INSTALL_DIR/"*.sh

# Run
bash "$INSTALL_DIR/main.sh"