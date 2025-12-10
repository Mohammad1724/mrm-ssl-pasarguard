#!/bin/bash

# Load Modules
source /opt/mrm-manager/utils.sh
source /opt/mrm-manager/ui.sh
source /opt/mrm-manager/ssl.sh
source /opt/mrm-manager/node.sh
source /opt/mrm-manager/theme.sh
source /opt/mrm-manager/site.sh
source /opt/mrm-manager/inbound.sh
source /opt/mrm-manager/backup.sh
source /opt/mrm-manager/domain_separator.sh
source /opt/mrm-manager/port_manager.sh
source /opt/mrm-manager/migrator.sh

# --- HELPER FUNCTIONS ---
edit_file() {
    if [ -f "$1" ]; then 
        nano "$1"
    else 
        echo -e "${RED}File not found: $1${NC}"
        pause
    fi
}

# --- TOOLS MENU ---
tools_menu() {
    while true; do
        clear
        ui_header "TOOLS & SETTINGS"
        echo "1) Fake Site / Camouflage (Nginx)"
        echo "2) Domain Separator (Panel & Sub)"
        echo "3) Port Manager (Single/Dual Port)"
        echo "4) Theme Manager (Subscription Page)"
        echo "5) Inbound Wizard (Create Config)"
        echo "6) Migration Tools (Pasarguard -> Rebeka)"
        echo "7) Edit Panel Config (.env)"
        echo "8) Edit Node Config (.env)"
        echo "9) Restart Panel Service"
        echo "10) Restart Node Service"
        echo "11) Show Node SSL Paths"
        echo "0) Back"
        echo ""
        read -p "Select: " T_OPT
        case $T_OPT in
            1) site_menu ;;
            2) domain_menu ;;
            3) port_menu ;;
            4) theme_menu ;;
            5) inbound_menu ;;
            6) migrator_menu ;;
            7) edit_file "$PANEL_ENV" ;;
            8) edit_file "$NODE_ENV" ;;
            9) restart_service "panel"; pause ;;
            10) restart_service "node"; pause ;;
            11) show_node_ssl ;;
            0) return ;;
            *) ;;
        esac
    done
}

# --- MAIN LOOP ---
check_root
install_deps

while true; do
    clear
    ui_header "MRM PASARGUARD MANAGER v3.3"
    ui_status_bar
    
    echo "  1) SSL Certificates"
    echo "  2) Backup & Restore"
    echo "  3) Tools & Settings"
    echo ""
    echo "  0) Exit"
    echo ""
    read -p "Select: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) backup_menu ;;
        3) tools_menu ;;
        0) exit 0 ;;
        *) ;;
    esac
done