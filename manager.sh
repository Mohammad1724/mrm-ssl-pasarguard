#!/bin/bash
CONFIG_FILE="/var/lib/pasarguard/templates/subscription/theme_config.js"
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}Error: Install theme first.${NC}"; exit 1; fi

update() { sed -i "s|$1: \".*\"|$1: \"$2\"|g" "$CONFIG_FILE"; echo -e "${GREEN}Updated!${NC}"; sleep 1; }

while true; do
    clear
    echo -e "${CYAN}=== FarsNetVIP Manager ===${NC}"
    echo "1) Edit Brand Name"
    echo "2) Edit News Ticker"
    echo "3) Edit Bot Username"
    echo "4) Edit Support ID"
    echo "5) Edit Android Link"
    echo "6) Edit iOS Link"
    echo "7) Edit Windows Link"
    echo "8) Edit Tutorial (Step 1)"
    echo "9) Edit Tutorial (Step 2)"
    echo "10) Edit Tutorial (Step 3)"
    echo "0) Exit"
    read -p "Select: " OPT
    
    case $OPT in
        1) read -p "New Brand: " V; update "brandName" "$V" ;;
        2) read -p "New News: " V; update "newsText" "$V" ;;
        3) read -p "New Bot (no @): " V; update "botUsername" "$V" ;;
        4) read -p "New Support (no @): " V; update "supportID" "$V" ;;
        5) read -p "New Android URL: " V; update "androidUrl" "$V" ;;
        6) read -p "New iOS URL: " V; update "iosUrl" "$V" ;;
        7) read -p "New Win URL: " V; update "winUrl" "$V" ;;
        8) read -p "Step 1: " V; update "tut1" "$V" ;;
        9) read -p "Step 2: " V; update "tut2" "$V" ;;
        10) read -p "Step 3: " V; update "tut3" "$V" ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid${NC}"; sleep 1 ;;
    esac
done