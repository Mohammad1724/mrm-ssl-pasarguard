#!/bin/bash

# ============================================
# MRM MANAGER - MAIN ENTRY POINT v2.0
# ============================================

# Define Paths
BASE_DIR="/opt/mrm-manager"

# 1. Load Libraries with Error Handling
if [ -f "$BASE_DIR/utils.sh" ]; then
    source "$BASE_DIR/utils.sh"
else
    echo "Error: utils.sh not found in $BASE_DIR"
    exit 1
fi

if [ -f "$BASE_DIR/ui.sh" ]; then
    source "$BASE_DIR/ui.sh"
else
    echo "Error: ui.sh not found. Running in text mode."
    # Fallback dummy functions if UI missing
    ui_header() { echo "--- $1 ---"; }
    ui_menu() { echo "UI Error"; exit 1; }
fi

# ============================================
# INITIALIZATION
# ============================================

# Setup Trap for cleanup (Cursor fix)
trap 'tput cnorm; exit 0' INT TERM

# Check Root
check_root

# Show Loading Screen
clear
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      MRM MANAGER INITIALIZING...       ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Please wait while we check dependencies...${NC}"
echo -e "${DIM}(This may take a minute on first run)${NC}"

# Install Dependencies (Verbose enough to see progress if stuck)
install_deps

# Detect Panel
PANEL=$(detect_active_panel)

# ============================================
# SUB-MENUS
# ============================================

menu_tools() {
    while true; do
        # Using simple select for sub-menus to avoid complexity
        clear
        ui_header "TOOLS & UTILITIES"
        echo " 1) Fake Site (Nginx Camouflage)"
        echo " 2) Domain Separator (Admin/Sub)"
        echo " 3) Port Manager (Single/Dual)"
        echo " 4) Inbound Wizard"
        echo " 5) Migration Tools (Auto)"
        echo " 6) Theme Manager"
        echo " 7) Edit Panel .env"
        echo " 8) Edit Node .env"
        echo " 9) Restart Services"
        echo " 0) Back"
        echo ""
        read -p "Select: " T_OPT
        case $T_OPT in
            1) source "$BASE_DIR/site.sh"; site_menu ;;
            2) source "$BASE_DIR/domain_separator.sh"; domain_menu ;;
            3) source "$BASE_DIR/port_manager.sh"; port_menu ;;
            4) source "$BASE_DIR/inbound.sh"; inbound_menu ;;
            5) source "$BASE_DIR/migrator.sh"; migrator_menu ;;
            6) source "$BASE_DIR/theme.sh"; theme_menu ;;
            7) nano "$PANEL_ENV" ;;
            8) nano "$NODE_ENV" ;;
            9) 
                echo "1) Restart Panel"
                echo "2) Restart Node"
                read -p "Select: " R_OPT
                [ "$R_OPT" == "1" ] && restart_service "panel"
                [ "$R_OPT" == "2" ] && restart_service "node"
                pause 
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

menu_control() {
    while true; do
        clear
        ui_header "ADMIN CONTROLS ($PANEL_NAME)"
        echo " 1) Create Admin (Sudo/Regular)"
        echo " 2) Reset Admin Password"
        echo " 3) Delete Admin"
        echo " 4) View Panel Logs"
        echo " 0) Back"
        echo ""
        read -p "Select: " C_OPT
        case $C_OPT in
            1) admin_create; pause ;;
            2) admin_reset; pause ;;
            3) admin_delete; pause ;;
            4) cd "$PANEL_DIR" && docker compose logs -f --tail 100; pause ;;
            0) return ;;
        esac
    done
}

# ============================================
# MAIN LOOP
# ============================================

while true; do
    clear
    ui_header "MRM MANAGER v2.1"
    ui_status_bar
    
    echo -e " ${CYAN}1)${NC} SSL Certificates"
    echo -e " ${CYAN}2)${NC} Backup & Restore"
    echo -e " ${CYAN}3)${NC} Tools & Settings"
    echo -e " ${CYAN}4)${NC} Admin & Logs"
    echo -e " ${RED}0) Exit${NC}"
    echo ""
    read -p "Select Option: " OPTION

    case $OPTION in
        1) source "$BASE_DIR/ssl.sh"; ssl_menu ;;
        2) source "$BASE_DIR/backup.sh"; backup_menu ;;
        3) menu_tools ;;
        4) menu_control ;;
        0) clear; echo "Good bye!"; exit 0 ;;
        *) ;;
    esac
done