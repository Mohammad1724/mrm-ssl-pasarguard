#!/bin/bash
source /opt/mrm-manager/utils.sh

connect_node_wizard() {
    # ... (کد ویزارد اتصال نود که در نسخه ۵ دادم اینجا قرار می‌گیرد) ...
    # فقط دقت کنید متغیرها را از utils.sh می‌خواند
}

edit_file() {
    if [ -f "$1" ]; then nano "$1"; else echo -e "${RED}File not found: $1${NC}"; pause; fi
}

settings_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      SETTINGS & NODE                      ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Connect Node to Core (Wizard)"
        echo "2) Edit Panel Config"
        echo "3) Edit Node Config"
        echo "4) Restart Panel"
        echo "5) Restart Node"
        echo "6) Back"
        read -p "Select: " P_OPT
        case $P_OPT in
            1) connect_node_wizard ;;
            2) edit_file "$PANEL_ENV" ;;
            3) edit_file "$NODE_ENV" ;;
            4) pasarguard restart; pause ;;
            5) cd "$NODE_DIR" && docker compose restart; pause ;;
            6) return ;;
        esac
    done
}