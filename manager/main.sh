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
source /opt/mrm-manager/nodelink.sh
source /opt/mrm-manager/cloudflare.sh

# --- UPDATE FUNCTION ---
update_script() {
    echo -e "${BLUE}Updating MRM Manager...${NC}"
    local INSTALL_DIR="/opt/mrm-manager"
    local REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/manager"

    curl -s -o "$INSTALL_DIR/utils.sh" "$REPO_URL/utils.sh"
    curl -s -o "$INSTALL_DIR/ssl.sh" "$REPO_URL/ssl.sh"
    curl -s -o "$INSTALL_DIR/node.sh" "$REPO_URL/node.sh"
    curl -s -o "$INSTALL_DIR/theme.sh" "$REPO_URL/theme.sh"
    curl -s -o "$INSTALL_DIR/site.sh" "$REPO_URL/site.sh"
    curl -s -o "$INSTALL_DIR/inbound.sh" "$REPO_URL/inbound.sh"
    curl -s -o "$INSTALL_DIR/backup.sh" "$REPO_URL/backup.sh"
    curl -s -o "$INSTALL_DIR/monitor.sh" "$REPO_URL/monitor.sh"
    curl -s -o "$INSTALL_DIR/nodelink.sh" "$REPO_URL/nodelink.sh"
    curl -s -o "$INSTALL_DIR/cloudflare.sh" "$REPO_URL/cloudflare.sh"
    curl -s -o "$INSTALL_DIR/main.sh" "$REPO_URL/main.sh"

    chmod +x "$INSTALL_DIR/"*.sh
    echo -e "${GREEN}✔ Updated! Reloading...${NC}"
    sleep 1
    exec bash "$INSTALL_DIR/main.sh"
}

# --- TOOLS MENU (Sub-menu) ---
tools_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      TOOLS & UTILITIES                    ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Fake Site / Camouflage (Nginx)"
        echo "2) Cloudflare DNS Manager"
        echo "3) Theme Manager (Subscription Page)"
        echo "4) Inbound Wizard"
        echo "5) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) site_menu ;;
            2) cloudflare_menu ;;
            3) theme_menu ;;
            4) inbound_menu ;;
            5) return ;;
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
    echo -e "${YELLOW}     MRM PASARGUARD MANAGER v3.0           ${NC}"
    echo -e "${CYAN}===========================================${NC}"
    echo ""
    echo "  1) SSL Certificates"
    echo "  2) Node Management"
    echo "  3) Backup & Restore"
    echo "  4) Monitoring"
    echo "  5) Tools"
    echo "  6) Update Script"
    echo ""
    echo "  0) Exit"
    echo ""
    echo -e "${CYAN}===========================================${NC}"
    read -p "Select: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) 
            while true; do
                clear
                echo -e "${BLUE}===========================================${NC}"
                echo -e "${YELLOW}      NODE MANAGEMENT                      ${NC}"
                echo -e "${BLUE}===========================================${NC}"
                echo "1) Panel & Node Configuration"
                echo "2) Node Connection (Token/Install)"
                echo "3) Back"
                echo -e "${BLUE}===========================================${NC}"
                read -p "Select: " N_OPT
                case $N_OPT in
                    1) settings_menu ;;
                    2) nodelink_menu ;;
                    3) break ;;
                    *) ;;
                esac
            done
            ;;
        3) backup_menu ;;
        4) monitor_menu ;;
        5) tools_menu ;;
        6) update_script ;;
        0) exit 0 ;;
        *) ;;
    esac
done