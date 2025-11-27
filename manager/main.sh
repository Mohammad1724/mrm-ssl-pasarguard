#!/bin/bash

# لود کردن ماژول‌ها
source /opt/mrm-manager/utils.sh
source /opt/mrm-manager/ssl.sh
source /opt/mrm-manager/node.sh

install_theme_wrapper() {
    echo -e "${BLUE}Downloading Theme Script...${NC}"
    bash <(curl -s "$THEME_SCRIPT_URL")
    pause
}

# Main Loop
check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}     MRM MANAGER v5.2 (Modular)            ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo "1) SSL Certificates Menu"
    echo "2) Theme Manager"
    echo "3) Settings & Node Connector"
    echo "4) Exit"
    echo -e "${BLUE}===========================================${NC}"
    read -p "Select: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) install_theme_wrapper ;;
        3) settings_menu ;;
        4) exit 0 ;;
        *) ;;
    esac
done