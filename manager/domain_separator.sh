#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

NGINX_CONF="/etc/nginx/conf.d/panel_separate.conf"

install_requirements() {
    local NEED_INSTALL=false
    command -v nginx &> /dev/null || NEED_INSTALL=true
    command -v certbot &> /dev/null || NEED_INSTALL=true
    
    if [ "$NEED_INSTALL" = true ]; then
        echo -e "${BLUE}Installing Nginx and Certbot...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y nginx certbot python3-certbot-nginx -qq > /dev/null
    fi
    systemctl enable nginx > /dev/null 2>&1
}

setup_domain_separation() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      DOMAIN SEPARATOR (Panel & Sub)         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo "This will separate your Admin Panel and Subscription Link"
    echo "using Nginx on a custom port (e.g., 2096)."
    echo ""
    
    install_requirements
    
    # 1. Get Inputs
    read -p "Admin Domain (e.g., admin.site.com): " ADMIN_DOM
    read -p "Sub Domain (e.g., sub.site.com): " SUB_DOM
    read -p "Port to use (e.g., 2096): " PORT
    read -p "Current Panel Port (e.g., 7431): " PANEL_PORT
    
    [ -z "$ADMIN_DOM" ] || [ -z "$SUB_DOM" ] || [ -z "$PORT" ] || [ -z "$PANEL_PORT" ] && return
    
    # 2. Get SSL
    echo -e "\n${BLUE}Requesting SSL Certificates...${NC}"
    systemctl stop nginx
    
    certbot certonly --standalone --non-interactive --agree-tos --expand \
        --email "admin@$ADMIN_DOM" \
        -d "$ADMIN_DOM" -d "$SUB_DOM"
        
    if [ ! -d "/etc/letsencrypt/live/$ADMIN_DOM" ]; then
        echo -e "${RED}SSL Failed! Check domains DNS.${NC}"
        return
    fi
    
    # 3. Configure Nginx
    echo -e "\n${BLUE}Configuring Nginx...${NC}"
    
    cat > "$NGINX_CONF" <<EOF
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    
    server_name $ADMIN_DOM $SUB_DOM;

    ssl_certificate /etc/letsencrypt/live/$ADMIN_DOM/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOM/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        
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

    # 4. Open Firewall
    ufw allow $PORT/tcp > /dev/null 2>&1
    
    # 5. Restart Nginx
    systemctl start nginx
    systemctl restart nginx
    
    # 6. Update Panel Config (Optional but recommended)
    echo -e "\n${BLUE}Updating Panel Subscription URL...${NC}"
    # We can't easily edit DB, but we can guide user
    
    echo -e "${GREEN}✔ Configuration Complete!${NC}"
    echo ""
    echo -e "${YELLOW}--- ACTION REQUIRED ---${NC}"
    echo -e "1. Login to Panel: ${CYAN}https://$ADMIN_DOM:$PORT${NC}"
    echo -e "2. Go to Settings"
    echo -e "3. Set Subscription URL to: ${CYAN}https://$SUB_DOM:$PORT${NC}"
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
        echo "3) Edit Nginx Config Manually"
        echo "4) Back"
        read -p "Select: " OPT
        case $OPT in
            1) setup_domain_separation ;;
            2) systemctl restart nginx; echo "Done."; sleep 1 ;;
            3) nano "$NGINX_CONF" ;;
            4) return ;;
            *) ;;
        esac
    done
}