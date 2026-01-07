#!/bin/bash

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- Variables ---
MIRZA_PATH="/var/www/mirzapro"
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
                    Version 4.0.0 - Ultimate Edition
EOF
    echo -e "${NC}"
}

# --- Core Functions ---
install_mirza() {
    mirza_logo
    echo -e "${CYAN}Starting Mirza Pro Installation...${NC}\n"
    read -p "Domain (bot.example.com): " DOMAIN
    read -p "Bot Token: " BOT_TOKEN
    read -p "Admin ID: " ADMIN_ID
    read -p "Bot Username (no @): " BOT_USERNAME
    read -p "New Marzban v1.0+? (y/n): " IS_NEW
    [[ "$IS_NEW" =~ ^[Yy]$ ]] && MARZBAN_VAL="true" || MARZBAN_VAL="false"

    DB_PASS=$(openssl rand -base64 12 | tr -d /=+)

    echo -e "${YELLOW}Installing Packages...${NC}"
    apt-get update && apt-get install -y apache2 mariadb-server git curl php8.2 libapache2-mod-php8.2 php8.2-{mysql,curl,mbstring,xml,zip,gd,bcmath} jq certbot python3-certbot-apache 2>/dev/null

    mysql -e "CREATE DATABASE IF NOT EXISTS mirzapro; GRANT ALL PRIVILEGES ON mirzapro.* TO 'mirza_user'@'localhost' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;"

    rm -rf "$MIRZA_PATH" && git clone https://github.com/Mmd-Amir/mirza_pro.git "$MIRZA_PATH"

    cat > "$MIRZA_CONFIG_FILE" <<EOF
<?php
if(!defined("index")) define("index", true);
\$dbname = 'mirzapro'; \$usernamedb = 'mirza_user'; \$passworddb = '$DB_PASS';
\$connect = mysqli_connect("localhost", \$usernamedb, \$passworddb, \$dbname);
if (!\$connect) die("Database connection failed!");
mysqli_set_charset(\$connect, "utf8mb4");
try {
    \$pdo = new PDO("mysql:host=localhost;dbname=\$dbname;charset=utf8mb4", \$usernamedb, \$passworddb, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC
    ]);
} catch(Exception \$e) { die("PDO connection error"); }
\$APIKEY = '$BOT_TOKEN'; \$adminnumber = '$ADMIN_ID';
\$domainhosts = 'https://$DOMAIN'; \$usernamebot = '$BOT_USERNAME';
\$new_marzban = $MARZBAN_VAL;
?>
EOF

    chown -R www-data:www-data "$MIRZA_PATH"
    chmod -R 755 "$MIRZA_PATH"

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
    echo -e "${GREEN}✔ Mirza Pro Installed Successfully!${NC}"
    read -p "Press Enter to continue..."
}

update_mirza() {
    mirza_logo
    if [ -d "$MIRZA_PATH" ]; then
        cp "$MIRZA_CONFIG_FILE" /tmp/mirza_config.backup
        cd "$MIRZA_PATH" && git fetch origin && git reset --hard origin/main
        cp /tmp/mirza_config.backup "$MIRZA_CONFIG_FILE"
        chown -R www-data:www-data "$MIRZA_PATH"
        systemctl restart apache2
        echo -e "${GREEN}✔ Updated successfully.${NC}"
    else
        echo -e "${RED}Error: Mirza is not installed.${NC}"
    fi
    read -p "Press Enter to continue..."
}

remove_mirza() {
    mirza_logo
    read -p "Are you sure you want to DELETE everything? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        a2dissite mirzapro.conf
        rm -rf "$MIRZA_PATH" /etc/apache2/sites-available/mirzapro.conf
        mysql -e "DROP DATABASE IF EXISTS mirzapro; DROP USER IF EXISTS 'mirza_user'@'localhost';"
        (crontab -l 2>/dev/null | grep -v "$MIRZA_PATH") | crontab -
        systemctl restart apache2
        echo -e "${GREEN}✔ Mirza removed successfully.${NC}"
    fi
    read -p "Press Enter to continue..."
}

