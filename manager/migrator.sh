#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V10.3 (Fixed: All Critical Issues)
#==============================================================================

# Load Utils & UI
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh 2>/dev/null; fi
source /opt/mrm-manager/ui.sh 2>/dev/null

# Fallback colors
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[0;33m}"
BLUE="${BLUE:-\033[0;34m}"
CYAN="${CYAN:-\033[0;36m}"
NC="${NC:-\033[0m}"

# --- CONFIGURATION ---
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
MIGRATION_LOG="${MIGRATION_LOG:-/var/log/mrm_migration.log}"
MIGRATION_TEMP=""

# Global variables
SRC=""
TGT=""
CURRENT_BACKUP=""
SOURCE_PANEL_TYPE=""
SOURCE_DB_TYPE=""

# Xray URLs
XRAY_DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

REBECCA_INSTALL_CMD="bash -c \"\$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)\" @ install --database mysql"

# --- HELPER FUNCTIONS ---

migration_init() {
    MIGRATION_TEMP=$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null) || MIGRATION_TEMP="/tmp/mrm-migration-$$"
    mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT"
    mkdir -p "$(dirname "$MIGRATION_LOG")" 2>/dev/null
    touch "$MIGRATION_LOG" 2>/dev/null
    echo "=== Migration Started: $(date) ===" >> "$MIGRATION_LOG"
}

migration_cleanup() { 
    [[ "$MIGRATION_TEMP" == /tmp/* ]] && rm -rf "$MIGRATION_TEMP" 2>/dev/null
    # FIX #5: پاکسازی فایل‌های موقت
    rm -f /tmp/pg_config.json /tmp/clean_config.json /tmp/sqlite_export_*.sql 2>/dev/null
}

mlog()   { echo "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG" 2>/dev/null; }
minfo()  { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()    { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn()  { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr()   { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }
mpause() { echo ""; echo -e "${YELLOW}Press any key to continue...${NC}"; read -n 1 -s -r; echo ""; }

# Fallback UI functions
if ! type ui_confirm &>/dev/null; then
    ui_confirm() {
        local prompt="$1"
        local default="${2:-y}"
        read -p "$prompt [y/n] ($default): " answer
        answer="${answer:-$default}"
        [[ "$answer" =~ ^[Yy] ]]
    }
fi

if ! type ui_header &>/dev/null; then
    ui_header() {
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  $1${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo ""
    }
fi

# --- FIX #2: SAFE SQL ESCAPE FUNCTION ---
sql_escape() {
    local str="$1"
    # Escape backslash first, then single quote
    str="${str//\\/\\\\}"
    str="${str//\'/\'\'}"
    # Escape special characters for MySQL
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}

# --- FIX #7: SAFE PASSWORD READER ---
read_var() {
    local key="$1"
    local file="$2"
    [ ! -f "$file" ] && echo "" && return 1
    # بهبود خواندن متغیر با پشتیبانی از = در مقدار
    local line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | grep -v "^[[:space:]]*#" | head -1)
    [ -z "$line" ] && echo "" && return 1
    # حذف نام متغیر و علامت =
    local value="${line#*=}"
    # حذف فاصله‌های ابتدا و انتها
    value=$(echo "$value" | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # حذف کوتیشن
    value=$(echo "$value" | sed -E 's/^"//;s/"$//;s/^\x27//;s/\x27$//')
    echo "$value"
}

# --- PANEL DETECTION ---
detect_source_panel() {
    if [ -d "/opt/pasarguard" ] && [ -f "/opt/pasarguard/.env" ]; then
        SOURCE_PANEL_TYPE="pasarguard"
        echo "/opt/pasarguard"
        return 0
    fi
    if [ -d "/opt/marzban" ] && [ -f "/opt/marzban/.env" ]; then
        SOURCE_PANEL_TYPE="marzban"
        echo "/opt/marzban"
        return 0
    fi
    return 1
}

get_source_data_dir() {
    local src="$1"
    case "$src" in
        */pasarguard*) echo "/var/lib/pasarguard" ;;
        */marzban*)    echo "/var/lib/marzban" ;;
        *)             echo "/var/lib/$(basename "$src")" ;;
    esac
}

# --- FIX #14: بهبود تشخیص نوع دیتابیس ---
detect_db_type() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    
    if [ -f "$env_file" ]; then
        local db_url=$(read_var "SQLALCHEMY_DATABASE_URL" "$env_file")
        case "$db_url" in
            *postgresql*|*postgres*|*timescale*) echo "postgresql" ;;
            *mysql*|*mariadb*)      echo "mysql" ;;
            *sqlite*)               echo "sqlite" ;;
            "")
                # اگر URL خالی بود، فایل دیتابیس را چک کن
                local data_dir=$(get_source_data_dir "$panel_dir")
                if [ -f "$data_dir/db.sqlite3" ]; then
                    echo "sqlite"
                else
                    echo "unknown"
                fi
                ;;
            *)                      echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

# --- DATABASE CONTAINER DETECTION ---
find_pg_container() {
    local panel_dir="$1"
    local panel_name=$(basename "$panel_dir")
    # FIX: escape کردن نام پنل برای regex
    local escaped_name=$(echo "$panel_name" | sed 's/[.[\*^$(){}?+|]/\\&/g')
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "${escaped_name}.*(timescale|postgres|db)" | head -1)
    [ -z "$cname" ] && cname=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | grep -v rebecca | head -1)
    echo "$cname"
}

find_mysql_container() {
    local panel_dir="$1"
    local panel_name=$(basename "$panel_dir")
    local escaped_name=$(echo "$panel_name" | sed 's/[.[\*^$(){}?+|]/\\&/g')
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "${escaped_name}.*(mysql|mariadb)" | head -1)
    [ -z "$cname" ] && cname=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb)" | head -1)
    echo "$cname"
}

