#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

NGINX_CONF="/etc/nginx/conf.d/panel_separate.conf"

install_requirements() {
    echo -e "${BLUE}Checking requirements...${NC}"
    local NEED_INSTALL=false
    
    if ! command -v nginx &> /dev/null; then
        echo -e "${YELLOW}Nginx not found. Installing...${NC}"
        NEED_INSTALL=true
    fi
    
    if ! command -v certbot &> /dev/null; then
        echo -e "${YELLOW}Certbot not found. Installing...${NC}"
        NEED_INSTALL=true
    fi
    
    if [ "$NEED_INSTALL" = true ]; then
        apt-get update -qq
        apt-get install -y nginx certbot python3-certbot-nginx -qq
        echo -e "${GREEN}✔ Requirements installed.${NC}"
    else
        echo -e "${GREEN}✔ Requirements are already installed.${NC}"
    fi
    
    systemctl enable nginx > /dev/null 2>&1
}

setup_domain_separation() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      DOMAIN SEPARATOR (Panel & Sub)         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    install_requirements
    
    # --- CLEANUP OLD CONFLICTS ---
    if [ -f "/etc/nginx/conf.d/panel.conf" ]; then
        echo -e "${YELLOW}Found conflicting config: panel.conf. Disabling it...${NC}"
        mv /etc/nginx/conf.d/panel.conf /etc/nginx/conf.d/panel.conf.bak
        echo -e "${GREEN}✔ Disabled panel.conf${NC}"
    fi
    
    echo ""
    
    # 1. Get Inputs
    read -p "1. Admin Domain (e.g., admin.site.com): " ADMIN_DOM
    if [ -z "$ADMIN_DOM" ]; then echo -e "${RED}Error: Admin Domain is required!${NC}"; pause; return; fi
    
    read -p "2. Sub Domain (e.g., sub.site.com): " SUB_DOM
    if [ -z "$SUB_DOM" ]; then echo -e "${RED}Error: Sub Domain is required!${NC}"; pause; return; fi
    
    read -p "3. Port to use (default: 2096): " PORT
    [ -z "$PORT" ] && PORT="2096"
    
    read -p "4. Current Panel Port (default: 7431): " PANEL_PORT
    [ -z "$PANEL_PORT" ] && PANEL_PORT="7431"
    
    echo ""
    echo -e "${BLUE}-------------------------------------${NC}"
    echo -e "Admin: ${CYAN}$ADMIN_DOM${NC}"
    echo -e "Sub:   ${CYAN}$SUB_DOM${NC}"
    echo -e "Port:  ${CYAN}$PORT${NC}"
    echo -e "Panel: ${CYAN}$PANEL_PORT${NC}"
    echo -e "${BLUE}-------------------------------------${NC}"
    read -p "Is this correct? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then echo "Cancelled."; pause; return; fi
    
    # 2. Get SSL
    echo ""
    echo -e "${BLUE}Stopping Nginx to get SSL...${NC}"
    systemctl stop nginx
    
    echo -e "${BLUE}Requesting SSL from Let's Encrypt...${NC}"
    # We request for BOTH domains in ONE certificate (using --expand)
    certbot certonly --standalone --non-interactive --agree-tos --expand \
        --email "admin@$ADMIN_DOM" \
        -d "$ADMIN_DOM" -d "$SUB_DOM"
        
    local CERT_RES=$?
    
    # Verify SSL Success
    if [ $CERT_RES -ne 0 ] || [ ! -d "/etc/letsencrypt/live/$ADMIN_DOM" ]; then
        echo ""
        echo -e "${RED}✘ SSL Generation Failed!${NC}"
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "1. Check if domains ($ADMIN_DOM, $SUB_DOM) point to this server IP."
        echo "2. Turn OFF Cloudflare Proxy (Orange Cloud) temporarily."
        echo "3. Ensure Port 80 is open."
        
        systemctl start nginx
        pause
        return
    fi
    
    echo -e "${GREEN}✔ SSL Certificates obtained successfully.${NC}"
    
    # 3. Configure Nginx
    echo -e "${BLUE}Writing Nginx configuration to $NGINX_CONF...${NC}"
    
    cat > "$NGINX_CONF" <<EOF
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    
    server_name $ADMIN_DOM $SUB_DOM;

    # SSL Certificates (Using the first domain's path which contains both)
    ssl_certificate /etc/letsencrypt/live/$ADMIN_DOM/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOM/privkey.pem;

    location / {
        # Connect to Panel via HTTPS (Important: Panel uses self-signed SSL)
        proxy_pass https://127.0.0.1:$PANEL_PORT;
        
        # Ignore Panel's internal SSL errors (Fixes 502 Bad Gateway)
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name $ADMIN_DOM;

        # Standard Proxy Headers
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

    # 4. Test Nginx Config (Critical Step)
    echo -e "${BLUE}Testing Nginx configuration...${NC}"
    if ! nginx -t; then
        echo -e "${RED}✘ Nginx Config Error! Reverting changes...${NC}"
        rm -f "$NGINX_CONF"
        systemctl start nginx
        pause
        return
    fi

    # 5. Open Firewall
    echo -e "${BLUE}Opening firewall port $PORT...${NC}"
    ufw allow $PORT/tcp > /dev/null 2>&1
    
    # 6. Restart Nginx
    echo -e "${BLUE}Restarting Nginx...${NC}"
    systemctl restart nginx
    
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}✔ Nginx is running.${NC}"
    else
        echo -e "${RED}✘ Nginx failed to start! Check logs: journalctl -xe${NC}"
        pause; return
    fi
    
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}      SETUP COMPLETED SUCCESSFULLY    ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "1. Login Panel: ${CYAN}https://$ADMIN_DOM:$PORT${NC}"
    echo -e "2. Go to Panel Settings > General"
    echo -e "3. Set 'Subscription URL' to: ${CYAN}https://$SUB_DOM:$PORT${NC}"
    echo ""
    pause
}

domain_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      DOMAIN MANAGER                       ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Separate Admin & Sub Domains (Wizard)"
        echo "2) Restart Nginx"
        echo "3) Check Nginx Status"
        echo "4) Edit Nginx Config Manually"
        echo "5) Back"
        read -p "Select: " OPT
        case $OPT in
            1) setup_domain_separation ;;
            2) systemctl restart nginx; echo "Done."; sleep 1 ;;
            3) systemctl status nginx --no-pager; pause ;;
            4) nano "$NGINX_CONF" ;;
            5) return ;;
            *) ;;
        esac
    done
}