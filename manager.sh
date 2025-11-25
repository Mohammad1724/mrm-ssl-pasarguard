#!/bin/bash

# ==========================================
# FarsNetVIP Theme Manager
# Use this to edit theme settings instantly!
# ==========================================

CONFIG_FILE="/var/lib/pasarguard/templates/subscription/theme_config.js"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found! Please install the theme first.${NC}"
    exit 1
fi

update_config() {
    KEY=$1
    VALUE=$2
    # Using sed to replace value inside the JS file securely
    sed -i "s|$KEY: \".*\"|$KEY: \"$VALUE\"|g" "$CONFIG_FILE"
}

while true; do
    clear
    echo -e "${CYAN}====================================${NC}"
    echo -e "${YELLOW}    FarsNetVIP Theme Manager       ${NC}"
    echo -e "${CYAN}====================================${NC}"
    echo "1) Edit Brand Name"
    echo "2) Edit Bot Username"
    echo "3) Edit Support ID"
    echo "4) Edit Android Link"
    echo "5) Edit iOS Link"
    echo "6) Edit Windows Link"
    echo "7) Edit Tutorial Text (Step 1)"
    echo "8) Edit Tutorial Text (Step 2)"
    echo "9) Edit Tutorial Text (Step 3)"
    echo "0) Exit"
    echo -e "${CYAN}====================================${NC}"
    read -p "Select Option: " OPT

    case $OPT in
        1)
            read -p "Enter New Brand Name: " VAL
            update_config "brandName" "$VAL"
            ;;
        2)
            read -p "Enter New Bot Username (no @): " VAL
            update_config "botUsername" "$VAL"
            ;;
        3)
            read -p "Enter New Support ID (no @): " VAL
            update_config "supportID" "$VAL"
            ;;
        4)
            read -p "Enter New Android URL: " VAL
            update_config "androidUrl" "$VAL"
            ;;
        5)
            read -p "Enter New iOS URL: " VAL
            update_config "iosUrl" "$VAL"
            ;;
        6)
            read -p "Enter New Windows URL: " VAL
            update_config "winUrl" "$VAL"
            ;;
        7)
            read -p "Enter Tutorial Step 1: " VAL
            update_config "tut1" "$VAL"
            ;;
        8)
            read -p "Enter Tutorial Step 2: " VAL
            update_config "tut2" "$VAL"
            ;;
        9)
            read -p "Enter Tutorial Step 3: " VAL
            update_config "tut3" "$VAL"
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
    
    if [ "$OPT" != "0" ]; then
        echo -e "${GREEN}✔ Updated Successfully!${NC}"
        sleep 1
    fi
done