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
source /opt/mrm-manager/cloudflare.sh  # New

# --- UPDATE FUNCTIONS ---
update_script() {
    echo -e "${BLUE}Updating MRM Manager Scripts...${NC}"
    local INSTALL_DIR="/opt/mrm-manager"
    local REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/manager"

    # Download all
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

update_panel() {
    echo -e "${BLUE}Updating Pasarguard Core...${NC}"
    if [ -d "$PANEL_DIR" ]; then
        cd "$PANEL_DIR"
        docker compose pull
        docker compose up -d
        echo -e "${GREEN}✔ Panel Updated.${NC}"
    else
        echo -e "${RED}Panel directory not found.${NC}"
    fi
    pause
}

update_node() {
    echo -e "${PURPLE}Updating Node Service...${NC}"
    if [ -d "$NODE_DIR" ]; then
        cd "$NODE_DIR"
        docker compose pull
        docker compose up -d
        echo -e "${GREEN}✔ Node Updated.${NC}"
    else
        echo -e "${RED}Node directory not found.${NC}"
    fi
    pause
}

# --- MAIN LOOP ---
check_root
install_deps
check_installation

while true; do
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}     MRM PASARGUARD MANAGER v2.5              ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo "1) SSL Certificates Menu"
    echo "2) Panel & Node Configuration"
    echo "3) Theme Manager"
    echo "4) Fake Site / Camouflage"
    echo "5) Inbound Wizard"
    echo "6) Backup & Restore"
    echo "7) Monitoring & Status"
    echo "8) Node Connection"
    echo "9) Cloudflare Manager"
    echo "10) Update Center"
    echo "11) Exit"
    echo -e "${BLUE}===========================================${NC}"
    read -p "Select: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) settings_menu ;;
        3) theme_menu ;;
        4) site_menu ;;
        5) inbound_menu ;;
        6) backup_menu ;;
        7) monitor_menu ;;
        8) nodelink_menu ;;
        9) cloudflare_menu ;;
        10) 
            echo -e "\n${CYAN}--- Update Center ---${NC}"
            echo "1) Update Manager Script"
            echo "2) Update Panel Core"
            echo "3) Update Node"
            echo "4) Back"
            read -p "Select: " U_OPT
            case $U_OPT in
                1) update_script ;;
                2) update_panel ;;
                3) update_node ;;
                *) ;;
            esac
            ;;
        11) exit 0 ;;
        *) ;;
    esac
done