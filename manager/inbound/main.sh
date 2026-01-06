#!/bin/bash

# ============================================
# INBOUND MANAGER - Main Menu
# Version: 2.1 (Clean UI)
# ============================================

INBOUND_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Load parent utils if not loaded
if [ -z "$PANEL_DIR" ]; then
    source /opt/mrm-manager/utils.sh
    source /opt/mrm-manager/ui.sh
fi

# Load inbound modules
source "$INBOUND_DIR/lib.sh"
source "$INBOUND_DIR/create.sh"
source "$INBOUND_DIR/manage.sh"
source "$INBOUND_DIR/tools.sh"

# ============================================
# MAIN MENU
# ============================================
inbound_menu() {
    while true; do
        clear
        echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}INBOUND MANAGER${UI_NC}                     ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}╠══════════════════════════════════════════════╣${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   1) ➕ Create Inbound                       ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   2) 📋 List & Manage                        ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   3) 🔗 Generate Share Link                  ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   4) 💾 Backup / Restore                     ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   0) ↩️  Back                                 ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) create_menu ;;
            2) manage_menu ;;
            3) generate_share_link ;;
            4) backup_menu_inbound ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ============================================
# CREATE SUBMENU
# ============================================
create_menu() {
    while true; do
        clear
        echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}CREATE INBOUND${UI_NC}                      ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}╠══════════════════════════════════════════════╣${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   ${UI_GREEN}── Quick Presets ──${UI_NC}                       ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   1) ⚡ Reality (Recommended)                ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   2) 🌐 CDN (WebSocket/HTTPUpgrade)          ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   ${UI_GREEN}── Advanced ──${UI_NC}                            ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   3) 🔧 Custom (All Options)                 ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   0) ↩️  Back                                 ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) quick_reality_preset ;;
            2) quick_cdn_preset ;;
            3) create_advanced_inbound ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ============================================
# MANAGE SUBMENU
# ============================================
manage_menu() {
    while true; do
        clear
        echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}MANAGE INBOUNDS${UI_NC}                     ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}╠══════════════════════════════════════════════╣${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   1) 📋 List All                             ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   2) 🔍 View Details                         ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   3) ✏️  Edit                                 ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   4) 📑 Clone                                ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   5) 🗑️  Delete                               ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   0) ↩️  Back                                 ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) list_inbounds ;;
            2) view_inbound_details ;;
            3) edit_inbound ;;
            4) clone_inbound ;;
            5) delete_inbound ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ============================================
# BACKUP SUBMENU
# ============================================
backup_menu_inbound() {
    while true; do
        clear
        echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}BACKUP / RESTORE${UI_NC}                    ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}╠══════════════════════════════════════════════╣${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   1) 💾 Backup All Inbounds                  ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   2) ♻️  Restore from Backup                  ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   3) 📤 Export Single Inbound                ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   4) 📥 Import Inbound                       ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}   0) ↩️  Back                                 ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
        echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) backup_all_inbounds ;;
            2) restore_inbounds ;;
            3) export_inbound ;;
            4) import_inbound ;;
            0) return ;;
            *) ;;
        esac
    done
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    inbound_menu
fi