export_db() {
    mirza_logo
    if [ -f "$MIRZA_CONFIG_FILE" ]; then
        echo -e "${YELLOW}Exporting Database...${NC}"
        # استخراج اطلاعات از فایل کانفیگ
        DB_NAME=$(grep "\$dbname" "$MIRZA_CONFIG_FILE" | cut -d"'" -f2)
        DB_USER=$(grep "\$usernamedb" "$MIRZA_CONFIG_FILE" | cut -d"'" -f2)
        DB_PASS=$(grep "\$passworddb" "$MIRZA_CONFIG_FILE" | cut -d"'" -f2)
        
        # خروجی گرفتن
        mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$MIRZA_PATH/mirzapro_backup.sql"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✔ Database exported successfully!${NC}"
            echo -e "${CYAN}Location: $MIRZA_PATH/mirzapro_backup.sql${NC}"
        else
            echo -e "${RED}❌ Export failed! Please check database credentials.${NC}"
        fi
    else
        echo -e "${RED}Error: Config file not found!${NC}"
    fi
    read -p "Press Enter to continue..."
}

import_db() {
    mirza_logo
    echo -e "${CYAN}--- Import Database ---${NC}"
    read -p "Enter full path to your .sql file (e.g. /root/backup.sql): " SQL_PATH
    
    if [ -f "$SQL_PATH" ]; then
        # استخراج اطلاعات دیتابیس
        DB_NAME=$(grep "\$dbname" "$MIRZA_CONFIG_FILE" | cut -d"'" -f2)
        DB_USER=$(grep "\$usernamedb" "$MIRZA_CONFIG_FILE" | cut -d"'" -f2)
        DB_PASS=$(grep "\$passworddb" "$MIRZA_CONFIG_FILE" | cut -d"'" -f2)

        echo -e "${YELLOW}Preparing database...${NC}"
        # اطمینان از وجود دیتابیس (اگر نبود می‌سازد)
        mysql -u root -e "CREATE DATABASE IF NOT EXISTS $DB_NAME; GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"

        echo -e "${YELLOW}Importing data...${NC}"
        # ایمپورت دیتابیس
        mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_PATH"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✔ Database imported successfully!${NC}"
        else
            echo -e "${RED}❌ Import failed! Check if the SQL file is valid.${NC}"
        fi
    else
        echo -e "${RED}Error: SQL file not found at $SQL_PATH${NC}"
    fi
    read -p "Press Enter to continue..."
}
configure_backup() {
    mirza_logo
    echo -e "${CYAN}Setting up Telegram Auto-Backup...${NC}"
    read -p "Interval in hours (e.g. 12): " b_interval
    BACKUP_PHP=$(find "$MIRZA_PATH" -name "*backup*.php" | head -n 1)
    if [ -n "$BACKUP_PHP" ]; then
        DIR_PATH=$(dirname "$BACKUP_PHP")
        FILE_NAME=$(basename "$BACKUP_PHP")
        (crontab -l 2>/dev/null | grep -v "$FILE_NAME"; echo "0 */$b_interval * * * cd $DIR_PATH && /usr/bin/php $FILE_NAME > /dev/null 2>&1") | crontab -
        echo -e "${GREEN}✔ Backup scheduled every $b_interval hours.${NC}"
    else
        echo -e "${RED}Backup file not found in repo!${NC}"
    fi
    read -p "Press Enter to continue..."
}

renew_ssl() {
    mirza_logo
    echo -e "${YELLOW}Renewing SSL Certificates...${NC}"
    certbot renew --apache
    systemctl restart apache2
    echo -e "${GREEN}✔ SSL Renew process completed.${NC}"
    read -p "Press Enter to continue..."
}

