#!/bin/bash

# ==========================================
# THEME INSTALLER (Python-Based Replacement - UTF8 Safe)
# ==========================================

# 1. تنظیمات
TEMPLATE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/templates/subscription/index.html"
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: Please run as root.${NC}"; exit 1; fi

# --- تابع استخراج امن با پایتون (برای جلوگیری از خطای sed) ---
get_val_py() {
    python3 -c "
import re
try:
    with open('$TEMPLATE_FILE', 'r', encoding='utf-8', errors='ignore') as f:
        c = f.read()
    m = re.search(r'$1', c)
    print(m.group(1) if m else '')
except: pass
"
}

fetch_defaults() {
    echo -e "${BLUE}Reading current configuration...${NC}"
    
    if [ -f "$TEMPLATE_FILE" ]; then
        # استفاده از Regex پایتون برای خواندن مقادیر قبلی
        DEF_BRAND=$(get_val_py 'id="brandTxt"[^>]*data-text="([^"]+)"')
        if [ -z "$DEF_BRAND" ]; then DEF_BRAND=$(get_val_py 'id="brandTxt"[^>]*>([^<]+)<'); fi
        
        DEF_BOT=$(get_val_py 'class="bot-link".*href="https:\/\/t\.me\/([^"]+)"')
        DEF_SUP=$(get_val_py 'class="btn btn-dark".*href="https:\/\/t\.me\/([^"]+)"')
        DEF_NEWS=$(get_val_py 'id="nT">([^<]+)<')
    fi

    # Defaults
    [ -z "$DEF_BRAND" ] && DEF_BRAND="FarsNetVIP"
    [ -z "$DEF_BOT" ] && DEF_BOT="MyBot"
    [ -z "$DEF_SUP" ] && DEF_SUP="Support"
    [ -z "$DEF_NEWS" ] && DEF_NEWS="خوش آمدید"
}

clear
echo -e "${CYAN}=== FarsNetVIP Theme Installer (UTF-8 Safe) ===${NC}"

# 2. خواندن مقادیر
fetch_defaults

echo -e "Enter new values or press ${YELLOW}ENTER${NC} to keep current:"
echo ""

read -p "Brand Name [$DEF_BRAND]: " IN_BRAND
read -p "Bot Username (No @) [$DEF_BOT]: " IN_BOT
read -p "Support ID (No @) [$DEF_SUP]: " IN_SUP
read -p "News Text [$DEF_NEWS]: " IN_NEWS

[ -z "$IN_BRAND" ] && IN_BRAND="$DEF_BRAND"
[ -z "$IN_BOT" ] && IN_BOT="$DEF_BOT"
[ -z "$IN_SUP" ] && IN_SUP="$DEF_SUP"
[ -z "$IN_NEWS" ] && IN_NEWS="$DEF_NEWS"

# Links
LNK_AND="https://play.google.com/store/apps/details?id=com.v2ray.ang"
LNK_IOS="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"
LNK_WIN="https://github.com/2dust/v2rayN/releases"

# 3. دانلود
echo -e "\n${BLUE}Downloading template...${NC}"
mkdir -p "$TEMPLATE_DIR"

if curl -fsSL "$TEMPLATE_URL" -o "$TEMPLATE_FILE"; then
    echo -e "${GREEN}✔ Download successful.${NC}"
else
    echo -e "${RED}✘ Download failed! Check URL.${NC}"
    exit 1
fi

# 4. جایگزینی امن با پایتون (Anti-Crash)
echo -e "${BLUE}Applying configurations (Safe Mode)...${NC}"

export IN_BRAND IN_BOT IN_SUP IN_NEWS LNK_AND LNK_IOS LNK_WIN
python3 - << 'EOF'
import os

file_path = "/var/lib/pasarguard/templates/subscription/index.html"
brand = os.environ.get('IN_BRAND', 'FarsNetVIP')
bot = os.environ.get('IN_BOT', 'MyBot')
sup = os.environ.get('IN_SUP', 'Support')
news = os.environ.get('IN_NEWS', 'Welcome')
l_and = os.environ.get('LNK_AND', '#')
l_ios = os.environ.get('LNK_IOS', '#')
l_win = os.environ.get('LNK_WIN', '#')

try:
    with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    # جایگزینی‌ها
    content = content.replace('__BRAND__', brand)
    content = content.replace('__BOT__', bot)
    content = content.replace('__SUP__', sup)
    content = content.replace('__NEWS__', news)
    content = content.replace('__ANDROID__', l_and)
    content = content.replace('__IOS__', l_ios)
    content = content.replace('__WIN__', l_win)

    # ذخیره با فرمت صحیح UTF-8
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(content)
    
    print("Template updated successfully with UTF-8 encoding.")
except Exception as e:
    print(f"Error updating template: {e}")
    exit(1)
EOF

# 5. کانفیگ پنل
if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

# 6. ریستارت
echo -e "${BLUE}Restarting panel...${NC}"
if command -v pasarguard &> /dev/null; then
    pasarguard restart
else
    systemctl restart pasarguard 2>/dev/null
fi

echo -e "${GREEN}✔ Done! Your panel works with Persian text now.${NC}"