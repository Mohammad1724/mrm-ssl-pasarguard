#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# Detect correct Xray config path based on DATA_DIR from utils
if [ -f "$DATA_DIR/xray_config.json" ]; then
    XRAY_CONFIG="$DATA_DIR/xray_config.json"
else
    XRAY_CONFIG="$DATA_DIR/config.json"
fi

NGINX_CONF="/etc/nginx/conf.d/panel_separate.conf"
BACKUP_DIR="$DATA_DIR/backups_port_manager"

check_reqs() {
    if ! command -v nginx &> /dev/null; then
        echo -e "${RED}Nginx is required! Please install it first.${NC}"
        return 1
    fi
    if ! command -v lsof &> /dev/null; then
        install_package lsof lsof
    fi
    mkdir -p "$BACKUP_DIR"
}

backup_configs() {
    echo -e "${BLUE}Backing up configurations...${NC}"
    local TS=$(date +%s)
    [ -f "$XRAY_CONFIG" ] && cp "$XRAY_CONFIG" "$BACKUP_DIR/config.json.$TS"
    [ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "$BACKUP_DIR/nginx.conf.$TS"
    ls -1t "$BACKUP_DIR"/* | tail -n +11 | xargs rm -f 2>/dev/null
}

restore_configs() {
    echo -e "${YELLOW}Restoring last configuration...${NC}"
    local LAST_XRAY=$(ls -1t "$BACKUP_DIR"/config.json.* 2>/dev/null | head -1)
    local LAST_NGINX=$(ls -1t "$BACKUP_DIR"/nginx.conf.* 2>/dev/null | head -1)
    if [ -f "$LAST_XRAY" ]; then cp "$LAST_XRAY" "$XRAY_CONFIG"; echo "Restored Xray"; fi
    if [ -f "$LAST_NGINX" ]; then cp "$LAST_NGINX" "$NGINX_CONF"; echo "Restored Nginx"; fi
    restart_service "panel"
    systemctl restart nginx
    echo -e "${GREEN}✔ Rollback Complete.${NC}"
    pause
}

setup_dual_port() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      DUAL PORT MODE (Split)                 ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    read -p "Admin Domain: " ADOM
    read -p "Sub Domain: " SDOM
    read -p "Port for Panel/Sub (e.g. 2096): " PORT
    read -p "Internal Panel Port (e.g. 7431): " PPORT
    [ -z "$ADOM" ] || [ -z "$SDOM" ] || [ -z "$PORT" ] || [ -z "$PPORT" ] && return

    backup_configs

    # FIX: Ensure we use the correct cert for SUB domain
    local SUB_CERT_PATH="/etc/letsencrypt/live/$SDOM"
    if [ ! -d "$SUB_CERT_PATH" ]; then
        echo -e "${YELLOW}Cert for $SDOM not found, using $ADOM cert (Warning: Might cause mismatch)${NC}"
        SUB_CERT_PATH="/etc/letsencrypt/live/$ADOM"
    fi

    echo -e "${BLUE}Configuring Nginx on port $PORT...${NC}"
    cat > "$NGINX_CONF" <<EOF
# Admin Domain
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    server_name $ADOM;
    ssl_certificate /etc/letsencrypt/live/$ADOM/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADOM/privkey.pem;
    location / {
        # FIX: Use HTTP to avoid 502 Bad Gateway if panel SSL is off
        proxy_pass http://127.0.0.1:$PPORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
# Sub Domain
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    server_name $SDOM;
    ssl_certificate ${SUB_CERT_PATH}/fullchain.pem;
    ssl_certificate_key ${SUB_CERT_PATH}/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:$PPORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    echo -e "${BLUE}Cleaning Xray fallbacks...${NC}"
    python3 << PYEOF
import json
try:
    path = "$XRAY_CONFIG"
    with open(path, 'r') as f: data = json.load(f)
    for ib in data.get('inbounds', []):
        if ib.get('port') == 443 and 'fallbacks' in ib['settings']:
            new_fb = [fb for fb in ib['settings']['fallbacks'] if 'name' not in fb]
            ib['settings']['fallbacks'] = new_fb
    with open(path, 'w') as f: json.dump(data, f, indent=2)
    print("OK")
except Exception as e: print(e)
PYEOF

    # FIX: Check firewall
    if command -v ufw &> /dev/null; then ufw allow $PORT/tcp > /dev/null 2>&1; fi
    
    if nginx -t; then
        systemctl restart nginx
        restart_service "panel"
        echo -e "${GREEN}✔ Dual Port Mode Activated!${NC}"
    else
        echo -e "${RED}✘ Nginx Error! Rolling back...${NC}"
        restore_configs
    fi
    pause
}

setup_single_port() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      SINGLE PORT MODE (443 Only)            ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    read -p "Admin Domain: " ADOM
    read -p "Sub Domain: " SDOM
    read -p "Internal Panel Port (e.g. 7431): " PPORT

    # Ask for fallback port
    read -p "Internal Nginx Fallback Port [8080]: " FB_PORT
    [ -z "$FB_PORT" ] && FB_PORT="8080"

    # Check if port is in use
    if lsof -i :$FB_PORT > /dev/null 2>&1; then
        echo -e "${RED}Warning: Port $FB_PORT seems to be in use!${NC}"
        read -p "Continue anyway? (y/n): " CONT
        if [ "$CONT" != "y" ]; then return; fi
    fi

    [ -z "$ADOM" ] || [ -z "$SDOM" ] || [ -z "$PPORT" ] && return

    backup_configs

    echo -e "${BLUE}Configuring Nginx on localhost:$FB_PORT...${NC}"
    # FIX: Changed proxy_protocol to standard listen, and proxy_pass to http
    cat > "$NGINX_CONF" <<EOF
server {
    listen $FB_PORT;
    listen [::]:$FB_PORT;
    server_name $ADOM $SDOM;
    location / {
        proxy_pass http://127.0.0.1:$PPORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    echo -e "${BLUE}Adding Xray fallbacks...${NC}"
    # NOTE: This JSON modification might be overwritten by Marzban on restart.
    python3 << PYEOF
import json
try:
    path = "$XRAY_CONFIG"
    with open(path, 'r') as f: data = json.load(f)
    for ib in data.get('inbounds', []):
        if ib.get('port') == 443:
            if 'fallbacks' not in ib['settings']: ib['settings']['fallbacks'] = []
            fb_list = ib['settings']['fallbacks']
            # Remove old
            fb_list = [fb for fb in fb_list if fb.get('name') not in ["$ADOM", "$SDOM"]]
            # Add new (xver: 1 is removed because nginx above is not proxy_protocol)
            fb_list.insert(0, {"name": "$ADOM", "dest": $FB_PORT})
            fb_list.insert(0, {"name": "$SDOM", "dest": $FB_PORT})
            ib['settings']['fallbacks'] = fb_list
    with open(path, 'w') as f: json.dump(data, f, indent=2)
    print("OK")
except Exception as e: print(e)
PYEOF

    if nginx -t; then
        systemctl restart nginx
        restart_service "panel"
        echo -e "${GREEN}✔ Single Port Mode Activated!${NC}"
        echo -e "${YELLOW}Note: If Panel restarts revert this, configure XRAY_JSON in .env${NC}"
    else
        echo -e "${RED}✘ Nginx Error! Rolling back...${NC}"
        restore_configs
    fi
    pause
}

port_menu() {
    check_reqs || return
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      PORT MANAGER (Architecture)          ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Switch to Dual Port (Separate 2096 & 443)"
        echo "2) Switch to Single Port (Everything 443)"
        echo "3) Restore Previous Config (Rollback)"
        echo "4) Back"
        read -p "Select: " OPT
        case $OPT in
            1) setup_dual_port ;;
            2) setup_single_port ;;
            3) restore_configs ;;
            4) return ;;
            *) ;;
        esac
    done
}