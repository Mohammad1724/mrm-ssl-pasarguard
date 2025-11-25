#!/bin/bash

# ==========================================
# FarsNetVIP Theme Manager (Direct HTML Edit)
# ==========================================

# Target File (Now editing index.html directly to avoid 404 errors)
TARGET_FILE="/var/lib/pasarguard/templates/subscription/index.html"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Check if theme is installed
if [ ! -f "$TARGET_FILE" ]; then
    echo -e "${RED}Error: Theme not found! Please run theme.sh first.${NC}"
    exit 1
fi

# --- FUNCTIONS ---

# Get current value from JS object inside HTML
get_current_val() {
    # Grep finds the line, Sed extracts content between quotes
    grep "$1:" "$TARGET_FILE" | sed -n 's/.*: "\(.*\)",/\1/p'
}

# Update value in HTML
update_config() {
    KEY=$1
    NEW_VAL=$2
    
    # We use | as delimiter for sed to allow slashes / in URLs
    # This regex looks for:  key: "anything",   and replaces it
    sed -i "s|$KEY: \".*\"|$KEY: \"$NEW_VAL\"|g" "$TARGET_FILE"
    
    echo -e "${GREEN}✔ Updated Successfully!${NC}"
    sleep 1
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
    
    echo -e "\n${BLUE}--- Tutorial ---${NC}"
    echo "8) Edit Step 1 Text"
    echo "9) Edit Step 2 Text"
    echo "10) Edit Step 3 Text"
    
    echo -e "\n${RED}0) Exit${NC}"
    echo -e "${CYAN}========================================${NC}"
    read -p "Select Option: " OPT

    case $OPT in
        1)
            CUR=$(get_current_val "brandName")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Brand Name: " VAL
            if [ ! -z "$VAL" ]; then update_config "brandName" "$VAL"; fi
            ;;
        2)
            CUR=$(get_current_val "newsText")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New News Text: " VAL
            if [ ! -z "$VAL" ]; then update_config "newsText" "$VAL"; fi
            ;;
        3)
            CUR=$(get_current_val "botUsername")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Bot User (no @): " VAL
            if [ ! -z "$VAL" ]; then update_config "botUsername" "$VAL"; fi
            ;;
        4)
            CUR=$(get_current_val "supportID")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Support ID (no @): " VAL
            if [ ! -z "$VAL" ]; then update_config "supportID" "$VAL"; fi
            ;;
        5)
            CUR=$(get_current_val "androidUrl")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Android URL: " VAL
            if [ ! -z "$VAL" ]; then update_config "androidUrl" "$VAL"; fi
            ;;
        6)
            CUR=$(get_current_val "iosUrl")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New iOS URL: " VAL
            if [ ! -z "$VAL" ]; then update_config "iosUrl" "$VAL"; fi
            ;;
        7)
            CUR=$(get_current_val "winUrl")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Windows URL: " VAL
            if [ ! -z "$VAL" ]; then update_config "winUrl" "$VAL"; fi
            ;;
        8)
            CUR=$(get_current_val "tut1")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Step 1: " VAL
            if [ ! -z "$VAL" ]; then update_config "tut1" "$VAL"; fi
            ;;
        9)
            CUR=$(get_current_val "tut2")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Step 2: " VAL
            if [ ! -z "$VAL" ]; then update_config "tut2" "$VAL"; fi
            ;;
        10)
            CUR=$(get_current_val "tut3")
            echo -e "Current: ${YELLOW}$CUR${NC}"
            read -p "New Step 3: " VAL
            if [ ! -z "$VAL" ]; then update_config "tut3" "$VAL"; fi
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