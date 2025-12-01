#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

WWW_DIR="/var/www/html"

install_nginx_if_needed() {
    # Install required tools
    local NEED_INSTALL=false
    command -v nginx &> /dev/null || NEED_INSTALL=true
    command -v wget &> /dev/null || NEED_INSTALL=true
    command -v unzip &> /dev/null || NEED_INSTALL=true
    
    if [ "$NEED_INSTALL" = true ]; then
        echo -e "${BLUE}Installing Nginx and tools...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y nginx wget unzip -qq > /dev/null
    fi
    
    systemctl enable nginx > /dev/null 2>&1
    systemctl start nginx > /dev/null 2>&1
}

download_template() {
    local URL=$1
    local NAME=$2

    echo -e "${BLUE}Downloading template: $NAME...${NC}"
    
    # Backup current site
    if [ -f "$WWW_DIR/index.html" ]; then
        cp "$WWW_DIR/index.html" "/tmp/index_backup.html"
    fi
    
    rm -rf "$WWW_DIR"/*

    # Download
    if wget -qO /tmp/template.zip "$URL"; then
        # Check if file is valid zip
        if file /tmp/template.zip | grep -q "Zip archive"; then
            unzip -q -o /tmp/template.zip -d "$WWW_DIR"
            
            # If zip contained a single folder, move contents up
            local ITEMS=$(ls -1 "$WWW_DIR" | wc -l)
            local FIRST_ITEM=$(ls -1 "$WWW_DIR" | head -1)
            if [ "$ITEMS" -eq 1 ] && [ -d "$WWW_DIR/$FIRST_ITEM" ]; then
                mv "$WWW_DIR/$FIRST_ITEM"/* "$WWW_DIR/" 2>/dev/null
                rmdir "$WWW_DIR/$FIRST_ITEM" 2>/dev/null
            fi
            
            rm -f /tmp/template.zip

            # Fix permissions
            chown -R www-data:www-data "$WWW_DIR" 2>/dev/null
            chmod -R 755 "$WWW_DIR"

            echo -e "${GREEN}✔ Template installed successfully!${NC}"
        else
            echo -e "${RED}✘ Downloaded file is not a valid ZIP!${NC}"
            # Restore backup
            if [ -f "/tmp/index_backup.html" ]; then
                cp "/tmp/index_backup.html" "$WWW_DIR/index.html"
            fi
        fi
    else
        echo -e "${RED}✘ Download failed! URL may be invalid.${NC}"
        # Restore backup
        if [ -f "/tmp/index_backup.html" ]; then
            cp "/tmp/index_backup.html" "$WWW_DIR/index.html"
        fi
    fi
    
    rm -f /tmp/template.zip /tmp/index_backup.html 2>/dev/null
}

setup_fake_site() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      FAKE SITE MANAGER                      ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    install_nginx_if_needed

    echo ""
    echo "Select a template to install on Port 80:"
    echo ""
    echo -e "${BLUE}--- Professional Templates ---${NC}"
    echo "1) Digital Agency (Modern/Dark)"
    echo "2) Coffee Shop (Elegant)"
    echo "3) Personal Portfolio (Clean)"
    echo "4) Construction Company"
    echo "5) Cryptocurrency Landing Page"
    echo ""
    echo -e "${BLUE}--- Simple HTML (Always Works) ---${NC}"
    echo "6) Simple Gaming Page"
    echo "7) Simple Tech Page"
    echo "8) Simple Business Page"
    echo ""
    echo -e "${BLUE}--- Custom ---${NC}"
    echo "9) Upload Custom Zip (URL)"
    echo "10) Restore Default Nginx"
    echo "11) Back"

    read -p "Select: " T_OPT

    case $T_OPT in
        1) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page296/oxer.zip" "Digital Agency" ;;
        2) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page293/chocolux.zip" "Coffee Shop" ;;
        3) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page294/shapel.zip" "Portfolio" ;;
        4) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page296/constra.zip" "Construction" ;;
        5) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page293/dgital.zip" "Crypto" ;;
        6) 
            cat > "$WWW_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Vortex Gaming</title>
    <style>
        body { background: #111; color: #0f0; font-family: monospace; text-align: center; padding-top: 15%; }
        h1 { font-size: 3em; text-shadow: 0 0 10px #0f0; }
    </style>
</head>
<body>
    <h1>VORTEX GAMING</h1>
    <p>System Online | Waiting for connection...</p>
</body>
</html>
HTMLEOF
            echo -e "${GREEN}✔ Gaming page installed.${NC}"
            ;;
        7)
            cat > "$WWW_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Cloud Server</title>
    <style>
        body { background: #f5f5f5; color: #333; font-family: sans-serif; text-align: center; padding-top: 15%; }
        h1 { color: #2196F3; }
        .status { color: #4CAF50; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Cloud Server</h1>
    <p>Status: <span class="status">Online</span></p>
    <p>All systems operational.</p>
</body>
</html>
HTMLEOF
            echo -e "${GREEN}✔ Tech page installed.${NC}"
            ;;
        8)
            cat > "$WWW_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Business Solutions</title>
    <style>
        body { background: #fff; color: #333; font-family: Arial, sans-serif; text-align: center; padding-top: 15%; }
        h1 { color: #1a1a1a; }
        p { color: #666; }
    </style>
</head>
<body>
    <h1>Business Solutions Inc.</h1>
    <p>Professional services for modern enterprises.</p>
    <p>Contact: info@business.local</p>
</body>
</html>
HTMLEOF
            echo -e "${GREEN}✔ Business page installed.${NC}"
            ;;
        9)
            echo ""
            read -p "Enter Zip URL: " ZIP_URL
            if [ -n "$ZIP_URL" ]; then
                download_template "$ZIP_URL" "Custom Template"
            else
                echo -e "${RED}URL cannot be empty.${NC}"
            fi
            ;;
        10)
            echo '<h1>Welcome to nginx!</h1><p>Server is running.</p>' > "$WWW_DIR/index.html"
            echo -e "${GREEN}✔ Restored default nginx page.${NC}"
            ;;
        11) return ;;
        *) return ;;
    esac

    # Ensure Nginx config is correct
    cat > "/etc/nginx/sites-available/default" <<'NGINXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html index.htm;
    server_name _;
    
    location / {
        try_files $uri $uri/ =404;
    }
    
    error_page 404 /404.html;
    location = /404.html {
        internal;
    }
}
NGINXEOF

    # Create 404 page
    cat > "$WWW_DIR/404.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head><title>404 Not Found</title></head>
<body style="text-align:center;padding-top:50px;font-family:sans-serif;">
    <h1>404 Not Found</h1>
    <hr>
    <p>nginx</p>
</body>
</html>
HTMLEOF

    systemctl restart nginx

    echo ""
    echo -e "${YELLOW}Tip: Set Fallback Port to 80 in your Inbound settings.${NC}"
    pause
}

toggle_site() {
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx
        echo -e "${YELLOW}Nginx Stopped (Port 80 freed).${NC}"
    else
        systemctl start nginx
        echo -e "${GREEN}Nginx Started.${NC}"
    fi
    pause
}

edit_site() {
    if [ -f "$WWW_DIR/index.html" ]; then
        nano "$WWW_DIR/index.html"
        systemctl restart nginx
    else
        echo -e "${RED}No index.html found. Install a template first.${NC}"
        pause
    fi
}

site_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      FAKE SITE MANAGER (Nginx)            ${NC}"
        echo -e "${BLUE}===========================================${NC}"

        echo -ne "Status: "
        if systemctl is-active --quiet nginx; then
            echo -e "${GREEN}● Running on Port 80${NC}"
        else
            echo -e "${RED}● Stopped${NC}"
        fi
        echo ""

        echo "1) Install / Change Template"
        echo "2) Start / Stop Nginx"
        echo "3) Edit HTML Manually"
        echo "4) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) setup_fake_site ;;
            2) toggle_site ;;
            3) edit_site ;;
            4) return ;;
            *) ;;
        esac
    done
}