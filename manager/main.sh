#!/bin/bash

# Load Modules
source /opt/mrm-manager/utils.sh
source /opt/mrm-manager/ssl.sh
source /opt/mrm-manager/node.sh
source /opt/mrm-manager/theme.sh

# Main Loop
check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}     MRM MANAGER v5.3 (Full Modular)       ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo "1) SSL Certificates Menu"
    echo "2) Theme Manager"
    echo "3) Settings & Node Connector"
    echo "4) Exit"
    echo -e "${BLUE}===========================================${NC}"
    read -p "Select: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) theme_menu ;;
        3) settings_menu ;;
        4) exit 0 ;;
        *) ;;
    esac
done