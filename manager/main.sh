#!/bin/bash

# ==========================================
# MRM MANAGER v3.2 - Full Pro Edition
# ==========================================

# Load Modules
source /opt/mrm-manager/utils.sh
source /opt/mrm-manager/ui.sh
source /opt/mrm-manager/ssl.sh
source /opt/mrm-manager/backup.sh
source /opt/mrm-manager/domain_separator.sh
source /opt/mrm-manager/site.sh
source /opt/mrm-manager/theme.sh
source /opt/mrm-manager/migrator.sh
source /opt/mrm-manager/mirza.sh

# Load Inbound Module (NEW STRUCTURE)
source /opt/mrm-manager/inbound/main.sh

# Detect panel on startup
detect_active_panel > /dev/null

# ==========================================
# HELPER FUNCTIONS
# ==========================================
edit_file() {
    if [ -f "$1" ]; then 
        nano "$1"
    else 
        ui_error "File not found: $1"
        pause
    fi
}

# ==========================================
# NETWORK OPTIMIZATION (BBR)
# ==========================================
optimize_network() {
    ui_header "NETWORK OPTIMIZATION"

    ui_spinner_start "Enabling BBR..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    ui_spinner_stop
    ui_success "BBR Enabled"

    ui_spinner_start "Tuning TCP Stack..."
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
    ui_spinner_stop
    ui_success "TCP Tuned"

    ui_spinner_start "Increasing System Limits..."
    if ! grep -q "* soft nofile 1000000" /etc/security/limits.conf; then
        echo "* soft nofile 1000000" >> /etc/security/limits.conf
        echo "* hard nofile 1000000" >> /etc/security/limits.conf
        echo "root soft nofile 1000000" >> /etc/security/limits.conf
        echo "root hard nofile 1000000" >> /etc/security/limits.conf
    fi
    ui_spinner_stop
    ui_success "Limits Increased"

    echo ""
    ui_success "Network Optimization Complete!"
    pause
}

# ==========================================
# AUTO FIX
# ==========================================
auto_fix() {
    ui_header "AUTO FIX"

    ui_spinner_start "Configuring Firewall..."
    ufw allow 22,80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1

    for r in "192.0.0.0/8" "102.0.0.0/8" "198.0.0.0/8" "172.0.0.0/8"; do
        ufw delete deny from "$r" >/dev/null 2>&1 || true
        ufw delete deny out to "$r" >/dev/null 2>&1 || true
    done
    ui_spinner_stop
    ui_success "Firewall Fixed"

    ui_spinner_start "Fixing .env files..."
    if [ -f "$PANEL_ENV" ]; then
        sed -i 's|\(postgresql+asyncpg://[^"?]*\)\(["\s]*\)$|\1?ssl=disable\2|' "$PANEL_ENV"
        sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$PANEL_ENV"
        sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$PANEL_ENV"
    fi
    ui_spinner_stop
    ui_success ".env Files Fixed"

    ui_spinner_start "Restarting Services..."
    restart_service "panel" >/dev/null 2>&1
    restart_service "node" >/dev/null 2>&1
    ui_spinner_stop
    ui_success "Services Restarted"

    echo ""
    ui_success "Auto Fix Complete!"
    pause
}

# ==========================================
# PANEL CONTROL MENU
# ==========================================
panel_menu() {
    while true; do
        ui_header "PANEL CONTROL"
        detect_active_panel > /dev/null

        echo -e "Active Panel: ${UI_CYAN}$PANEL_DIR${UI_NC}"
        echo ""
        echo "1) 🔄 Restart Panel"
        echo "2) ⏹️  Stop Panel"
        echo "3) ▶️  Start Panel"
        echo "4) 📋 View Logs (Live)"
        echo "5) 👤 Create Admin"
        echo "6) 🔑 Reset Admin Password"
        echo "7) 📝 Edit .env"
        echo "8) 📝 Edit docker-compose.yml"
        echo ""
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) restart_service "panel"; pause ;;
            2) cd "$PANEL_DIR" && docker compose down; ui_success "Stopped"; pause ;;
            3) cd "$PANEL_DIR" && docker compose up -d; ui_success "Started"; pause ;;
            4) cd "$PANEL_DIR" && docker compose logs -f ;;
            5) admin_create; pause ;;
            6) admin_reset; pause ;;
            7) edit_file "$PANEL_ENV" ;;
            8) edit_file "$PANEL_DIR/docker-compose.yml" ;;
            0) return ;;
        esac
    done
}

# ==========================================
# TOOLS MENU
# ==========================================
tools_menu() {
    while true; do
        clear
        ui_header "TOOLS"

        echo "1) 🌐 Domain Separator (Panel & Sub)"
        echo "2) 🎭 Fake Site Manager"
        echo "3) 📥 Inbound Wizard"
        echo "4) 🎨 Theme Manager"
        echo "5) 🔄 Migration (Pasarguard → Rebecca)"
        echo ""
        echo "6) ⚡ Optimize Network (BBR)"
        echo "7) 🔧 Auto Fix"
        echo ""
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) domain_menu ;;
            2) site_menu ;;
            3) inbound_menu ;;
            4) theme_menu ;;
            5) migrator_menu ;;
            6) optimize_network ;;
            7) auto_fix ;;
            0) return ;;
        esac
    done
}

# ==========================================
# MAIN MENU
# ==========================================
main_menu() {
    check_root
    install_deps

    while true; do
        ui_header "MRM MANAGER v3.2" 50
        ui_status_bar

        echo "1) 🔐 SSL Certificates"
        echo "2) 💾 Backup & Restore"
        echo "3) 🤖 Mirza Pro (Telegram Bot)"
        echo "4) ⚙️  Panel Control"
        echo "5) 🛠️  Tools"
        echo ""
        echo "0) Exit"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) ssl_menu ;;
            2) backup_menu ;;
            3) mirza_menu ;;
            4) panel_menu ;;
            5) tools_menu ;;
            0) 
                clear
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0 
                ;;
        esac
    done
}

# Run
main_menu