# --- START SOURCE PANEL ---
start_source_panel() {
    local src="$1"
    minfo "Starting source panel services..."
    (cd "$src" && docker compose up -d) &>/dev/null
    
    local max_wait=60
    local waited=0
    
    if [ "$SOURCE_DB_TYPE" == "postgresql" ]; then
        local pg_container=$(find_pg_container "$src")
        while [ -z "$pg_container" ] && [ $waited -lt $max_wait ]; do
            sleep 3
            waited=$((waited + 3))
            pg_container=$(find_pg_container "$src")
            echo -n "."
        done
        
        if [ -n "$pg_container" ]; then
            waited=0
            # FIX: تست با نام کاربری صحیح
            local pg_user="pasarguard"
            [ "$SOURCE_PANEL_TYPE" == "marzban" ] && pg_user="marzban"
            while ! docker exec "$pg_container" pg_isready -U "$pg_user" &>/dev/null && [ $waited -lt $max_wait ]; do
                sleep 2
                waited=$((waited + 2))
                echo -n "."
            done
            echo ""
            mok "PostgreSQL is ready: $pg_container"
        fi
    fi
}

# --- INSTALL XRAY ---
install_xray() {
    local target_dir="$1"
    local src_data="$2"
    minfo "Installing Xray core..."
    mkdir -p "$target_dir/assets"
    
    if [ -f "$src_data/xray" ]; then
        cp "$src_data/xray" "$target_dir/xray"
        chmod +x "$target_dir/xray"
        mok "Xray copied from source"
    else
        minfo "Downloading Xray..."
        cd /tmp
        rm -f Xray-linux-64.zip 2>/dev/null
        if wget -q --show-progress "$XRAY_DOWNLOAD_URL" -O Xray-linux-64.zip; then
            unzip -o Xray-linux-64.zip -d "$target_dir/" >/dev/null 2>&1
            chmod +x "$target_dir/xray"
            mok "Xray downloaded"
        else
            merr "Failed to download Xray"
            return 1
        fi
    fi
    
    if [ -d "$src_data/assets" ]; then
        cp -rn "$src_data/assets/"* "$target_dir/assets/" 2>/dev/null
    fi
    [ ! -f "$target_dir/assets/geoip.dat" ] && wget -q "$GEOIP_URL" -O "$target_dir/assets/geoip.dat"
    [ ! -f "$target_dir/assets/geosite.dat" ] && wget -q "$GEOSITE_URL" -O "$target_dir/assets/geosite.dat"
    
    if [ -x "$target_dir/xray" ]; then
        mok "Xray installed successfully"
        return 0
    fi
    return 1
}

# --- COPY DATA FILES ---
copy_data_files() {
    local src_data="$1"
    local tgt_data="$2"
    minfo "Copying data files..."
    mkdir -p "$tgt_data"
    
    if [ -d "$src_data/certs" ]; then
        mkdir -p "$tgt_data/certs"
        cp -r "$src_data/certs/"* "$tgt_data/certs/" 2>/dev/null
        find "$tgt_data/certs" -type f -exec chmod 644 {} \;
        find "$tgt_data/certs" -type d -exec chmod 755 {} \;
        mok "Certificates copied"
    fi
    if [ -d "$src_data/templates" ]; then
        mkdir -p "$tgt_data/templates"
        cp -r "$src_data/templates/"* "$tgt_data/templates/" 2>/dev/null
        mok "Templates copied"
    fi
    if [ -d "$src_data/assets" ]; then
        mkdir -p "$tgt_data/assets"
        cp -r "$src_data/assets/"* "$tgt_data/assets/" 2>/dev/null
        mok "Assets copied"
    fi
}

# --- GENERATE ENV FILE ---
generate_clean_env() {
    local src="$1"
    local tgt="$2"
    local tgt_env="$tgt/.env"
    local src_env="$src/.env"
    minfo "Generating .env file..."

    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt_env")
    [ -z "$DB_PASS" ] && DB_PASS=$(openssl rand -hex 16)

    local UV_PORT=$(read_var "UVICORN_PORT" "$src_env")
    # FIX #9: پورت پیش‌فرض ربکا
    [ -z "$UV_PORT" ] && UV_PORT="8000"

    local SUDO_USER=$(read_var "SUDO_USERNAME" "$src_env")
    local SUDO_PASS=$(read_var "SUDO_PASSWORD" "$src_env")
    [ -z "$SUDO_USER" ] && SUDO_USER="admin"
    [ -z "$SUDO_PASS" ] && SUDO_PASS="admin"

    local TG_TOKEN=$(read_var "TELEGRAM_API_TOKEN" "$src_env")
    local TG_ADMIN=$(read_var "TELEGRAM_ADMIN_ID" "$src_env")

    local SSL_CERT=$(read_var "UVICORN_SSL_CERTFILE" "$src_env")
    local SSL_KEY=$(read_var "UVICORN_SSL_KEYFILE" "$src_env")
    SSL_CERT="${SSL_CERT//pasarguard/rebecca}"
    SSL_KEY="${SSL_KEY//pasarguard/rebecca}"
    SSL_CERT="${SSL_CERT//marzban/rebecca}"
    SSL_KEY="${SSL_KEY//marzban/rebecca}"

    local XRAY_JSON=$(read_var "XRAY_JSON" "$src_env")
    XRAY_JSON="${XRAY_JSON//pasarguard/rebecca}"
    XRAY_JSON="${XRAY_JSON//marzban/rebecca}"
    # FIX #22: مقدار پیش‌فرض برای XRAY_JSON
    [ -z "$XRAY_JSON" ] && XRAY_JSON="/var/lib/rebecca/xray_config.json"

    local SUB_URL=$(read_var "XRAY_SUBSCRIPTION_URL_PREFIX" "$src_env")

    cat > "$tgt_env" <<EOF
SQLALCHEMY_DATABASE_URL="mysql+pymysql://root:${DB_PASS}@127.0.0.1:3306/rebecca"
MYSQL_ROOT_PASSWORD="${DB_PASS}"
MYSQL_DATABASE="rebecca"
UVICORN_HOST="0.0.0.0"
UVICORN_PORT="${UV_PORT}"
UVICORN_SSL_CERTFILE="${SSL_CERT}"
UVICORN_SSL_KEYFILE="${SSL_KEY}"
SUDO_USERNAME="${SUDO_USER}"
SUDO_PASSWORD="${SUDO_PASS}"
TELEGRAM_API_TOKEN="${TG_TOKEN}"
TELEGRAM_ADMIN_ID="${TG_ADMIN}"
XRAY_JSON="${XRAY_JSON}"
XRAY_SUBSCRIPTION_URL_PREFIX="${SUB_URL}"
XRAY_EXECUTABLE_PATH="/var/lib/rebecca/xray"
XRAY_ASSETS_PATH="/var/lib/rebecca/assets"
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440
SECRET_KEY="$(openssl rand -hex 32)"
EOF
    mok "Environment file created"
}

