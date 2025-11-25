#!/bin/bash

# ==========================================
# THEME INSTALLER (Logic Only)
# ==========================================

# 1. تنظیم آدرس فایل HTML شما در گیت‌هاب
# IMPORTANT: Replace this URL with YOUR raw github url of index.html
TEMPLATE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/templates/subscription/index.html"

# Paths
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

# Colors
CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: Please run as root.${NC}"; exit 1; fi

# Helper to extract existing values
get_prev() { if [ -f "$TEMPLATE_FILE" ]; then grep 'id="brandTxt"' "$TEMPLATE_FILE" | head -n1 | sed -E 's/.*id="brandTxt">([^<]+)<.*/\1/'; fi }
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'; }

clear
echo -e "${CYAN}=== FarsNetVIP Theme Installer ===${NC}"

# 2. Get Inputs
PREV_BRAND=$(get_prev)
[ -z "$PREV_BRAND" ] && PREV_BRAND="FarsNetVIP"

read -p "Brand Name [$PREV_BRAND]: " IN_BRAND
read -p "Bot Username (No @) [MyBot]: " IN_BOT
read -p "Support ID (No @) [Support]: " IN_SUP
read -p "News Text [خوش آمدید]: " IN_NEWS

[ -z "$IN_BRAND" ] && IN_BRAND="$PREV_BRAND"
[ -z "$IN_BOT" ] && IN_BOT="MyBot"
[ -z "$IN_SUP" ] && IN_SUP="Support"
[ -z "$IN_NEWS" ] && IN_NEWS="خوش آمدید"

# Fixed Links
LNK_AND="https://play.google.com/store/apps/details?id=com.v2ray.ang"
LNK_IOS="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"
LNK_WIN="https://github.com/2dust/v2rayN/releases"

# 3. Download Template
echo -e "\n${BLUE}Downloading template...${NC}"
mkdir -p "$TEMPLATE_DIR"

if curl -fsSL "$TEMPLATE_URL" -o "$TEMPLATE_FILE"; then
    echo -e "${GREEN}✔ Download successful.${NC}"
else
    echo -e "${RED}✘ Download failed! Check URL.${NC}"
    exit 1
fi

# 4. Fix Encoding (Anti-Crash 500)
python3 -c "import sys; f='$TEMPLATE_FILE'; d=open(f,'rb').read(); open(f,'w',encoding='utf-8').write(d.decode('utf-8','ignore'))"

# 5. Replace Variables
echo -e "${BLUE}Configuring theme...${NC}"
sed -i "s|__BRAND__|$(sed_escape "$IN_BRAND")|g" "$TEMPLATE_FILE"
sed -i "s|__BOT__|$(sed_escape "$IN_BOT")|g" "$TEMPLATE_FILE"
sed -i "s|__SUP__|$(sed_escape "$IN_SUP")|g" "$TEMPLATE_FILE"
sed -i "s|__NEWS__|$(sed_escape "$IN_NEWS")|g" "$TEMPLATE_FILE"
sed -i "s|__ANDROID__|$LNK_AND|g" "$TEMPLATE_FILE"
sed -i "s|__IOS__|$LNK_IOS|g" "$TEMPLATE_FILE"
sed -i "s|__WIN__|$LNK_WIN|g" "$TEMPLATE_FILE"

# 6. Update Panel Config
if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

# 7. Restart Panel
echo -e "${BLUE}Restarting panel...${NC}"
if command -v pasarguard &> /dev/null; then
    pasarguard restart
else
    systemctl restart pasarguard 2>/dev/null
fi

echo -e "${GREEN}✔ Theme Installed Successfully!${NC}"