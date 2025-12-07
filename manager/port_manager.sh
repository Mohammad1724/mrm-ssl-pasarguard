#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

XRAY_CONFIG="/var/lib/pasarguard/config.json"
NGINX_CONF="/etc/nginx/conf.d/panel_separate.conf"
BACKUP_DIR="/var/lib/pasarguard/backups_port_manager"

# --- HELPERS ---
check_reqs() {
    if ! command -v nginx &> /dev/null; then
        echo -e "${RED}Nginx is required! Please install it first.${NC}"
        return 1
    fi
    mkdir -p "$BACKUP_DIR"
}

backup_configs() {
    echo -e "${BLUE}Backing up configurations...${NC}"
    local TS=$(date +%s)
    [ -f "$XRAY_CONFIG" ] && cp "$XRAY_CONFIG" "$BACKUP_DIR/config.json.$TS"
    [ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "$BACKUP_DIR/nginx.conf.$TS"
    
    # Keep only last 5 backups
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

# --- MODE 1: DUAL PORT (Separated) ---
setup_dual_port() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      DUAL PORT MODE (Split)                 ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo "Details:"
    echo "- VPN Users: Port 443 (Xray)"
    echo "- Sub Link & Panel: Custom Port (e.g. 2096)"
    echo ""
    
    read -p "Admin Domain: " ADOM
    read -p "Sub Domain: " SDOM
    read -p "Port for Panel/Sub (e.g. 2096): " PORT
    read -p "Internal Panel Port (e.g. 7431): " PPORT
    
    [ -z "$ADOM" ] || [ -z "$SDOM" ] || [ -z "$PORT" ] || [ -z "$PPORT" ] && return
    
    backup_configs
    
    # 1. Configure Nginx (Listen on Custom Port with SSL)
    echo -e "${BLUE}Configuring Nginx on port $PORT...${NC}"
    cat > "$NGINX_CONF" <<EOF
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    server_name $ADOM $SDOM;
    
    ssl_certificate /etc/letsencrypt/live/$ADOM/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADOM/privkey.pem;
    
    location / {
        proxy_pass https://127.0.0.1:$PPORT;
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name $ADOM;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # 2. Clean Xray Fallbacks (Remove Domain Fallbacks if any)
    # We use python to safely remove domain fallbacks from port 443
    echo -e "${BLUE}Cleaning Xray fallbacks...${NC}"
    python3 << PYEOF
import json
try:
    path = "$XRAY_CONFIG"
    with open(path, 'r') as f:
        data = json.load(f)
    
    for ib in data.get('inbounds', []):
        if ib.get('port') == 443 and 'fallbacks' in ib['settings']:
            # Filter out fallbacks that have 'name' (domain based)
            # Keep only dest:80 (default fallback)
            new_fb = [fb for fb in ib['settings']['fallbacks'] if 'name' not in fb]
            ib['settings']['fallbacks'] = new_fb
            
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print("OK")
except Exception as e:
    print(e)
PYEOF

    # 3. Apply
    ufw allow $PORT/tcp > /dev/null 2>&1
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

# --- MODE 2: SINGLE PORT (Fallback) ---
setup_single_port() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      SINGLE PORT MODE (443 Only)            ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo "Details:"
    echo "- Everything on Port 443 (Stealth)"
    echo "- Xray handles VPN"
    echo "- Xray falls back Panel/Sub traffic to Nginx (internal)"
    echo ""
    
    read -p "Admin Domain: " ADOM
    read -p "Sub Domain: " SDOM
    read -p "Internal Panel Port (e.g. 7431): " PPORT
    
    [ -z "$ADOM" ] || [ -z "$SDOM" ] || [ -z "$PPORT" ] && return
    
    backup_configs
    
    # 1. Configure Nginx (Listen on Local Port 8080, NO SSL)
    # Xray handles SSL, so Nginx receives plain HTTP
    echo -e "${BLUE}Configuring Nginx on localhost:8080...${NC}"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 8080 proxy_protocol;
    listen [::]:8080 proxy_protocol;
    server_name $ADOM $SDOM;
    
    location / {
        proxy_pass https://127.0.0.1:$PPORT;
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name $ADOM;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # 2. Add Fallbacks to Xray
    echo -e "${BLUE}Adding Xray fallbacks...${NC}"
    python3 << PYEOF
import json
try:
    path = "$XRAY_CONFIG"
    with open(path, 'r') as f:
        data = json.load(f)
    
    for ib in data.get('inbounds', []):
        if ib.get('port') == 443:
            if 'fallbacks' not in ib['settings']:
                ib['settings']['fallbacks'] = []
            
            fb_list = ib['settings']['fallbacks']
            # Remove old entries for these domains to avoid duplicates
            fb_list = [fb for fb in fb_list if fb.get('name') not in ["$ADOM", "$SDOM"]]
            
            # Add new fallbacks
            fb_list.insert(0, {"name": "$ADOM", "dest": 8080, "xver": 1})
            fb_list.insert(0, {"name": "$SDOM", "dest": 8080, "xver": 1})
            
            ib['settings']['fallbacks'] = fb_list
            
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print("OK")
except Exception as e:
    print(e)
PYEOF

    # 3. Apply
    if nginx -t; then
        systemctl restart nginx
        restart_service "panel"
        echo -e "${GREEN}✔ Single Port Mode Activated!${NC}"
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