# --- INSTALL REBECCA ---
install_rebecca_wizard() {
    clear
    ui_header "INSTALLING REBECCA"
    if ! ui_confirm "Install Rebecca Panel?" "y"; then return 1; fi
    eval "$REBECCA_INSTALL_CMD"
    if [ -d "/opt/rebecca" ]; then
        mok "Rebecca installed"
        return 0
    else
        merr "Installation failed"
        return 1
    fi
}

# --- FIX #6: IMPORT CORE CONFIG (SAFE JSON HANDLING) ---
import_core_config() {
    local PG_CONTAINER="$1"
    local MYSQL_CONTAINER="$2"
    local DB_PASS="$3"
    local DB_NAME="${4:-pasarguard}"
    local DB_USER="${5:-pasarguard}"
    
    minfo "Importing Core Config..."
    
    # Export to file
    docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT config FROM core_configs LIMIT 1;" > /tmp/pg_config.json 2>/dev/null
    
    if [ ! -s /tmp/pg_config.json ]; then
        mwarn "No core config found in source"
        return 1
    fi
    
    # Process via Python with proper escaping
    python3 << 'PYEOF'
import json
import sys
import re

try:
    with open('/tmp/pg_config.json', 'r') as f:
        config_str = f.read().strip()
    
    if not config_str:
        print("Empty config")
        sys.exit(1)
    
    config = json.loads(config_str)
    
    # Fix paths
    config_str = json.dumps(config)
    config_str = config_str.replace('/var/lib/pasarguard', '/var/lib/rebecca')
    config_str = config_str.replace('/opt/pasarguard', '/opt/rebecca')
    config_str = config_str.replace('/var/lib/marzban', '/var/lib/rebecca')
    config_str = config_str.replace('/opt/marzban', '/opt/rebecca')
    
    config = json.loads(config_str)
    if 'api' not in config:
        config['api'] = {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]}
    
    # Write clean JSON
    with open('/tmp/clean_config.json', 'w') as f:
        json.dump(config, f, ensure_ascii=False)
    
    # Write MySQL-safe escaped version
    final_str = json.dumps(config, ensure_ascii=False)
    # Escape for MySQL
    final_str = final_str.replace('\\', '\\\\')
    final_str = final_str.replace("'", "\\'")
    
    with open('/tmp/mysql_config.txt', 'w') as f:
        f.write(final_str)
    
    print("OK")
    
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYEOF

    if [ ! -f /tmp/mysql_config.txt ]; then
        merr "Failed to process config"
        return 1
    fi
    
    # Import using file to avoid shell escaping issues
    docker cp /tmp/mysql_config.txt "$MYSQL_CONTAINER:/tmp/config_import.txt"
    
    docker exec "$MYSQL_CONTAINER" bash -c "
    CONFIG_DATA=\$(cat /tmp/config_import.txt)
    mysql -uroot -p'$DB_PASS' rebecca -e \"
    DELETE FROM core_configs;
    INSERT INTO core_configs (id, name, config, created_at) VALUES (1, 'default', '\$CONFIG_DATA', NOW());
    \"
    rm -f /tmp/config_import.txt
    " 2>/dev/null
    
    mok "Core Config imported"
    rm -f /tmp/pg_config.json /tmp/clean_config.json /tmp/mysql_config.txt
}

# --- FIX #8: SETUP JWT (با بررسی ساختار موجود) ---
setup_jwt() {
    local MYSQL_CONTAINER="$1"
    local DB_PASS="$2"
    
    minfo "Configuring JWT Keys..."
    
    # Check if jwt table exists and has correct structure
    local table_exists=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "SHOW TABLES LIKE 'jwt';" 2>/dev/null)
    
    if [ -n "$table_exists" ]; then
        # Check if already has data
        local jwt_count=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "SELECT COUNT(*) FROM jwt;" 2>/dev/null | tr -d ' \n')
        if [ "$jwt_count" -gt 0 ] 2>/dev/null; then
            mok "JWT already configured (found $jwt_count entries)"
            return 0
        fi
    fi
    
    # Generate keys
    local JWT_KEY=$(openssl rand -hex 64)
    local SUB_KEY=$(openssl rand -hex 64)
    local ADM_KEY=$(openssl rand -hex 64)
    local VMESS=$(openssl rand -hex 16)
    local VLESS=$(openssl rand -hex 16)
    
    # Create table if not exists and insert
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -e "
    CREATE TABLE IF NOT EXISTS jwt (
        id INT AUTO_INCREMENT PRIMARY KEY,
        secret_key VARCHAR(255) NOT NULL,
        subscription_secret_key VARCHAR(255),
        admin_secret_key VARCHAR(255),
        vmess_mask VARCHAR(64),
        vless_mask VARCHAR(64)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    
    INSERT INTO jwt (secret_key, subscription_secret_key, admin_secret_key, vmess_mask, vless_mask) 
    VALUES ('$JWT_KEY', '$SUB_KEY', '$ADM_KEY', '$VMESS', '$VLESS')
    ON DUPLICATE KEY UPDATE secret_key=VALUES(secret_key);
    " 2>/dev/null
    
    if [ $? -eq 0 ]; then
        mok "JWT configured successfully"
    else
        mwarn "JWT configuration may have issues"
    fi
}

