#!/bin/bash

# ==========================================
# THEME INSTALLER (Smart Cache Version)
# ==========================================

# 1. تنظیمات
TEMPLATE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/templates/subscription/index.html"
TEMPLATE_DIR="/var/lib/pasarguard/templates/subscription"
TEMPLATE_FILE="$TEMPLATE_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"

# Colors
CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: Please run as root.${NC}"; exit 1; fi

# --- توابع کمکی برای استخراج اطلاعات قبلی ---
get_current_val() {
    local match_str=$1
    local sed_pattern=$2
    if [ -f "$TEMPLATE_FILE" ]; then
        # تلاش برای پیدا کردن مقدار در فایل موجود
        grep "$match_str" "$TEMPLATE_FILE" | head -n1 | sed -E "$sed_pattern"
    fi
}

# استخراج مقادیر فعلی از فایل HTML نصب شده
fetch_defaults() {
    # 1. Brand Name (پیدا کردن متن داخل آی‌دی brandTxt)
    DEF_BRAND=$(get_current_val 'id="brandTxt"' 's/.*id="brandTxt">([^<]+)<.*/\1/')
    
    # 2. Bot Username (پیدا کردن لینک تلگرام داخل کلاس bot-link)
    DEF_BOT=$(get_current_val 'class="bot-link"' 's/.*href="https:\/\/t\.me\/([^"]+)".*/\1/')
    
    # 3. Support ID (پیدا کردن لینک تلگرام داخل دکمه ساپورت یا btn-dark)
    DEF_SUP=$(get_current_val 'btn-dark' 's/.*href="https:\/\/t\.me\/([^"]+)".*/\1/')
    
    # 4. News Text (پیدا کردن متن داخل اسپنِ ticker)
    DEF_NEWS=$(get_current_val 'class="ticker"' 's/.*<span.*>([^<]+)<\/span>.*/\1/')

    # تنظیم پیش‌فرض‌ها اگر فایل وجود نداشت یا چیزی پیدا نشد
    [ -z "$DEF_BRAND" ] && DEF_BRAND="FarsNetVIP"
    [ -z "$DEF_BOT" ] && DEF_BOT="MyBot"
    [ -z "$DEF_SUP" ] && DEF_SUP="Support"
    [ -z "$DEF_NEWS" ] && DEF_NEWS="خوش آمدید"
}

sed_escape() { printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'; }

clear
echo -e "${CYAN}=== FarsNetVIP Theme Installer ===${NC}"

# 2. خواندن مقادیر قبلی
echo -e "${BLUE}Reading current configuration...${NC}"
fetch_defaults

# نمایش و دریافت ورودی (با مقادیر پیش‌فرض هوشمند)
echo -e "Enter new values or press ${YELLOW}ENTER${NC} to keep current:"
echo ""

read -p "Brand Name [$DEF_BRAND]: " IN_BRAND
read -p "Bot Username (No @) [$DEF_BOT]: " IN_BOT
read -p "Support ID (No @) [$DEF_SUP]: " IN_SUP
read -p "News Text [$DEF_NEWS]: " IN_NEWS

# اگر کاربر چیزی وارد نکرد، از مقدار پیش‌فرض (قبلی) استفاده کن
[ -z "$IN_BRAND" ] && IN_BRAND="$DEF_BRAND"
[ -z "$IN_BOT" ] && IN_BOT="$DEF_BOT"
[ -z "$IN_SUP" ] && IN_SUP="$DEF_SUP"
[ -z "$IN_NEWS" ] && IN_NEWS="$DEF_NEWS"

# لینک‌های دانلود ثابت
LNK_AND="https://play.google.com/store/apps/details?id=com.v2ray.ang"
LNK_IOS="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"
LNK_WIN="https://github.com/2dust/v2rayN/releases"

# 3. دانلود تم جدید
echo -e "\n${BLUE}Downloading template...${NC}"
mkdir -p "$TEMPLATE_DIR"

if curl -fsSL "$TEMPLATE_URL" -o "$TEMPLATE_FILE"; then
    echo -e "${GREEN}✔ Download successful.${NC}"
else
    echo -e "${RED}✘ Download failed! Check URL.${NC}"
    exit 1
fi

# 4. جلوگیری از ارور 500 (Fix Encoding)
python3 -c "import sys; f='$TEMPLATE_FILE'; d=open(f,'rb').read(); open(f,'w',encoding='utf-8').write(d.decode('utf-8','ignore'))"

# 5. جایگزینی متغیرها در فایل جدید
echo -e "${BLUE}Applying configurations...${NC}"
sed -i "s|__BRAND__|$(sed_escape "$IN_BRAND")|g" "$TEMPLATE_FILE"
sed -i "s|__BOT__|$(sed_escape "$IN_BOT")|g" "$TEMPLATE_FILE"
sed -i "s|__SUP__|$(sed_escape "$IN_SUP")|g" "$TEMPLATE_FILE"
sed -i "s|__NEWS__|$(sed_escape "$IN_NEWS")|g" "$TEMPLATE_FILE"
sed -i "s|__ANDROID__|$LNK_AND|g" "$TEMPLATE_FILE"
sed -i "s|__IOS__|$LNK_IOS|g" "$TEMPLATE_FILE"
sed -i "s|__WIN__|$LNK_WIN|g" "$TEMPLATE_FILE"

# 6. تنظیم پنل
if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi
# حذف تنظیمات تکراری قدیمی
sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
# افزودن تنظیمات جدید
echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

# 7. ریستارت پنل
echo -e "${BLUE}Restarting panel...${NC}"
if command -v pasarguard &> /dev/null; then
    pasarguard restart
else
    systemctl restart pasarguard 2>/dev/null
fi

echo -e "${GREEN}✔ Theme Installed/Updated Successfully!${NC}"
echo -e "Brand: $IN_BRAND | Bot: @$IN_BOT"