change_domain() {
    mirza_logo
    read -p "Enter New Domain: " NEW_DOMAIN
    sed -i "s|https://.*'|https://$NEW_DOMAIN'|g" "$MIRZA_CONFIG_FILE"
    OLD_DOMAIN=$(grep "ServerName" /etc/apache2/sites-available/mirzapro.conf | awk '{print $2}')
    sed -i "s/$OLD_DOMAIN/$NEW_DOMAIN/g" /etc/apache2/sites-available/mirzapro.conf
    certbot --apache -d "$NEW_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    systemctl restart apache2
    echo -e "${GREEN}✔ Domain changed to $NEW_DOMAIN${NC}"
    read -p "Press Enter to continue..."
}

additional_mgmt() {
    mirza_logo
    echo -e "1) View Logs\n2) Service Status\n3) Webhook Info\n0) Back"
    read -p "Choice: " am_choice
    case $am_choice in
        1) tail -n 50 /var/log/apache2/error.log | less ;;
        2) systemctl status apache2 mariadb ;;
        3) 
           TOKEN=$(grep "APIKEY" "$MIRZA_CONFIG_FILE" | cut -d"'" -f2)
           curl -s "https://api.telegram.org/bot$TOKEN/getWebhookInfo" | jq .
           read -p "Press Enter..."
           ;;
    esac
}

migration_server() {
    mirza_logo
    echo -e "${YELLOW}Immigration (Migration) Guide:${NC}"
    echo -e "1. Export Database on OLD server (Option 4)"
    echo -e "2. Install Mirza on NEW server (Option 1)"
    echo -e "3. Import Database on NEW server (Option 5)"
    echo -e "4. Copy 'data' folder from old to new /var/www/mirzapro/"
    read -p "Press Enter to continue..."
}

remove_domain() {
    mirza_logo
    a2dissite mirzapro.conf
    rm /etc/apache2/sites-available/mirzapro.conf
    systemctl restart apache2
    echo -e "${GREEN}✔ Domain configuration removed.${NC}"
    read -p "Press Enter to continue..."
}

delete_crons() {
    mirza_logo
    crontab -r
    echo -e "${GREEN}✔ All Cron Jobs deleted.${NC}"
    read -p "Press Enter to continue..."
}

# --- Main Menu Function ---
mirza_menu() {
    while true; do
        mirza_logo
        echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
        echo -e "${WHITE}║            MIRZA PRO - MAIN MENU               ║${NC}"
        echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
        echo -e "║                                                ║"
        echo -e "║ 1)  Install Mirza Bot                          ║"
        echo -e "║ 2)  Update Mirza Bot                           ║"
        echo -e "║ 3)  Remove Mirza Bot                           ║"
        echo -e "║ 4)  Export Database                            ║"
        echo -e "║ 5)  Import Database                            ║"
        echo -e "║ 6)  Configure Automated Backup                 ║"
        echo -e "║ 7)  Renew SSL Certificates                     ║"
        echo -e "║ 8)  Change Domain                              ║"
        echo -e "║ 9)  Additional Bot Management                  ║"
        echo -e "║ 10) Immigration (Server Migration)             ║"
        echo -e "║ 11) Remove Domain                              ║"
        echo -e "║ 12) Delete Cron Jobs                           ║"
        echo -e "║ 13) Exit                                       ║"
        echo -e "║                                                ║"
        echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
        read -p "❯ Select an option [1-13]: " choice

        case $choice in
            1) install_mirza ;;
            2) update_mirza ;;
            3) remove_mirza ;;
            4) export_db ;;
            5) import_db ;;
            6) configure_backup ;;
            7) renew_ssl ;;
            8) change_domain ;;
            9) additional_mgmt ;;
            10) migration_server ;;
            11) remove_domain ;;
            12) delete_crons ;;
            13) return ;;
            *) echo -e "${RED}Invalid Option!${NC}" && sleep 1 ;;
        esac
    done
}