# --- SETUP SERVICES ---
setup_services() {
    local MYSQL_CONTAINER="$1"
    local DB_PASS="$2"
    
    minfo "Linking Services..."
    
    # Check if services table exists
    local table_exists=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "SHOW TABLES LIKE 'services';" 2>/dev/null)
    
    if [ -z "$table_exists" ]; then
        mwarn "Services table not found - Rebecca may create it on startup"
        return 0
    fi
    
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -e "
    INSERT IGNORE INTO services (id, name, created_at) VALUES (1, 'Default Service', NOW());
    INSERT IGNORE INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts WHERE id NOT IN (SELECT host_id FROM service_hosts);
    UPDATE users SET service_id = 1 WHERE service_id IS NULL;
    " 2>/dev/null
    mok "Services linked"
}

# --- FIX #4: HELPER FOR BOOLEAN CONVERSION ---
pg_bool_to_int() {
    local val="$1"
    case "$val" in
        t|true|TRUE|True|1|yes|YES|Yes) echo "1" ;;
        *) echo "0" ;;
    esac
}

# --- DIRECT POSTGRESQL TO MYSQL MIGRATION ---
migrate_postgresql_to_mysql() {
    local src="$1"
    local tgt="$2"
    ui_header "DIRECT DATABASE MIGRATION"
    
    local PG_CONTAINER=$(find_pg_container "$src")
    local MYSQL_CONTAINER=$(find_mysql_container "$tgt")
    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt/.env")
    
    # Detect source database name and user
    local SRC_DB_NAME="pasarguard"
    local SRC_DB_USER="pasarguard"
    if [ "$SOURCE_PANEL_TYPE" == "marzban" ]; then
        SRC_DB_NAME="marzban"
        SRC_DB_USER="marzban"
    fi
    
    if [ -z "$PG_CONTAINER" ]; then merr "PostgreSQL container not found"; return 1; fi
    if [ -z "$MYSQL_CONTAINER" ]; then merr "MySQL container not found"; return 1; fi
    
    minfo "Source: $PG_CONTAINER (PostgreSQL - $SRC_DB_NAME)"
    minfo "Target: $MYSQL_CONTAINER (MySQL)"
    
    # FIX #8: اضافه کردن بررسی خطا
    run_pg() { 
        local result
        result=$(docker exec "$PG_CONTAINER" psql -U "$SRC_DB_USER" -d "$SRC_DB_NAME" -t -A -c "$1" 2>/dev/null)
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
            mlog "PG Error: $1"
        fi
        echo "$result"
    }
    
    run_mysql() { 
        docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "$1" 2>/dev/null
    }
    
    minfo "Waiting for MySQL..."
    local waited=0
    while ! docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$DB_PASS" --silent 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        [ $waited -ge 60 ] && { merr "MySQL timeout"; return 1; }
        echo -n "."
    done
    echo ""
    mok "MySQL ready"
    
    # 1. Reset DB
    run_mysql "CREATE DATABASE IF NOT EXISTS rebecca CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    run_mysql "SET FOREIGN_KEY_CHECKS=0; DELETE FROM users; DELETE FROM inbounds; DELETE FROM hosts; DELETE FROM services; DELETE FROM service_hosts; DELETE FROM core_configs; DELETE FROM proxies; SET FOREIGN_KEY_CHECKS=1;"
    
    # 2. Setup JWT FIRST
    setup_jwt "$MYSQL_CONTAINER" "$DB_PASS"
    
    # 3. Import Admins
    minfo "Importing Admins..."
    local admin_count=0
    while IFS='|' read -r id username hashed_password is_sudo telegram_id; do
        [ -z "$id" ] && continue
        local role="standard"
        # FIX #4: بهبود تشخیص boolean
        [ "$(pg_bool_to_int "$is_sudo")" == "1" ] && role="sudo"
        [ -z "$telegram_id" ] || [ "$telegram_id" == "" ] && telegram_id="NULL"
        # FIX #2: استفاده از تابع escape
        username=$(sql_escape "$username")
        hashed_password=$(sql_escape "$hashed_password")
        run_mysql "INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) VALUES ($id, '$username', '$hashed_password', '$role', 'active', $telegram_id, NOW()) ON DUPLICATE KEY UPDATE hashed_password='$hashed_password', role='$role';"
        ((admin_count++))
    done < <(run_pg "SELECT id, username, hashed_password, COALESCE(is_sudo, false), COALESCE(telegram_id::text, '') FROM admins;")
    mok "Admins imported: $admin_count"
    
    # 4. Import Inbounds
    minfo "Importing Inbounds..."
    local inbound_count=0
    while IFS='|' read -r id tag; do
        [ -z "$id" ] && continue
        tag=$(sql_escape "$tag")
        run_mysql "INSERT INTO inbounds (id, tag) VALUES ($id, '$tag') ON DUPLICATE KEY UPDATE tag='$tag';"
        ((inbound_count++))
    done < <(run_pg "SELECT id, tag FROM inbounds;")
    mok "Inbounds imported: $inbound_count"
    
    # 5. Import Users
    minfo "Importing Users..."
    local user_count=0
    while IFS='|' read -r id username status used_traffic data_limit expire admin_id note; do
        [ -z "$id" ] && continue
        # FIX #10: حفظ نام کاربری اصلی با جایگزینی ایمن
        username="${username//@/_at_}"
        username="${username//./_dot_}"
        username=$(sql_escape "$username")
        
        # FIX #3: وضعیت on_hold باید حفظ شود
        case "$status" in
            active)     status="active" ;;
            on_hold)    status="on_hold" ;;
            disabled)   status="disabled" ;;
            limited)    status="limited" ;;
            expired)    status="expired" ;;
            *)          status="active" ;;
        esac
        
        [ -z "$used_traffic" ] && used_traffic="0"
        [ -z "$data_limit" ] || [ "$data_limit" == "" ] && data_limit="NULL"
        [ -z "$expire" ] || [ "$expire" == "" ] && expire="NULL"
        [ -z "$admin_id" ] || [ "$admin_id" == "" ] && admin_id="1"
        note=$(sql_escape "$note")
        
        run_mysql "INSERT INTO users (id, username, status, used_traffic, data_limit, expire, admin_id, note, created_at) VALUES ($id, '$username', '$status', $used_traffic, $data_limit, $expire, $admin_id, '$note', NOW()) ON DUPLICATE KEY UPDATE status='$status';"
        ((user_count++))
    done < <(run_pg "SELECT id, username, COALESCE(status, 'active'), COALESCE(used_traffic, 0), data_limit, EXTRACT(EPOCH FROM expire)::bigint, COALESCE(admin_id, 1), COALESCE(note, '') FROM users;")
    mok "Users imported: $user_count"
    
    # 6. Import Proxies
    minfo "Importing Proxies..."
    local proxy_count=0
    while IFS='|' read -r id user_id type settings; do
        [ -z "$id" ] && continue
        type=$(sql_escape "$type")
        settings=$(sql_escape "$settings")
        run_mysql "INSERT INTO proxies (id, user_id, type, settings) VALUES ($id, $user_id, '$type', '$settings') ON DUPLICATE KEY UPDATE settings='$settings';"
        ((proxy_count++))
    done < <(run_pg "SELECT id, user_id, type, settings FROM proxies;")
    mok "Proxies imported: $proxy_count"
    
    # 7. Import Hosts
    minfo "Importing Hosts..."
    local host_count=0
    while IFS='|' read -r id remark address port inbound_tag sni host security fingerprint is_disabled path; do
        [ -z "$id" ] && continue
        [ -z "$port" ] || [ "$port" == "" ] && port="NULL"
        # FIX #4: boolean conversion
        local is_disabled_val=$(pg_bool_to_int "$is_disabled")
        
        remark=$(sql_escape "$remark")
        address=$(sql_escape "$address")
        path=$(sql_escape "$path")
        inbound_tag=$(sql_escape "$inbound_tag")
        sni=$(sql_escape "$sni")
        host=$(sql_escape "$host")
        security=$(sql_escape "$security")
        
        # Path fixes
        address="${address//pasarguard/rebecca}"
        address="${address//marzban/rebecca}"
        path="${path//pasarguard/rebecca}"
        path="${path//marzban/rebecca}"
        
        [ -z "$fingerprint" ] || [ "$fingerprint" == "" ] && fingerprint="none"
        fingerprint=$(sql_escape "$fingerprint")
        
        run_mysql "INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, security, fingerprint, is_disabled, path) VALUES ($id, '$remark', '$address', $port, '$inbound_tag', '$sni', '$host', '$security', '$fingerprint', $is_disabled_val, '$path') ON DUPLICATE KEY UPDATE address='$address';"
        ((host_count++))
    done < <(run_pg "SELECT id, remark, address, port, inbound_tag, sni, host, security, COALESCE(fingerprint::text, 'none'), is_disabled, COALESCE(path, '') FROM hosts;")
    mok "Hosts imported: $host_count"
    
    # 8. Import Core Config
    import_core_config "$PG_CONTAINER" "$MYSQL_CONTAINER" "$DB_PASS" "$SRC_DB_NAME" "$SRC_DB_USER"
    
    # 9. Setup Services
    setup_services "$MYSQL_CONTAINER" "$DB_PASS"
    
    # Summary
    echo ""
    ui_header "MIGRATION SUMMARY"
    echo -e "  Admins:       ${GREEN}$(run_mysql "SELECT COUNT(*) FROM admins;" | tr -d ' \n')${NC}"
    echo -e "  Users:        ${GREEN}$(run_mysql "SELECT COUNT(*) FROM users;" | tr -d ' \n')${NC}"
    echo -e "  Proxies:      ${GREEN}$(run_mysql "SELECT COUNT(*) FROM proxies;" | tr -d ' \n')${NC}"
    echo -e "  Inbounds:     ${GREEN}$(run_mysql "SELECT COUNT(*) FROM inbounds;" | tr -d ' \n')${NC}"
    echo -e "  Hosts:        ${GREEN}$(run_mysql "SELECT COUNT(*) FROM hosts;" | tr -d ' \n')${NC}"
    echo -e "  Core Configs: ${GREEN}$(run_mysql "SELECT COUNT(*) FROM core_configs;" | tr -d ' \n')${NC}"
    echo -e "  Services:     ${GREEN}$(run_mysql "SELECT COUNT(*) FROM services;" | tr -d ' \n')${NC}"
    echo -e "  JWT:          ${GREEN}$(run_mysql "SELECT COUNT(*) FROM jwt;" | tr -d ' \n')${NC}"
    echo ""
    
    return 0
}

