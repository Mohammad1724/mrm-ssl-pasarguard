#!/bin/bash
# =============================================
# Mirza Pro Module for MRM Manager
# =============================================

# Load utils if needed
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# --- Global Variables ---
MIRZA_PATH="/var/www/mirzapro"
MIRZA_BACKUP_PATH="/root/mirza_backups"
MIRZA_LOG_FILE="/var/log/mirza_manager.log"
MIRZA_CONFIG_FILE="$MIRZA_PATH/config.php"

# --- Logo ---
mirza_logo() {
    clear
    echo -e "${CYAN}"
    cat << EOF
███╗   ███╗██╗██████╗ ███████╗ █████╗     ██████╗ ██████╗  ██████╗ 
████╗ ████║██║██╔══██╗╚══███╔╝██╔══██╗    ██╔══██╗██╔══██╗██╔═══██╗
██╔████╔██║██║██████╔╝  ███╔╝ ███████║    ██████╔╝██████╔╝██║   ██║
██║╚██╔╝██║██║██╔══██╗ ███╔╝  ██╔══██║    ██╔═══╝ ██╔══██╗██║   ██║
██║ ╚═╝ ██║██║██║  ██║███████╗██║  ██║    ██║     ██║  ██║╚██████╔╝
╚═╝     ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝
                    Version 3.4.1 - Ultimate
EOF
    echo -e "${NC}"
}

# --- Standard Functions ---
wait_for_apt() {
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}Waiting for apt locks...${NC}"
        sleep 5
    done
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9][-a-zA-Z0-9.]*\.[a-zA-Z]{2,}$ ]]
}

validate_bot_token() {
    [[ "$1" =~ ^[0-9]+:[A-Za-z0-9_-]{35,}$ ]]
}

# --- Core Functions ---
install_mirza() {
    mirza_logo
    echo -e "${CYAN}Starting Mirza Pro Installation${NC}\n"
    echo -e "1) Original Version (mahdiMGF2)"
    echo -e "2) Modified Version (Mmd-Amir)"
    read -p "Choice (1-2): " repo_choice
    REPO_URL="https://github.com/mahdiMGF2/mirza_pro.git"
    [ "$repo_choice" == "2" ] && REPO_URL="https://github.com/Mmd-Amir/mirza_pro.git"

    wait_for_apt
    apt-get install -y software-properties-common gnupg dnsutils openssl
    add-apt-repository ppa:ondrej/php -y && apt-get update

    read -p "Domain (bot.example.com): " DOMAIN
    read -p "Bot Token: " BOT_TOKEN
    read -p "Admin ID: " ADMIN_ID
    read -p "Bot Username (no @): " BOT_USERNAME
    read -p "New Marzban v1.0+? (y/n): " IS_NEW
    [[ "$IS_NEW" =~ ^[Yy]$ ]] && MARZBAN_VAL="true" || MARZBAN_VAL="false"

    DB_PASS=$(openssl rand -base64 16 | tr -d /=+)
    
    echo -e "${YELLOW}Installing Packages...${NC}"
    apt-get install -y apache2 mariadb-server git curl php8.2 libapache2-mod-php8.2 php8.2-{mysql,curl,mbstring,xml,zip,gd,bcmath} 2>/dev/null

    mysql -e "CREATE DATABASE IF NOT EXISTS mirzapro; GRANT ALL PRIVILEGES ON mirzapro.* TO 'mirza_user'@'localhost' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;"

    rm -rf "$MIRZA_PATH" && git clone "$REPO_URL" "$MIRZA_PATH"
    
    cat > "$MIRZA_CONFIG_FILE" <<EOF
<?php
if(!defined("index")) define("index", true);
\$dbname = 'mirzapro'; \$usernamedb = 'mirza_user'; \$passworddh = '$DB_PASS';
\$connect = mysqli_connect("localhost", \$usernamedb, \$passworddh, \$dbname);
\$APIKEY = '$BOT_TOKEN'; \$adminnumber = '$ADMIN_ID';
\$domainhosts = 'https://$DOMAIN'; \$usernamebot = '$BOT_USERNAME';
\$new_marzban = $MARZBAN_VAL;
?>
EOF

    cat > /etc/apache2/sites-available/mirzapro.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot $MIRZA_PATH
    <Directory $MIRZA_PATH>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
    a2ensite mirzapro.conf && a2dissite 000-default.conf && a2enmod rewrite ssl
    
    certbot --apache -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    systemctl restart apache2
    echo -e "${GREEN}✔ Mirza Pro Installed!${NC}"
    pause
}

