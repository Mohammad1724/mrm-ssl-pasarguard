#!/bin/bash

# ==========================================
# FarsNetVIP Theme Manager (for new Glass UI)
# ==========================================

TARGET_FILE="/var/lib/pasarguard/templates/subscription/index.html"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# ---- Safety: root check ----
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

# Check if theme is installed
if [ ! -f "$TARGET_FILE" ]; then
    echo -e "${RED}Error: Theme not found! Please run theme.sh first.${NC}"
    exit 1
fi

# ---- Helpers ----

sed_escape() {
    # Escape & / \ برای استفاده در sed
    printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'
}

# خواندن مقادیر فعلی از HTML

get_brand() {
    sed -n 's/.*id="brandTxt">\([^<]*\).*/\1/p' "$TARGET_FILE" | head -n1
}

get_news() {
    sed -n 's/.*id="newsTxt">\([^<]*\).*/\1/p' "$TARGET_FILE" | head -n1
}

get_bot_user() {
    # از href لینک با کلاس bot-badge
    sed -n '/class="bot-badge"/ s/.*href="https:\/\/t.me\/\([^"]*\)".*/\1/p' "$TARGET_FILE" | head -n1
}

get_support_user() {
    # از href لینکی که پشتیبانی است (دارای رنگ muted-fg)
    sed -n '/color:var(--muted-fg)/ s/.*href="https:\/\/t.me\/\([^"]*\)".*/\1/p' "$TARGET_FILE" | head -n1
}

get_android_url() {
    sed -n '/id="dlAnd"/ s/.*href="\([^"]*\)".*/\1/p' "$TARGET_FILE" | head -n1
}

get_ios_url() {
    sed -n '/id="dlIos"/ s/.*href="\([^"]*\)".*/\1/p' "$TARGET_FILE" | head -n1
}

get_win_url() {
    sed -n '/id="dlWin"/ s/.*href="\([^"]*\)".*/\1/p' "$TARGET_FILE" | head -n1
}

# آپدیت مقادیر

update_brand() {
    local NEW_VAL="$1"
    local ESC
    ESC=$(sed_escape "$NEW_VAL")
    sed -i "s|\(id=\"brandTxt\">\)[^<]*\(<\)|\1$ESC\2|" "$TARGET_FILE"
}

update_news() {
    local NEW_VAL="$1"
    local ESC
    ESC=$(sed_escape "$NEW_VAL")
    sed -i "s|\(id=\"newsTxt\">\)[^<]*\(<\)|\1$ESC\2|" "$TARGET_FILE"
}

update_bot_user() {
    local NEW_VAL="$1"
    local ESC
    ESC=$(sed_escape "$NEW_VAL")
    # href
    sed -i "/class=\"bot-badge\"/ s|\(href=\"https://t.me/\)[^\"]*|\1$ESC|" "$TARGET_FILE"
    # متن @username
    sed -i "/class=\"bot-badge\"/ s|@[^<]*|@$ESC|" "$TARGET_FILE"
}

update_support_user() {
    local NEW_VAL="$1"
    local ESC
    ESC=$(sed_escape "$NEW_VAL")
    sed -i "/color:var(--muted-fg)/ s|\(href=\"https://t.me/\)[^\"]*|\1$ESC|" "$TARGET_FILE"
}

update_android_url() {
    local NEW_VAL="$1"
    local ESC
    ESC=$(sed_escape "$NEW_VAL")
    sed -i "/id=\"dlAnd\"/ s|\(href=\"\)[^\"]*|\1$ESC|" "$TARGET_FILE"
}

update_ios_url() {
    local NEW_VAL="$1"
    local ESC
    ESC=$(sed_escape "$NEW_VAL")
    sed -i "/id=\"dlIos\"/ s|\(href=\"\)[^\"]*|\1$ESC|" "$TARGET_FILE"
}

update_win_url() {
    local NEW_VAL="$1"
    local ESC
    ESC=$(sed_escape "$NEW_VAL")
    sed -i "/id=\"dlWin\"/ s|\(href=\"\)[^\"]*|\1$ESC|" "$TARGET_FILE"
}

# --- MENU ---

while true; do
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${YELLOW}      FarsNetVIP Theme Manager          ${NC}"
    echo -e "${CYAN}========================================${NC}"

    echo -e "${BLUE}--- General ---${NC}"
    echo "1) Edit Brand Name"
    echo "2) Edit News Ticker"

    echo -e "\n${BLUE}--- Contact ---${NC}"
    echo "3) Edit Bot Username"
    echo "4) Edit Support ID"

    echo -e "\n${BLUE}--- App Links ---${NC}"
    echo "5) Edit Android URL"
    echo "6) Edit iOS URL"
    echo "7) Edit Windows URL"

    echo -e "\n${RED}0) Exit${NC}"
    echo -e "${CYAN}========================================${NC}"
    read -p "Select Option: " OPT

    case $OPT in
        1)
            CUR=$(get_brand)
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Brand Name: " VAL
            if [ -n "$VAL" ]; then
                update_brand "$VAL"
                echo -e "${GREEN}✔ Updated Successfully!${NC}"
                sleep 1
            fi
            ;;
        2)
            CUR=$(get_news)
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New News Text: " VAL
            if [ -n "$VAL" ]; then
                update_news "$VAL"
                echo -e "${GREEN}✔ Updated Successfully!${NC}"
                sleep 1
            fi
            ;;
        3)
            CUR=$(get_bot_user)
            echo -e "Current Bot Username: ${YELLOW}$CUR${NC}"
            read -p "New Bot User (no @): " VAL
            if [ -n "$VAL" ]; then
                update_bot_user "$VAL"
                echo -e "${GREEN}✔ Updated Successfully!${NC}"
                sleep 1
            fi
            ;;
        4)
            CUR=$(get_support_user)
            echo -e "Current Support ID: ${YELLOW}$CUR${NC}"
            read -p "New Support ID (no @): " VAL
            if [ -n "$VAL" ]; then
                update_support_user "$VAL"
                echo -e "${GREEN}✔ Updated Successfully!${NC}"
                sleep 1
            fi
            ;;
        5)
            CUR=$(get_android_url)
            echo -e "Current Android URL: ${YELLOW}$CUR${NC}"
            read -p "New Android URL: " VAL
            if [ -n "$VAL" ]; then
                update_android_url "$VAL"
                echo -e "${GREEN}✔ Updated Successfully!${NC}"
                sleep 1
            fi
            ;;
        6)
            CUR=$(get_ios_url)
            echo -e "Current iOS URL: ${YELLOW}$CUR${NC}"
            read -p "New iOS URL: " VAL
            if [ -n "$VAL" ]; then
                update_ios_url "$VAL"
                echo -e "${GREEN}✔ Updated Successfully!${NC}"
                sleep 1
            fi
            ;;
        7)
            CUR=$(get_win_url)
            echo -e "Current Windows URL: ${YELLOW}$CUR${NC}"
            read -p "New Windows URL: " VAL
            if [ -n "$VAL" ]; then
                update_win_url "$VAL"
                echo -e "${GREEN}✔ Updated Successfully!${NC}"
                sleep 1
            fi
            ;;
        0)
            echo -e "${GREEN}Exiting...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid Option${NC}"
            sleep 1
            ;;
    esac
done