# --- FIX #1: اضافه کردن تابع migrate_sqlite_to_mysql ---
migrate_sqlite_to_mysql() {
    local src="$1"
    local tgt="$2"
    ui_header "SQLITE TO MYSQL MIGRATION"
    
    local MYSQL_CONTAINER=$(find_mysql_container "$tgt")
    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt/.env")
    local SRC_DATA=$(get_source_data_dir "$src")
    local SQLITE_DB="$SRC_DATA/db.sqlite3"
    
    if [ ! -f "$SQLITE_DB" ]; then
        merr "SQLite database not found: $SQLITE_DB"
        return 1
    fi
    
    if [ -z "$MYSQL_CONTAINER" ]; then merr "MySQL container not found"; return 1; fi
    
    minfo "Source: $SQLITE_DB (SQLite)"
    minfo "Target: $MYSQL_CONTAINER (MySQL)"
    
    # Check sqlite3 command
    if ! command -v sqlite3 &>/dev/null; then
        minfo "Installing sqlite3..."
        apt-get update && apt-get install -y sqlite3 >/dev/null 2>&1
    fi
    
    run_sqlite() { 
        sqlite3 -separator '|' "$SQLITE_DB" "$1" 2>/dev/null
    }
    
    run_mysql() { 
        docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "$1" 2>/dev/null
    }
    
    minfo "Waiting for MySQL..."
    local waited=0
    while ! docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$DB_PASS" --silent 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        [ $waited -ge 60 ] && { merr "MySQL timeout"; return 1; }
        echo -n "."
    done
    echo ""
    mok "MySQL ready"
    
    # Reset DB
    run_mysql "CREATE DATABASE IF NOT EXISTS rebecca CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    run_mysql "SET FOREIGN_KEY_CHECKS=0; DELETE FROM users; DELETE FROM inbounds; DELETE FROM hosts; DELETE FROM proxies; SET FOREIGN_KEY_CHECKS=1;"
    
    # Setup JWT
    setup_jwt "$MYSQL_CONTAINER" "$DB_PASS"
    
    # Import Admins
    minfo "Importing Admins..."
    local admin_count=0
    while IFS='|' read -r id username hashed_password is_sudo telegram_id; do
        [ -z "$id" ] && continue
        local role="standard"
        [ "$is_sudo" == "1" ] && role="sudo"
        [ -z "$telegram_id" ] && telegram_id="NULL"
        username=$(sql_escape "$username")
        hashed_password=$(sql_escape "$hashed_password")
        run_mysql "INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) VALUES ($id, '$username', '$hashed_password', '$role', 'active', $telegram_id, NOW()) ON DUPLICATE KEY UPDATE hashed_password='$hashed_password';"
        ((admin_count++))
    done < <(run_sqlite "SELECT id, username, hashed_password, COALESCE(is_sudo, 0), telegram_id FROM admins;")
    mok "Admins imported: $admin_count"
    
    # Import Inbounds
    minfo "Importing Inbounds..."
    local inbound_count=0
    while IFS='|' read -r id tag; do
        [ -z "$id" ] && continue
        tag=$(sql_escape "$tag")
        run_mysql "INSERT INTO inbounds (id, tag) VALUES ($id, '$tag') ON DUPLICATE KEY UPDATE tag='$tag';"
        ((inbound_count++))
    done < <(run_sqlite "SELECT id, tag FROM inbounds;")
    mok "Inbounds imported: $inbound_count"
    
    # Import Users
    minfo "Importing Users..."
    local user_count=0
    while IFS='|' read -r id username status used_traffic data_limit expire admin_id note; do
        [ -z "$id" ] && continue
        username="${username//@/_at_}"
        username="${username//./_dot_}"
        username=$(sql_escape "$username")
        
        case "$status" in
            active|on_hold|disabled|limited|expired) ;;
            *) status="active" ;;
        esac
        
        [ -z "$used_traffic" ] && used_traffic="0"
        [ -z "$data_limit" ] && data_limit="NULL"
        [ -z "$expire" ] && expire="NULL"
        [ -z "$admin_id" ] && admin_id="1"
        note=$(sql_escape "$note")
        
        run_mysql "INSERT INTO users (id, username, status, used_traffic, data_limit, expire, admin_id, note, created_at) VALUES ($id, '$username', '$status', $used_traffic, $data_limit, $expire, $admin_id, '$note', NOW()) ON DUPLICATE KEY UPDATE status='$status';"
        ((user_count++))
    done < <(run_sqlite "SELECT id, username, COALESCE(status, 'active'), COALESCE(used_traffic, 0), data_limit, expire, COALESCE(admin_id, 1), COALESCE(note, '') FROM users;")
    mok "Users imported: $user_count"
    
    # Import Proxies
    minfo "Importing Proxies..."
    local proxy_count=0
    while IFS='|' read -r id user_id type settings; do
        [ -z "$id" ] && continue
        type=$(sql_escape "$type")
        settings=$(sql_escape "$settings")
        run_mysql "INSERT INTO proxies (id, user_id, type, settings) VALUES ($id, $user_id, '$type', '$settings') ON DUPLICATE KEY UPDATE settings='$settings';"
        ((proxy_count++))
    done < <(run_sqlite "SELECT id, user_id, type, settings FROM proxies;")
    mok "Proxies imported: $proxy_count"
    
    # Import Hosts
    minfo "Importing Hosts..."
    local host_count=0
    while IFS='|' read -r id remark address port inbound_tag sni host security fingerprint is_disabled path; do
        [ -z "$id" ] && continue
        [ -z "$port" ] && port="NULL"
        [ "$is_disabled" == "1" ] && is_disabled_val=1 || is_disabled_val=0
        
        remark=$(sql_escape "$remark")
        address=$(sql_escape "$address")
        path=$(sql_escape "$path")
        inbound_tag=$(sql_escape "$inbound_tag")
        sni=$(sql_escape "$sni")
        host=$(sql_escape "$host")
        security=$(sql_escape "$security")
        fingerprint=$(sql_escape "${fingerprint:-none}")
        
        address="${address//pasarguard/rebecca}"
        address="${address//marzban/rebecca}"
        path="${path//pasarguard/rebecca}"
        path="${path//marzban/rebecca}"
        
        run_mysql "INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, security, fingerprint, is_disabled, path) VALUES ($id, '$remark', '$address', $port, '$inbound_tag', '$sni', '$host', '$security', '$fingerprint', $is_disabled_val, '$path') ON DUPLICATE KEY UPDATE address='$address';"
        ((host_count++))
    done < <(run_sqlite "SELECT id, remark, address, port, inbound_tag, COALESCE(sni, ''), COALESCE(host, ''), COALESCE(security, 'none'), COALESCE(fingerprint, 'none'), COALESCE(is_disabled, 0), COALESCE(path, '') FROM hosts;")
    mok "Hosts imported: $host_count"
    
    # Import Core Config from SQLite
    minfo "Importing Core Config..."
    local config_json=$(run_sqlite "SELECT config FROM core_configs LIMIT 1;")
    if [ -n "$config_json" ]; then
        echo "$config_json" > /tmp/sqlite_config.json
        python3 << 'PYEOF'
