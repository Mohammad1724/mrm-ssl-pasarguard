#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
NGINX_CONF="/etc/nginx/conf.d/panel_separate.conf"

setup_domain_separation() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      DOMAIN SEPARATOR (Safe SSL)            ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    read -p "Admin Domain: " ADMIN_DOM
    read -p "Sub Domain: " SUB_DOM
    read -p "Port to use (default: 2096): " PORT
    [ -z "$PORT" ] && PORT="2096"
    read -p "Current Panel Port (default: 7431): " PANEL_PORT
    [ -z "$PANEL_PORT" ] && PANEL_PORT="7431"

    [ -z "$ADMIN_DOM" ] || [ -z "$SUB_DOM" ] && return

    # Stop Nginx for standalone certbot
    systemctl stop nginx

    # FIXED: Get certs SEPARATELY to avoid total failure
    echo -e "${BLUE}Requesting SSL for Admin: $ADMIN_DOM${NC}"
    certbot certonly --standalone --non-interactive --agree-tos --email "admin@$ADMIN_DOM" -d "$ADMIN_DOM"
    
    echo -e "${BLUE}Requesting SSL for Sub: $SUB_DOM${NC}"
    certbot certonly --standalone --non-interactive --agree-tos --email "admin@$ADMIN_DOM" -d "$SUB_DOM"

    # Check
    if [ ! -d "/etc/letsencrypt/live/$ADMIN_DOM" ]; then
        echo -e "${RED}Failed to get SSL for Admin Domain.${NC}"; systemctl start nginx; pause; return
    fi
    # Use Admin SSL for sub if sub failed (fallback), but better to have separate blocks.
    # For now, we assume both are needed.
    
    # Write Nginx
    cat > "$NGINX_CONF" <<EOF
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    server_name $ADMIN_DOM $SUB_DOM;
    # Using Admin cert as primary (or make 2 server blocks for perfection)
    ssl_certificate /etc/letsencrypt/live/$ADMIN_DOM/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOM/privkey.pem;

    location / {
        proxy_pass https://127.0.0.1:$PANEL_PORT;
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name $ADMIN_DOM;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    if nginx -t; then
        ufw allow $PORT/tcp > /dev/null 2>&1
        systemctl restart nginx
        echo -e "${GREEN}✔ Setup Complete.${NC}"
    else
        echo -e "${RED}✘ Nginx Config Error.${NC}"
    fi
    pause
}

domain_menu() {
    while true; do
        clear
        echo "1) Separate Admin & Sub Domains"
        echo "2) Back"
        read -p "Select: " OPT
        case $OPT in 1) setup_domain_separation ;; 2) return ;; esac
    done
}