#!/bin/bash

# ============================================
# INBOUND MANAGER - Main Menu
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
        ui_header "INBOUND MANAGER" 55

        echo -e "${UI_YELLOW}── Quick Presets ──${UI_NC}"
        echo "  1) ⚡ Quick Reality Setup"
        echo "  2) 🌐 Quick CDN Setup"
        echo ""
        echo -e "${UI_YELLOW}── Advanced ──${UI_NC}"
        echo "  3) 🔧 Create Custom Inbound"
        echo ""
        echo -e "${UI_YELLOW}── Manage ──${UI_NC}"
        echo "  4) 📋 List Inbounds"
        echo "  5) 🔍 View Details"
        echo "  6) ✏️  Edit Inbound"
        echo "  7) 📑 Clone Inbound"
        echo "  8) 🗑️  Delete Inbound"
        echo ""
        echo -e "${UI_YELLOW}── Tools ──${UI_NC}"
        echo "  9) 🔗 Generate Share Link"
        echo " 10) 📤 Export Inbound"
        echo " 11) 📥 Import Inbound"
        echo " 12) 💾 Backup All"
        echo " 13) ♻️  Restore Backup"
        echo ""
        echo "  0) ↩️  Back"
        echo ""

        read -p "Select: " OPT

        case $OPT in
            1) quick_reality_preset ;;
            2) quick_cdn_preset ;;
            3) create_advanced_inbound ;;
            4) list_inbounds ;;
            5) view_inbound_details ;;
            6) edit_inbound ;;
            7) clone_inbound ;;
            8) delete_inbound ;;
            9) generate_share_link ;;
            10) export_inbound ;;
            11) import_inbound ;;
            12) backup_all_inbounds ;;
            13) restore_inbounds ;;
            0) return ;;
            *) ;;
        esac
    done
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    inbound_menu
fi