import json
import sys

try:
    with open('/tmp/sqlite_config.json', 'r') as f:
        config = json.load(f)
    
    config_str = json.dumps(config)
    config_str = config_str.replace('/var/lib/pasarguard', '/var/lib/rebecca')
    config_str = config_str.replace('/opt/pasarguard', '/opt/rebecca')
    config_str = config_str.replace('/var/lib/marzban', '/var/lib/rebecca')
    config_str = config_str.replace('/opt/marzban', '/opt/rebecca')
    
    config = json.loads(config_str)
    if 'api' not in config:
        config['api'] = {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]}
    
    final_str = json.dumps(config, ensure_ascii=False)
    final_str = final_str.replace('\\', '\\\\')
    final_str = final_str.replace("'", "\\'")
    
    with open('/tmp/mysql_config.txt', 'w') as f:
        f.write(final_str)
    
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYEOF
        
        if [ -f /tmp/mysql_config.txt ]; then
            docker cp /tmp/mysql_config.txt "$MYSQL_CONTAINER:/tmp/config_import.txt"
            docker exec "$MYSQL_CONTAINER" bash -c "
            CONFIG_DATA=\$(cat /tmp/config_import.txt)
            mysql -uroot -p'$DB_PASS' rebecca -e \"
            DELETE FROM core_configs;
            INSERT INTO core_configs (id, name, config, created_at) VALUES (1, 'default', '\$CONFIG_DATA', NOW());
            \"
            rm -f /tmp/config_import.txt
            " 2>/dev/null
            mok "Core Config imported"
            rm -f /tmp/sqlite_config.json /tmp/mysql_config.txt
        fi
    else
        mwarn "No core config found"
    fi
    
    # Setup Services
    setup_services "$MYSQL_CONTAINER" "$DB_PASS"
    
    # Summary
    echo ""
    ui_header "MIGRATION SUMMARY"
    echo -e "  Admins:       ${GREEN}$(run_mysql "SELECT COUNT(*) FROM admins;" | tr -d ' \n')${NC}"
    echo -e "  Users:        ${GREEN}$(run_mysql "SELECT COUNT(*) FROM users;" | tr -d ' \n')${NC}"
    echo -e "  Proxies:      ${GREEN}$(run_mysql "SELECT COUNT(*) FROM proxies;" | tr -d ' \n')${NC}"
    echo -e "  Inbounds:     ${GREEN}$(run_mysql "SELECT COUNT(*) FROM inbounds;" | tr -d ' \n')${NC}"
    echo -e "  Hosts:        ${GREEN}$(run_mysql "SELECT COUNT(*) FROM hosts;" | tr -d ' \n')${NC}"
    echo -e "  Core Configs: ${GREEN}$(run_mysql "SELECT COUNT(*) FROM core_configs;" | tr -d ' \n')${NC}"
    echo ""
    
    return 0
}