delete_mirza() {
    mirza_logo
    read -p "Type 'DELETE' to confirm: " confirm
    if [ "$confirm" == "DELETE" ]; then
        a2dissite mirzapro.conf
        rm -rf "$MIRZA_PATH" /etc/apache2/sites-available/mirzapro.conf
        mysql -e "DROP DATABASE IF EXISTS mirzapro; DROP USER IF EXISTS 'mirza_user'@'localhost';"
        systemctl restart apache2
        echo -e "${GREEN}✔ Deleted successfully.${NC}"
    fi
    pause
}

update_mirza() {
    mirza_logo
    if [ -d "$MIRZA_PATH" ]; then
        cp "$MIRZA_CONFIG_FILE" /tmp/mirza_config.backup
        cd "$MIRZA_PATH" && git fetch origin && git reset --hard origin/main
        cp /tmp/mirza_config.backup "$MIRZA_CONFIG_FILE"
        systemctl restart apache2
        echo -e "${GREEN}✔ Updated successfully.${NC}"
    fi
    pause
}

backup_mirza() {
    mirza_logo
    local ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$MIRZA_BACKUP_PATH/$ts"
    cp -r "$MIRZA_PATH/." "$MIRZA_BACKUP_PATH/$ts/"
    echo -e "${GREEN}✔ Local backup created at $MIRZA_BACKUP_PATH/$ts${NC}"
    pause
}

view_logs_mirza() {
    mirza_logo
    echo -e "1. Apache Errors\n2. Manager History\n0. Back"
    read -p "Choice: " log_c
    case $log_c in
        1) tail -n 30 /var/log/apache2/error.log ;;
        2) tail -n 30 "$MIRZA_LOG_FILE" ;;
    esac
    pause
}

service_status_mirza() {
    mirza_logo
    systemctl is-active apache2 mariadb
    free -m | awk 'NR==2{printf "RAM: %s/%s MB\n", $3, $2}'
    pause
}

webhook_status() {
    mirza_logo
    TOKEN=$(grep -oE "[0-9]+:[A-Za-z0-9_-]{35,}" "$MIRZA_CONFIG_FILE")
    curl -s "https://api.telegram.org/bot$TOKEN/getWebhookInfo" | jq .
    pause
}

setup_telegram_backup_mirza() {
    mirza_logo
    echo "Enable Auto-Backup to Telegram?"
    read -p "(y/n): " cron_confirm
    if [[ "$cron_confirm" =~ ^[Yy]$ ]]; then
        read -p "Interval in hours (1-24): " b_interval
        CRON_TIME="0 */$b_interval * * *"
        [ "$b_interval" -eq 24 ] && CRON_TIME="0 0 * * *"
        # Assuming backup.php exists in mirza repo
        BACKUP_PHP=$(find "$MIRZA_PATH" -name "*backup*.php" | head -n 1)
        (crontab -l 2>/dev/null | grep -v "$BACKUP_PHP"; echo "$CRON_TIME /usr/bin/php $BACKUP_PHP") | crontab -
        echo -e "${GREEN}✔ Scheduled successfully.${NC}"
    fi
    pause
}

# --- Main Menu ---
mirza_menu() {
    while true; do
        clear
        mirza_logo
        echo -e "${YELLOW}      Mirza Pro Manager - Version 3.4.1${NC}\n"
        echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${WHITE}║  1.  Install Mirza Pro (2 Sources)                   ║${NC}"
        echo -e "${WHITE}║  2.  Delete Mirza Pro                                ║${NC}"
        echo -e "${WHITE}║  3.  Update Mirza Pro                                ║${NC}"
        echo -e "${WHITE}║  4.  Local Backup                                    ║${NC}"
        echo -e "${WHITE}║  5.  View Logs                                       ║${NC}"
        echo -e "${WHITE}║  6.  Service Status                                  ║${NC}"
        echo -e "${WHITE}║  7.  Restart Services                                ║${NC}"
        echo -e "${WHITE}║  8.  Edit config.php                                 ║${NC}"
        echo -e "${WHITE}║  9.  Webhook Status                                  ║${NC}"
        echo -e "${WHITE}║  10. Setup Telegram Auto-Backup                      ║${NC}"
        echo -e "${RED}║  0.  Back                                            ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n"
        read -p "Choose: " choice
        case $choice in
            1) install_mirza ;;
            2) delete_mirza ;;
            3) update_mirza ;;
            4) backup_mirza ;;
            5) view_logs_mirza ;;
            6) service_status_mirza ;;
            7) systemctl restart apache2 mariadb && echo "Done." && pause ;;
            8) nano "$MIRZA_CONFIG_FILE" && systemctl restart apache2 ;;
            9) webhook_status ;;
            10) setup_telegram_backup_mirza ;;
            0) return ;;
        esac
    done
}
