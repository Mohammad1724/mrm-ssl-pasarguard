#!/bin/bash

# مسیر نصب
INSTALL_DIR="/opt/mrm-manager"
REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/manager"

# ایجاد پوشه
mkdir -p "$INSTALL_DIR"

echo "Updating Manager..."

# دانلود ماژول‌ها
curl -s -o "$INSTALL_DIR/utils.sh" "$REPO_URL/utils.sh"
curl -s -o "$INSTALL_DIR/ssl.sh" "$REPO_URL/ssl.sh"
curl -s -o "$INSTALL_DIR/node.sh" "$REPO_URL/node.sh"
curl -s -o "$INSTALL_DIR/main.sh" "$REPO_URL/main.sh"

# پرمیشن اجرا
chmod +x "$INSTALL_DIR/"*.sh

# اجرای منوی اصلی
bash "$INSTALL_DIR/main.sh"