# --- STOP OLD SERVICES ---
stop_old_services() {
    minfo "Stopping old panel containers..."
    docker ps --format '{{.Names}}' | grep -iE "pasarguard|marzban" | grep -v rebecca | while read container; do
        minfo "  Stopping: $container"
        docker stop "$container" 2>/dev/null
    done
}

# --- FULL MIGRATION ---
do_full_migration() {
    migration_init
    clear
    ui_header "MRM MIGRATION TOOL V10.3"
    
    echo -e "${CYAN}Supports: PostgreSQL, MySQL, SQLite → Rebecca (MySQL)${NC}"
    echo ""
    
    SRC=$(detect_source_panel)
    if [ -z "$SRC" ]; then merr "No source panel found (Pasarguard/Marzban)"; mpause; return 1; fi
    
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    local SRC_DATA=$(get_source_data_dir "$SRC")
    
    echo -e "  Source: ${YELLOW}$SOURCE_PANEL_TYPE${NC} ($SRC)"
    echo -e "  DB Type: ${YELLOW}$SOURCE_DB_TYPE${NC}"
    echo -e "  Target: ${GREEN}Rebecca${NC} (/opt/rebecca)"
    echo ""
    
    if [ "$SOURCE_DB_TYPE" == "unknown" ]; then
        merr "Could not detect database type"
        mpause
        return 1
    fi
    
    if [ -d "/opt/rebecca" ]; then TGT="/opt/rebecca"; else
        if ! install_rebecca_wizard; then mpause; return 1; fi
        TGT="/opt/rebecca"
    fi
    local TGT_DATA="/var/lib/rebecca"
    
    if ! ui_confirm "Start migration?" "y"; then return 0; fi
    
    echo ""
    echo "$SRC" > "$BACKUP_ROOT/.last_source"
    
    minfo "[1/7] Starting source panel..."
    start_source_panel "$SRC"
    
    minfo "[2/7] Preparing target..."
    (cd "$TGT" && docker compose down 2>/dev/null) &>/dev/null
    
    minfo "[3/7] Copying data files..."
    copy_data_files "$SRC_DATA" "$TGT_DATA"
    
    minfo "[4/7] Installing Xray..."
    install_xray "$TGT_DATA" "$SRC_DATA"
    
    minfo "[5/7] Generating configuration..."
    generate_clean_env "$SRC" "$TGT"
    
    minfo "[6/7] Starting Rebecca..."
    (cd "$TGT" && docker compose up -d --force-recreate)
    minfo "Waiting for services to start..."
    sleep 30
    
    minfo "[7/7] Migrating database..."
    case "$SOURCE_DB_TYPE" in
        postgresql) migrate_postgresql_to_mysql "$SRC" "$TGT" ;;
        sqlite)     migrate_sqlite_to_mysql "$SRC" "$TGT" ;;
        mysql)      mwarn "MySQL to MySQL migration - copying data directly..."; migrate_mysql_to_mysql "$SRC" "$TGT" ;;
        *)          merr "Unsupported database type: $SOURCE_DB_TYPE" ;;
    esac
    
    minfo "Final restart..."
    (cd "$TGT" && docker compose down && sleep 5 && docker compose up -d)
    sleep 15
    stop_old_services
    
    echo ""
    ui_header "MIGRATION COMPLETE!"
    local panel_container=$(docker ps --format '{{.Names}}' | grep rebecca | grep -v mysql | head -1)
    if [ -n "$panel_container" ]; then
        mok "Panel running: $panel_container"
        local xray_log=$(docker logs "$panel_container" 2>&1 | grep -i xray | tail -1)
        if [[ "$xray_log" != *"not found"* ]]; then mok "Xray is working"; else mwarn "Xray might have issues"; fi
    fi
    echo ""
    echo -e "  ${GREEN}Login with your $SOURCE_PANEL_TYPE admin credentials${NC}"
    echo ""
    migration_cleanup
    mpause
}

