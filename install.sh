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
curl -s -o "$INSTALL_DIR/site.sh" "$REPO_URL/site.sh"
curl -s -o "$INSTALL_DIR/inbound.sh" "$REPO_URL/inbound.sh"
curl -s -o "$INSTALL_DIR/backup.sh" "$REPO_URL/backup.sh"
curl -s -o "$INSTALL_DIR/monitor.sh" "$REPO_URL/monitor.sh"
curl -s -o "$INSTALL_DIR/main.sh" "$REPO_URL/main.sh"

chmod +x "$INSTALL_DIR/"*.sh
bash "$INSTALL_DIR/main.sh"
ln -sf /opt/mrm-manager/main.sh /usr/local/bin/mrm