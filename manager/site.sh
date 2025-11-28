#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

WWW_DIR="/var/www/html"

install_nginx_if_needed() {
    if ! command -v nginx &> /dev/null; then
        echo -e "${BLUE}Installing Nginx...${NC}"
        apt-get update -qq && apt-get install -y nginx unzip -qq > /dev/null
    fi
    systemctl enable nginx > /dev/null 2>&1
    systemctl start nginx
}

download_template() {
    local URL=$1
    local NAME=$2
    
    echo -e "${BLUE}Downloading template: $NAME...${NC}"
    rm -rf "$WWW_DIR"/*
    
    # Download and unzip
    wget -qO /tmp/template.zip "$URL"
    if [ $? -eq 0 ]; then
        unzip -q -o /tmp/template.zip -d "$WWW_DIR"
        # If zip contained a folder, move contents up
        if [ $(ls -1 "$WWW_DIR" | wc -l) -eq 1 ] && [ -d "$WWW_DIR/$(ls "$WWW_DIR")" ]; then
            mv "$WWW_DIR"/*/* "$WWW_DIR/" 2>/dev/null
        fi
        rm -f /tmp/template.zip
        
        # Fix permissions
        chown -R www-data:www-data "$WWW_DIR"
        chmod -R 755 "$WWW_DIR"
        
        echo -e "${GREEN}✔ Template installed successfully!${NC}"
    else
        echo -e "${RED}✘ Download failed!${NC}"
    fi
}

setup_fake_site() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      ADVANCED FAKE SITE MANAGER             ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    install_nginx_if_needed
    
    echo "Select a template to install on Port 80:"
    echo ""
    echo -e "${ORANGE}--- Professional Templates ---${NC}"
    echo "1) Digital Agency (Modern/Dark)"
    echo "2) Coffee Shop (Elegant)"
    echo "3) Personal Portfolio (Clean)"
    echo "4) Construction Company"
    echo "5) Cryptocurrency Landing Page"
    echo ""
    echo -e "${ORANGE}--- Simple HTML ---${NC}"
    echo "6) Simple Gaming Page (Text only)"
    echo "7) Simple Tech Page (Text only)"
    echo ""
    echo -e "${ORANGE}--- Custom ---${NC}"
    echo "8) Restore Default Nginx Page"
    echo "9) Upload Custom Zip (URL)"
    echo "10) Back"
    
    read -p "Select: " T_OPT
    
    case $T_OPT in
        1) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page296/oxer.zip" "Digital Agency" ;;
        2) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page293/chocolux.zip" "Coffee Shop" ;;
        3) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page294/shapel.zip" "Portfolio" ;;
        4) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page296/constra.zip" "Construction" ;;
        5) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page293/dgital.zip" "Crypto" ;;
        6) 
            echo '<!DOCTYPE html><html><head><title>Vortex</title><style>body{background:#111;color:#0f0;font-family:monospace;text-align:center;padding-top:20%}</style></head><body><h1>SYSTEM READY</h1><p>Waiting for input...</p></body></html>' > "$WWW_DIR/index.html"
            echo -e "${GREEN}✔ Installed.${NC}"
            ;;
        7)
            echo '<!DOCTYPE html><html><head><title>Cloud</title><style>body{background:#fff;color:#333;font-family:sans-serif;text-align:center;padding-top:20%}</style></head><body><h1>Cloud Server</h1><p>Status: Online</p></body></html>' > "$WWW_DIR/index.html"
            echo -e "${GREEN}✔ Installed.${NC}"
            ;;
        8)
            echo '<h1>Welcome to nginx!</h1>' > "$WWW_DIR/index.html"
            echo -e "${GREEN}✔ Restored default.${NC}"
            ;;
        9)
            read -p "Enter Zip URL: " ZIP_URL
            download_template "$ZIP_URL" "Custom Zip"
            ;;
        *) return ;;
    esac
    
    # Ensure Nginx config is correct
    cat > "/etc/nginx/sites-available/default" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root $WWW_DIR;
    index index.html index.htm;
    server_name _;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Custom 404 page
    error_page 404 /404.html;
    location = /404.html {
        internal;
    }
}
EOF
    
    # Create fake 404 page
    echo "<html><head><title>404 Not Found</title></head><body style='text-align:center;padding-top:50px;'><h1>404 Not Found</h1><hr><p>nginx</p></body></html>" > "$WWW_DIR/404.html"
    
    systemctl restart nginx
    
    echo ""
    echo -e "${YELLOW}Remember to set Fallback Port to 80 in your Inbound settings!${NC}"
    pause
}

toggle_site() {
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx
        echo -e "${RED}Site Stopped (Port 80 freed).${NC}"
    else
        systemctl start nginx
        echo -e "${GREEN}Site Started.${NC}"
    fi
    pause
}

site_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      FAKE SITE MANAGER (Nginx)            ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        
        echo -ne "Current Status: "
        if systemctl is-active --quiet nginx; then
            echo -e "${GREEN}● Running${NC}"
        else
            echo -e "${RED}● Stopped${NC}"
        fi
        echo ""
        
        echo "1) Install / Change Template (Wizard)"
        echo "2) Start / Stop Site"
        echo "3) Edit HTML Manually (nano)"
        echo "4) Back"
        read -p "Select: " OPT
        case $OPT in
            1) setup_fake_site ;;
            2) toggle_site ;;
            3) nano "$WWW_DIR/index.html" ;;
            4) return ;;
            *) ;;
        esac
    done
}