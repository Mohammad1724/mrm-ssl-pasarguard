#!/bin/bash
source /opt/mrm-manager/utils.sh

_get_cert_action() {
    local DOMAIN=$1; local EMAIL=$2
    echo -e "${BLUE}Opening Port 80...${NC}"
    ufw allow 80/tcp > /dev/null 2>&1
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null
    fuser -k 80/tcp 2>/dev/null
    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
    systemctl start nginx 2>/dev/null
}

# ... (توابع _process_panel, _process_node, _process_config که قبلاً داشتیم را اینجا کپی کنید) ...
# برای خلاصه شدن اینجا نیاوردم، دقیقاً کدهای بخش SSL قبلی اینجا قرار می‌گیرند.

ssl_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      SSL MANAGEMENT (Modular)             ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Request New SSL (Wizard)"
        echo "2) Show Exact File Paths"
        echo "3) List LetsEncrypt Certs"
        echo "4) Back"
        read -p "Select: " S_OPT
        case $S_OPT in
            1) ssl_wizard ;; # این تابع را هم باید در همین فایل تعریف کنید
            2) show_detailed_paths ;; # این هم همینطور
            3) ls -1 /etc/letsencrypt/live 2>/dev/null; pause ;;
            4) return ;;
        esac
    done
}