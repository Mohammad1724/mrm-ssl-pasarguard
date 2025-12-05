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
source /opt/mrm-manager/domain_separator.sh # NEW

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
        echo "2) Domain Separator (Panel & Sub)" # NEW
        echo "3) Theme Manager (Subscription Page)"
        echo "4) Inbound Wizard (Create Config)"
        echo "5) Edit Panel Config (.env)"
        echo "6) Edit Node Config (.env)"
        echo "7) Restart Panel Service"
        echo "8) Restart Node Service"
        echo "9) Show Node SSL Paths"
        echo "10) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) site_menu ;;
            2) domain_menu ;; # Calls the new module
            3) theme_menu ;;
            4) inbound_menu ;;
            5) edit_file "$PANEL_ENV" ;;
            6) edit_file "$NODE_ENV" ;;
            7) restart_service "panel"; pause ;;
            8) restart_service "node"; pause ;;
            9) show_node_ssl ;;
            10) return ;;
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
    echo -e "${YELLOW}     MRM PASARGUARD MANAGER v3.1           ${NC}"
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