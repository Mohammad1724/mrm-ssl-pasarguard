#!/bin/bash

# ==========================================
# FarsNetVIP Theme Manager (Full Control)
# Use this to edit theme settings instantly!
# ==========================================

CONFIG_FILE="/var/lib/pasarguard/templates/subscription/theme_config.js"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found! Please install the theme first.${NC}"
    exit 1
fi

# Function to extract current value
get_current_val() {
    grep "$1:" "$CONFIG_FILE" | sed -n 's/.*: "\(.*\)",/\1/p'
}

# Function to update value
update_config() {
    KEY=$1
    NEW_VAL=$2
    # Secure replacement using sed
    sed -i "s|$KEY: \".*\"|$KEY: \"$NEW_VAL\"|g" "$CONFIG_FILE"
    echo -e "${GREEN}✔ Updated Successfully!${NC}"
    sleep 1
}

while true; do
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${YELLOW}      FarsNetVIP Theme Manager          ${NC}"
    echo -e "${CYAN}========================================${NC}"
    
    echo -e "${BLUE}--- General Settings ---${NC}"
    echo "1) Edit Brand Name"
    echo "2) Edit News Ticker Text"
    
    echo -e "\n${BLUE}--- Telegram & Support ---${NC}"
    echo "3) Edit Bot Username"
    echo "4) Edit Support ID"
    
    echo -e "\n${BLUE}--- Download Links ---${NC}"
    echo "5) Edit Android Link"
    echo "6) Edit iOS Link"
    echo "7) Edit Windows Link"
    
    echo -e "\n${BLUE}--- Tutorial Text ---${NC}"
    echo "8) Edit Step 1"
    echo "9) Edit Step 2"
    echo "10) Edit Step 3"
    
    echo -e "\n${RED}0) Exit${NC}"
    echo -e "${CYAN}========================================${NC}"
    read -p "Select Option: " OPT

    case $OPT in
        1)
            CUR=$(get_current_val "brandName")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "Enter New Brand Name: " VAL
            update_config "brandName" "$VAL"
            ;;
        2)
            CUR=$(get_current_val "newsText")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "Enter New News Text: " VAL
            update_config "newsText" "$VAL"
            ;;
        3)
            CUR=$(get_current_val "botUsername")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "Enter New Bot Username (no @): " VAL
            update_config "botUsername" "$VAL"
            ;;
        4)
            CUR=$(get_current_val "supportID")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "Enter New Support ID (no @): " VAL
            update_config "supportID" "$VAL"
            ;;
        5)
            read -p "Enter New Android URL: " VAL
            update_config "androidUrl" "$VAL"
            ;;
        6)
            read -p "Enter New iOS URL: " VAL
            update_config "iosUrl" "$VAL"
            ;;
        7)
            read -p "Enter New Windows URL: " VAL
            update_config "winUrl" "$VAL"
            ;;
        8)
            CUR=$(get_current_val "tut1")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "Enter Tutorial Step 1: " VAL
            update_config "tut1" "$VAL"
            ;;
        9)
            CUR=$(get_current_val "tut2")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "Enter Tutorial Step 2: " VAL
            update_config "tut2" "$VAL"
            ;;
        10)
            CUR=$(get_current_val "tut3")
            echo -e "Current: ${YELLOW}$CUR${NC}"
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
done