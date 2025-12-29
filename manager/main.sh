#!/bin/bash

# Load Modules
source /opt/mrm-manager/utils.sh
source /opt/mrm-manager/ui.sh
source /opt/mrm-manager/ssl.sh
source /opt/mrm-manager/node.sh
source /opt/mrm-manager/theme.sh
source /opt/mrm-manager/site.sh
source /opt/mrm-manager/inbound.sh
source /opt/mrm-manager/domain_separator.sh
source /opt/mrm-manager/port_manager.sh
source /opt/mrm-manager/migrator.sh

# Detect panel on startup
detect_active_panel > /dev/null

# --- HELPER FUNCTIONS ---
edit_file() {
    if [ -f "$1" ]; then 
        nano "$1"
    else 
        echo -e "${RED}File not found: $1${NC}"
        pause
    fi
}

# =============================================
# NETWORK & BBR OPTIMIZATION (ULTRA SPEED)
# =============================================
optimize_network() {
    clear
    ui_header "NETWORK OPTIMIZATION"
    echo -e "${UI_YELLOW}Applying kernel tweaks and BBR speed boost...${UI_NC}\n"

    ui_spinner_start "Enabling Google BBR..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    ui_spinner_stop && ui_success "BBR Congestion Control Enabled"

    ui_spinner_start "Tuning TCP Stack for High-Traffic..."
    cat <<EOF > /etc/sysctl.d/99-mrm-speed.conf
fs.file-max = 1000000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65536
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl -p /etc/sysctl.d/99-mrm-speed.conf >/dev/null 2>&1
    sysctl --system >/dev/null 2>&1
    ui_spinner_stop && ui_success "TCP Performance Tuned"

    ui_spinner_start "Increasing OS System Limits..."
    if ! grep -q "* soft nofile 1000000" /etc/security/limits.conf; then
        echo "* soft nofile 1000000" >> /etc/security/limits.conf
        echo "* hard nofile 1000000" >> /etc/security/limits.conf
        echo "root soft nofile 1000000" >> /etc/security/limits.conf
        echo "root hard nofile 1000000" >> /etc/security/limits.conf
    fi
    ui_spinner_stop && ui_success "System Limits Increased"

    echo -e "\n${UI_GREEN}================================================${UI_NC}"
    echo -e "${UI_GREEN}   NETWORK SPEED OPTIMIZATION COMPLETE!${UI_NC}"
    echo -e "${UI_GREEN}================================================${UI_NC}"
    pause
}

# =============================================
# AUTO FIX AFTER SERVER MIGRATION
# =============================================
auto_fix_migration() {
    clear
    ui_header "AUTO FIX AFTER MIGRATION"
    echo -e "${UI_YELLOW}Diagnosing and fixing common server issues...${UI_NC}\n"

    ui_spinner_start "Configuring Firewall..."
    ufw allow 22,80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    for r in "192.0.0.0/8" "102.0.0.0/8" "198.0.0.0/8" "172.0.0.0/8"; do
        ufw delete deny from "$r" >/dev/null 2>&1 || true
        ufw delete deny out to "$r" >/dev/null 2>&1 || true
    done
    ui_spinner_stop && ui_success "Firewall Optimized"

    ui_spinner_start "Checking Node SSL Keys..."
    mkdir -p /var/lib/pg-node/certs 2>/dev/null
    if [ ! -f /var/lib/pg-node/certs/ssl_key.pem ]; then
        openssl genrsa -out /var/lib/pg-node/certs/ssl_key.pem 2048 >/dev/null 2>&1
        ui_success "Node SSL key generated"
    fi
    ui_spinner_stop

    ui_spinner_start "Repairing Configurations..."
    if [ -f "$PANEL_ENV" ]; then
        sed -i 's|\(postgresql+asyncpg://[^"?]*\)\(["\s]*\)$|\1?ssl=disable\2|' "$PANEL_ENV"
        sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$PANEL_ENV"
        sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$PANEL_ENV"
        ui_success ".env file repaired"
    fi
    ui_spinner_stop

    ui_spinner_start "Restarting Services..."
    restart_service "panel" >/dev/null 2>&1
    restart_service "node" >/dev/null 2>&1
    ui_spinner_stop && ui_success "Services Restarted"

    echo -e "\n${UI_GREEN}✔ AUTO-FIX COMPLETED!${NC}"
    pause
}

# --- CONTROL MENU ---
control_menu() {
    while true; do
        clear
        ui_header "ADMIN & CONTROL ($PANEL_DIR)"
        echo "1) Restart Panel"
        echo "2) Stop Panel"
        echo "3) Start Panel"
        echo "4) View Logs (Live)"
        echo "5) Create New Admin"
        echo "6) Reset Admin Password"
        echo "7) Delete Admin"
        echo "0) Back"
        echo ""
        read -p "Select: " C_OPT
        case $C_OPT in
            1) restart_service "panel"; pause ;;
            2) cd "$PANEL_DIR" && docker compose down; echo "Stopped."; pause ;;
            3) cd "$PANEL_DIR" && docker compose up -d; echo "Started."; pause ;;
            4) cd "$PANEL_DIR" && docker compose logs -f ;;
            5) admin_create; pause ;;
            6) admin_reset; pause ;;
            7) admin_delete; pause ;;
            0) return ;;
        esac
    done
}

# --- TOOLS MENU ---
tools_menu() {
    while true; do
        clear
        ui_header "TOOLS & SETTINGS"
        echo "1) Fake Site / Camouflage"
        echo "2) Domain Separator"
        echo "3) Port Manager"
        echo "4) Theme Manager"
        echo -e "5) ${UI_GREEN}${UI_BOLD}Auto Fix After Migration${UI_NC}"
        echo -e "6) ${UI_CYAN}${UI_BOLD}Optimize Network Speed (BBR)${UI_NC}"
        echo "7) Inbound Wizard"
        echo "8) Migration Tools"
        echo "9) Edit Panel Config (.env)"
        echo "10) Edit Node Config (.env)"
        echo "11) Restart Node Service"
        echo "0) Back"
        echo ""
        read -p "Select: " T_OPT
        case $T_OPT in
            1) site_menu ;;
            2) domain_menu ;;
            3) port_menu ;;
            4) theme_menu ;;
            5) auto_fix_migration ;;
            6) optimize_network ;;
            7) inbound_menu ;;
            8) migrator_menu ;;
            9) edit_file "$PANEL_ENV" ;;
            10) edit_file "$NODE_ENV" ;;
            11) restart_service "node"; pause ;;
            0) return ;;
        esac
    done
}

# --- MAIN LOOP ---
check_root
install_deps

while true; do
    clear
    ui_header "MRM MANAGER v2.2"
    ui_status_bar

    echo "  1) SSL Certificates"
    echo "  2) Backup & Restore"
    echo "  3) Tools & Settings"
    echo "  4) Admin & Service Control"
    echo ""
    echo "  0) Exit"
    echo ""
    read -p "Select: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) bash /opt/mrm-manager/backup.sh ;;
        3) tools_menu ;;
        4) control_menu ;;
        0) exit 0 ;;
    esac
done