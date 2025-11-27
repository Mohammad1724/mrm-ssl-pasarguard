#!/bin/bash

# Load Utils if run standalone
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# ==========================================
# 1. INSTALL / UPDATE 
# ==========================================
install_theme_wizard() {
    TEMPLATE_FILE="/var/lib/pasarguard/templates/subscription/index.html"
    TEMPLATE_DIR=$(dirname "$TEMPLATE_FILE")
    
    # 1. تهیه بکاپ از فایل فعلی (برای خواندن تنظیمات)
    # این مرحله حیاتی است تا اطلاعات نپرد
    if [ -s "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "/tmp/index_old.html"
    else
        echo "" > "/tmp/index_old.html"
    fi

    # 2. دانلود فایل خام و جدید از گیت‌هاب
    echo -e "\n${BLUE}Downloading latest template...${NC}"
    mkdir -p "$TEMPLATE_DIR"
    local TEMP_DL="/tmp/index_dl.html"
    rm -f "$TEMP_DL"

    if curl -L -o "$TEMP_DL" "$THEME_HTML_URL"; then
        if [ ! -s "$TEMP_DL" ]; then
            echo -e "${RED}✘ Downloaded file is empty! Check URL.${NC}"
            pause; return
        fi
    else
        echo -e "${RED}✘ Download failed! Connection error.${NC}"
        pause; return
    fi

    # 3. اجرای پایتون برای (۱) استخراج اطلاعات قبلی (۲) دریافت ورودی (۳) جایگزینی
    echo -e "${BLUE}Processing configuration...${NC}"

    export TEMPLATE_FILE TEMP_DL
    
    python3 -c "
import os
import re
import sys

# رنگ‌ها
CYAN = '\033[0;36m'
YELLOW = '\033[1;33m'
GREEN = '\033[0;32m'
NC = '\033[0m'

old_file = '/tmp/index_old.html'
new_file = '/tmp/index_dl.html'
final_file = os.environ.get('TEMPLATE_FILE')

# --- مقادیر پیش‌فرض ---
defaults = {
    'brand': 'FarsNetVIP',
    'bot': 'MyBot',
    'sup': 'Support',
    'news': 'خوش آمدید',
    'l_and': 'https://play.google.com/store/apps/details?id=com.v2ray.ang',
    'l_ios': 'https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690',
    'l_win': 'https://github.com/2dust/v2rayN/releases'
}

# --- تلاش برای خواندن تنظیمات قبلی ---
try:
    with open(old_file, 'r', encoding='utf-8', errors='ignore') as f:
        old_content = f.read()
        
    # 1. Brand: id="brandTxt" data-text="VALUE"
    m_brand = re.search(r'id=\"brandTxt\"[^>]*data-text=\"([^\"]+)\"', old_content)
    if m_brand: defaults['brand'] = m_brand.group(1)
    
    # 2. Bot: href="https://t.me/VALUE" ... class="bot-link"
    # نکته: ترتیب href و class ممکن است فرق کند، پس دو حالت را چک می‌کنیم
    m_bot = re.search(r'href=\"https:\/\/t\.me\/([^\"]+)\"[^>]*class=\"bot-link\"', old_content)
    if not m_bot:
        m_bot = re.search(r'class=\"bot-link\"[^>]*href=\"https:\/\/t\.me\/([^\"]+)\"', old_content)
    if m_bot: defaults['bot'] = m_bot.group(1)
    
    # 3. Support: href="https://t.me/VALUE" ... class="btn btn-dark"
    m_sup = re.search(r'href=\"https:\/\/t\.me\/([^\"]+)\"[^>]*class=\"btn btn-dark\"', old_content)
    if not m_sup:
        m_sup = re.search(r'class=\"btn btn-dark\"[^>]*href=\"https:\/\/t\.me\/([^\"]+)\"', old_content)
    if m_sup: defaults['sup'] = m_sup.group(1)
    
    # 4. News: id="nT">VALUE<
    m_news = re.search(r'id=\"nT\">\s*([^<]+)\s*<', old_content)
    if m_news: defaults['news'] = m_news.group(1).strip()

except Exception as e:
    pass # فایل قبلی وجود نداشت یا مشکلی داشت

# --- دریافت ورودی از کاربر ---
print(f'\n{CYAN}=== Theme Settings ==={NC}')
print(f'Press {YELLOW}ENTER{NC} to keep the current value [in brackets].\n')

def get_input(label, key):
    val = input(f'{label} [{defaults[key]}]: ').strip()
    if not val:
        return defaults[key]
    return val

new_brand = get_input('Brand Name', 'brand')
new_bot = get_input('Bot Username (No @)', 'bot')
new_sup = get_input('Support ID (No @)', 'sup')
new_news = get_input('News Text', 'news')

# --- اعمال روی فایل جدید ---
try:
    with open(new_file, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    content = content.replace('__BRAND__', new_brand)
    content = content.replace('__BOT__', new_bot)
    content = content.replace('__SUP__', new_sup)
    content = content.replace('__NEWS__', new_news)
    
    content = content.replace('__ANDROID__', defaults['l_and'])
    content = content.replace('__IOS__', defaults['l_ios'])
    content = content.replace('__WIN__', defaults['l_win'])

    # ذخیره در مسیر اصلی
    with open(final_file, 'w', encoding='utf-8') as f:
        f.write(content)
        
    print(f'\n{GREEN}✔ Settings saved successfully.{NC}')

except Exception as e:
    print(f'\nError processing file: {e}')
    sys.exit(1)
"

    # بررسی نتیجه پایتون
    if [ $? -eq 0 ]; then
        # فعال‌سازی در کانفیگ
        if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
        echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$PANEL_ENV"
        echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$PANEL_ENV"

        restart_service "panel"
        echo -e "${GREEN}✔ Theme Updated & Restarted.${NC}"
        
        # پاکسازی فایل‌های موقت
        rm -f "/tmp/index_old.html" "/tmp/index_dl.html"
    else
        echo -e "${RED}✘ Script Failed.${NC}"
    fi
    
    pause
}

# ==========================================
# 2. ACTIVATE THEME
# ==========================================
activate_theme() {
    echo -e "${BLUE}Activating Theme...${NC}"
    local T_FILE="/var/lib/pasarguard/templates/subscription/index.html"
    
    if [ ! -s "$T_FILE" ]; then
        echo -e "${RED}Theme file missing. Install first.${NC}"
        pause; return
    fi

    if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi
    sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
    sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
    echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$PANEL_ENV"
    echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$PANEL_ENV"

    restart_service "panel"
    echo -e "${GREEN}✔ Theme Activated.${NC}"
    pause
}

# ==========================================
# 3. DEACTIVATE THEME
# ==========================================
deactivate_theme() {
    echo -e "${YELLOW}Deactivating Theme...${NC}"
    if [ -f "$PANEL_ENV" ]; then
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
        restart_service "panel"
        echo -e "${GREEN}✔ Theme Deactivated.${NC}"
    fi
    pause
}

# ==========================================
# 4. UNINSTALL THEME
# ==========================================
uninstall_theme() {
    echo -e "${RED}--- Uninstall Theme ---${NC}"
    read -p "Delete files? (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        rm -rf "/var/lib/pasarguard/templates/subscription"
        deactivate_theme
        echo -e "${GREEN}✔ Files removed.${NC}"
    fi
    pause
}

# === MENU ===
theme_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      THEME MANAGER  v 1.0                        ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Install / Update Theme (Wizard)"
        echo "2) Activate Theme"
        echo "3) Deactivate Theme"
        echo "4) Uninstall Theme"
        echo "5) Back"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) install_theme_wizard ;;
            2) activate_theme ;;
            3) deactivate_theme ;;
            4) uninstall_theme ;;
            5) return ;;
            *) ;;
        esac
    done
}