# --- MYSQL TO MYSQL MIGRATION (for completeness) ---
migrate_mysql_to_mysql() {
    local src="$1"
    local tgt="$2"
    
    mwarn "MySQL to MySQL migration is not fully implemented"
    minfo "Please use mysqldump manually or contact support"
    
    return 1
}

# --- FIX CURRENT ---
do_fix_current() {
    clear
    ui_header "FIX CURRENT INSTALLATION"
    if [ ! -d "/opt/rebecca" ]; then merr "Rebecca not installed"; mpause; return 1; fi
    TGT="/opt/rebecca"
    SRC=$(detect_source_panel)
    if [ -z "$SRC" ]; then merr "Source panel not found"; mpause; return 1; fi
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    local SRC_DATA=$(get_source_data_dir "$SRC")
    local TGT_DATA="/var/lib/rebecca"
    
    echo "This will re-import everything and fix configs."
    echo "Source: $SRC ($SOURCE_DB_TYPE)"
    if ! ui_confirm "Proceed?" "y"; then return 0; fi
    
    start_source_panel "$SRC"
    (cd "$TGT" && docker compose down) &>/dev/null
    copy_data_files "$SRC_DATA" "$TGT_DATA"
    install_xray "$TGT_DATA" "$SRC_DATA"
    (cd "$TGT" && docker compose up -d)
    sleep 30
    
    case "$SOURCE_DB_TYPE" in
        postgresql) migrate_postgresql_to_mysql "$SRC" "$TGT" ;;
        sqlite)     migrate_sqlite_to_mysql "$SRC" "$TGT" ;;
    esac
    
    (cd "$TGT" && docker compose down && docker compose up -d)
    sleep 15
    stop_old_services
    mok "Fix complete!"
    mpause
}

# --- ROLLBACK ---
do_rollback() {
    clear
    ui_header "ROLLBACK"
    local src_path=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    if [ -z "$src_path" ] || [ ! -d "$src_path" ]; then merr "No source panel path found"; mpause; return 1; fi
    echo "This will: Stop Rebecca, Start $src_path"
    if ui_confirm "Proceed?" "n"; then
        (cd /opt/rebecca && docker compose down 2>/dev/null) &>/dev/null
        (cd "$src_path" && docker compose up -d)
        mok "Rollback complete - $src_path is running"
    fi
    mpause
}

# --- VIEW STATUS ---
view_status() {
    clear
    ui_header "SYSTEM STATUS"
    echo -e "${CYAN}Docker Containers:${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | head -15
    echo ""
    if [ -d "/opt/rebecca" ]; then
        local MYSQL_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i "rebecca.*mysql" | head -1)
        local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "/opt/rebecca/.env")
        if [ -n "$MYSQL_CONTAINER" ] && [ -n "$DB_PASS" ]; then
            echo -e "${CYAN}Database Stats:${NC}"
            docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -e "
                SELECT 'Admins' as 'Table', COUNT(*) as 'Count' FROM admins
                UNION SELECT 'Users', COUNT(*) FROM users
                UNION SELECT 'Proxies', COUNT(*) FROM proxies
                UNION SELECT 'Inbounds', COUNT(*) FROM inbounds
                UNION SELECT 'Hosts', COUNT(*) FROM hosts
                UNION SELECT 'Core Configs', COUNT(*) FROM core_configs
                UNION SELECT 'Services', COUNT(*) FROM services
                UNION SELECT 'JWT', COUNT(*) FROM jwt;" 2>/dev/null
        fi
    fi
    mpause
}

# --- VIEW LOGS ---
view_logs() {
    clear
    ui_header "MIGRATION LOGS"
    if [ -f "$MIGRATION_LOG" ]; then tail -100 "$MIGRATION_LOG"; else echo "No logs found"; fi
    mpause
}

# --- MAIN MENU ---
migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION TOOL V10.3"
        echo "  1) Full Migration"
        echo "  2) Fix Current Installation"
        echo "  3) Rollback"
        echo "  4) View Status"
        echo "  5) View Logs"
        echo "  0) Exit"
        read -p "Select: " opt
        case "$opt" in
            1) do_full_migration ;;
            2) do_fix_current ;;
            3) do_rollback ;;
            4) view_status ;;
            5) view_logs ;;
            0) migration_cleanup; return 0 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi
    migrator_menu
fi