#!/bin/bash

# Load Modules
source /opt/mrm-manager/utils.sh
source /opt/mrm-manager/ssl.sh
source /opt/mrm-manager/node.sh
source /opt/mrm-manager/theme.sh
source /opt/mrm-manager/site.sh
source /opt/mrm-manager/inbound.sh
source /opt/mrm-manager/backup.sh
source /opt/mrm-manager/monitor.sh
source /opt/mrm-manager/domain_separator.sh
source /opt/mrm-manager/port_manager.sh # NEW MODULE

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
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      TOOLS                                ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Fake Site / Camouflage (Nginx)"
        echo "2) Domain Separator (Panel & Sub)"
        echo "3) Port Manager (Single/Dual Port) [Advanced]" # NEW OPTION
        echo "4) Theme Manager (Subscription Page)"
        echo "5) Inbound Wizard (Create Config)"
        echo "6) Edit Panel Config (.env)"
        echo "7) Edit Node Config (.env)"
        echo "8) Restart Panel Service"
        echo "9) Restart Node Service"
        echo "10) Show Node SSL Paths"
        echo "11) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) site_menu ;;
            2) domain_menu ;;
            3) port_menu ;; # Calls the new module
            4) theme_menu ;;
            5) inbound_menu ;;
            6) edit_file "$PANEL_ENV" ;;
            7) edit_file "$NODE_ENV" ;;
            8) restart_service "panel"; pause ;;
            9) restart_service "node"; pause ;;
            10) show_node_ssl ;;
            11) return ;;
            *) ;;
        esac
    done
}

# --- MAIN LOOP ---
check_root
install_deps

while true; do
    clear
    echo -e "${CYAN}===========================================${NC}"
    echo -e "${YELLOW}     MRM PASARGUARD MANAGER v3.2           ${NC}"
    echo -e "${CYAN}===========================================${NC}"
    echo ""
    echo "  1) SSL Certificates"
    echo "  2) Backup & Restore"
    echo "  3) Monitoring & Status"
    echo "  4) Tools & Settings"
    echo ""
    echo "  0) Exit"
    echo ""
    echo -e "${CYAN}===========================================${NC}"
    read -p "Select: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) backup_menu ;;
        3) monitor_menu ;;
        4) tools_menu ;;
        0) exit 0 ;;
        *) ;;
    esac
done