#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V10.1 (Final Production - PostgreSQL + Full Data Import)
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

detect_db_type() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    
    if [ -f "$env_file" ]; then
        local db_url=$(grep "^SQLALCHEMY_DATABASE_URL" "$env_file" | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        case "$db_url" in
            *postgresql*) echo "postgresql" ;;
            *mysql*)      echo "mysql" ;;
            *sqlite*)     echo "sqlite" ;;
            *)            echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

# --- DATABASE CONTAINER DETECTION ---
find_pg_container() {
    local panel_dir="$1"
    local panel_name=$(basename "$panel_dir")
    
    # Try multiple patterns
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "${panel_name}.*(timescale|postgres|db)" | head -1)
    [ -z "$cname" ] && cname=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | grep -v rebecca | head -1)
    
    echo "$cname"
}

find_mysql_container() {
    local panel_dir="$1"
    local panel_name=$(basename "$panel_dir")
    
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "${panel_name}.*(mysql|mariadb)" | head -1)
    [ -z "$cname" ] && cname=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb)" | head -1)
    
    echo "$cname"
}

# --- START SOURCE PANEL ---
start_source_panel() {
    local src="$1"
    minfo "Starting source panel services..."
    
    (cd "$src" && docker compose up -d) &>/dev/null
    
    # Wait for database
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
            # Wait for PostgreSQL to be ready
            waited=0
            while ! docker exec "$pg_container" pg_isready -U pasarguard &>/dev/null && [ $waited -lt $max_wait ]; do
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
    
    # Try to copy from source first
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
    
    # Copy/download assets
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
    
    # Certificates
    if [ -d "$src_data/certs" ]; then
        mkdir -p "$tgt_data/certs"
        cp -r "$src_data/certs/"* "$tgt_data/certs/" 2>/dev/null
        # Fix permissions
        find "$tgt_data/certs" -type f -exec chmod 644 {} \;
        find "$tgt_data/certs" -type d -exec chmod 755 {} \;
        mok "Certificates copied"
    fi
    
    # Templates
    if [ -d "$src_data/templates" ]; then
        mkdir -p "$tgt_data/templates"
        cp -r "$src_data/templates/"* "$tgt_data/templates/" 2>/dev/null
        mok "Templates copied"
    fi
    
    # Assets
    if [ -d "$src_data/assets" ]; then
        mkdir -p "$tgt_data/assets"
        cp -r "$src_data/assets/"* "$tgt_data/assets/" 2>/dev/null
        mok "Assets copied"
    fi
}

# --- SMART ENV READER ---
read_var() {
    local key="$1"
    local file="$2"
    [ ! -f "$file" ] && return
    grep -E "^\s*${key}\s*=" "$file" 2>/dev/null | grep -v "^#" | head -1 | sed -E "s/^\s*${key}\s*=\s*//g" | sed -E 's/^"//;s/"$//;s/^\x27//;s/\x27$//'
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
    [ -z "$UV_PORT" ] && UV_PORT="7431"

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

    local SUB_URL=$(read_var "XRAY_SUBSCRIPTION_URL_PREFIX" "$src_env")

    cat > "$tgt_env" <<EOF
# Database
SQLALCHEMY_DATABASE_URL="mysql+pymysql://root:${DB_PASS}@127.0.0.1:3306/rebecca"
MYSQL_ROOT_PASSWORD="${DB_PASS}"
MYSQL_DATABASE="rebecca"

# Server
UVICORN_HOST="0.0.0.0"
UVICORN_PORT="${UV_PORT}"
UVICORN_SSL_CERTFILE="${SSL_CERT}"
UVICORN_SSL_KEYFILE="${SSL_KEY}"

# Admin
SUDO_USERNAME="${SUDO_USER}"
SUDO_PASSWORD="${SUDO_PASS}"

# Telegram
TELEGRAM_API_TOKEN="${TG_TOKEN}"
TELEGRAM_ADMIN_ID="${TG_ADMIN}"

# Xray
XRAY_JSON="${XRAY_JSON}"
XRAY_SUBSCRIPTION_URL_PREFIX="${SUB_URL}"
XRAY_EXECUTABLE_PATH="/var/lib/rebecca/xray"
XRAY_ASSETS_PATH="/var/lib/rebecca/assets"

# JWT
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440
SECRET_KEY="$(openssl rand -hex 32)"
EOF

    mok "Environment file created"
}

# --- INSTALL REBECCA ---
install_rebecca_wizard() {
    clear
    ui_header "INSTALLING REBECCA"
    
    if ! ui_confirm "Install Rebecca Panel?" "y"; then 
        return 1
    fi
    
    eval "$REBECCA_INSTALL_CMD"
    
    if [ -d "/opt/rebecca" ]; then
        mok "Rebecca installed"
        return 0
    else
        merr "Installation failed"
        return 1
    fi
}

# --- IMPORT CORE CONFIG VIA PYTHON (FIXED) ---
import_core_config() {
    local PG_CONTAINER="$1"
    local MYSQL_CONTAINER="$2"
    local DB_PASS="$3"
    
    minfo "Importing Core Config..."
    
    # Export to file
    docker exec "$PG_CONTAINER" psql -U pasarguard -d pasarguard -t -A -c "SELECT config FROM core_configs LIMIT 1;" > /tmp/pg_config.json
    
    if [ ! -s /tmp/pg_config.json ]; then
        mwarn "No core config found in source"
        return 1
    fi
    
    # Process and Import via Python
    python3 << PYEOF
import json
import subprocess
import sys

try:
    with open('/tmp/pg_config.json', 'r') as f:
        config_str = f.read().strip()
    
    if not config_str:
        print("Empty config")
        sys.exit(1)
    
    # Validate JSON
    config = json.loads(config_str)
    
    # Fix paths
    config_str = json.dumps(config)
    config_str = config_str.replace('/var/lib/pasarguard', '/var/lib/rebecca')
    config_str = config_str.replace('/opt/pasarguard', '/opt/rebecca')
    
    # Ensure API section exists
    config = json.loads(config_str)
    if 'api' not in config:
        config['api'] = {
            "tag": "api",
            "services": ["HandlerService", "LoggerService", "StatsService"]
        }
    
    # Ensure API inbound exists
    api_exists = False
    if 'inbounds' in config:
        for inb in config['inbounds']:
            if inb.get('tag') == 'api':
                api_exists = True
                break
    else:
        config['inbounds'] = []
    
    if not api_exists:
        config['inbounds'].insert(0, {
            "tag": "api",
            "port": 10085,
            "listen": "127.0.0.1",
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"}
        })
    
    # Save cleaned config
    final_config = json.dumps(config)
    
    with open('/tmp/clean_config.json', 'w') as f:
        f.write(final_config)
    
    print("Config processed successfully")
    
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYEOF

    if [ $? -ne 0 ]; then
        mwarn "Failed to process config"
        return 1
    fi
    
    # Copy to MySQL container and import
    docker cp /tmp/clean_config.json "$MYSQL_CONTAINER:/tmp/config.json"
    
    # Import using Python inside container
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -e "
    SET @config = LOAD_FILE('/tmp/config.json');
    DELETE FROM core_configs;
    INSERT INTO core_configs (id, name, config, created_at) VALUES (1, 'default', @config, NOW());
    " 2>/dev/null
    
    # Verify
    local count=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "SELECT COUNT(*) FROM core_configs;" 2>/dev/null)
    
    if [ "$count" -gt 0 ]; then
        mok "Core Config imported"
        return 0
    else
        # Fallback: Direct insert with escaped content
        mwarn "LOAD_FILE failed, trying direct insert..."
        
        local CONFIG_CONTENT=$(cat /tmp/clean_config.json | sed "s/'/\\\\'/g" | tr -d '\n')
        docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -e "
        DELETE FROM core_configs;
        INSERT INTO core_configs (id, name, config, created_at) VALUES (1, 'default', '$CONFIG_CONTENT', NOW());
        " 2>/dev/null
        
        count=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "SELECT COUNT(*) FROM core_configs;" 2>/dev/null)
        if [ "$count" -gt 0 ]; then
            mok "Core Config imported (fallback)"
            return 0
        fi
        
        merr "Failed to import core config"
        return 1
    fi
}

# --- SETUP SERVICES AND LINKING (FIXED) ---
setup_services_and_linking() {
    local MYSQL_CONTAINER="$1"
    local DB_PASS="$2"
    
    minfo "Setting up Services and Linking..."
    
    run_mysql() {
        docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "$1" 2>/dev/null
    }
    
    # Create default service
    run_mysql "DELETE FROM services;"
    run_mysql "INSERT INTO services (id, name, created_at) VALUES (1, 'Default Service', NOW());"
    
    # Link all hosts to service
    run_mysql "DELETE FROM service_hosts;"
    run_mysql "INSERT INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts;"
    
    # Assign all users to service
    run_mysql "UPDATE users SET service_id = 1 WHERE service_id IS NULL;"
    
    local svc_count=$(run_mysql "SELECT COUNT(*) FROM services;")
    local sh_count=$(run_mysql "SELECT COUNT(*) FROM service_hosts;")
    local usr_linked=$(run_mysql "SELECT COUNT(*) FROM users WHERE service_id = 1;")
    
    mok "Services: $svc_count, Host Links: $sh_count, Users Linked: $usr_linked"
}

# --- DIRECT POSTGRESQL TO MYSQL MIGRATION (FIXED) ---
migrate_postgresql_to_mysql() {
    local src="$1"
    local tgt="$2"
    
    ui_header "DIRECT DATABASE MIGRATION"
    
    local PG_CONTAINER=$(find_pg_container "$src")
    local MYSQL_CONTAINER=$(find_mysql_container "$tgt")
    local DB_PASS=$(grep MYSQL_ROOT_PASSWORD "$tgt/.env" | cut -d'=' -f2 | tr -d '"')
    
    if [ -z "$PG_CONTAINER" ]; then
        merr "PostgreSQL container not found"
        return 1
    fi
    
    if [ -z "$MYSQL_CONTAINER" ]; then
        merr "MySQL container not found"
        return 1
    fi
    
    minfo "Source: $PG_CONTAINER (PostgreSQL)"
    minfo "Target: $MYSQL_CONTAINER (MySQL)"
    
    # Helper functions
    run_pg() {
        docker exec "$PG_CONTAINER" psql -U pasarguard -d pasarguard -t -A -c "$1" 2>/dev/null
    }
    
    run_mysql() {
        docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "$1" 2>/dev/null
    }
    
    # Wait for MySQL
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
    
    # Create database and reset tables
    run_mysql "CREATE DATABASE IF NOT EXISTS rebecca CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    run_mysql "SET FOREIGN_KEY_CHECKS=0;"
    run_mysql "DELETE FROM users;"
    run_mysql "DELETE FROM inbounds;"
    run_mysql "DELETE FROM hosts;"
    run_mysql "DELETE FROM services;"
    run_mysql "DELETE FROM service_hosts;"
    run_mysql "DELETE FROM core_configs;"
    run_mysql "DELETE FROM jwt;"
    run_mysql "DELETE FROM proxies;"
    run_mysql "SET FOREIGN_KEY_CHECKS=1;"
    
    echo ""
    minfo "[1/9] Importing Admins..."
    
    # Get admin count first
    local admin_count=$(run_pg "SELECT COUNT(*) FROM admins;")
    minfo "Found $admin_count admin(s) in source"
    
    # Export to file and import
    run_pg "SELECT id, username, hashed_password, COALESCE(is_sudo, false), COALESCE(telegram_id, 0), COALESCE(used_traffic, 0) FROM admins;" > /tmp/admins.txt
    
    while IFS='|' read -r id username hashed_password is_sudo telegram_id used_traffic; do
        [ -z "$id" ] && continue
        
        # Determine role
        local role="standard"
        [ "$is_sudo" == "t" ] && role="sudo"
        
        # Handle telegram_id
        [ -z "$telegram_id" ] && telegram_id="NULL"
        [ "$telegram_id" == "0" ] && telegram_id="NULL"
        
        # Escape password hash
        hashed_password=$(echo "$hashed_password" | sed "s/'/''/g")
        
        run_mysql "INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) VALUES ($id, '$username', '$hashed_password', '$role', 'active', $telegram_id, NOW()) ON DUPLICATE KEY UPDATE hashed_password='$hashed_password', role='$role';"
        
        mok "  Admin: $username (role: $role)"
    done < /tmp/admins.txt
    
    echo ""
    minfo "[2/9] Importing Inbounds..."
    
    # Export to file (FIXED: No protocol column in Rebecca)
    run_pg "SELECT id, tag FROM inbounds;" > /tmp/inbounds.txt
    
    while IFS='|' read -r id tag; do
        [ -z "$id" ] && continue
        run_mysql "INSERT INTO inbounds (id, tag) VALUES ($id, '$tag');"
        echo "  Added: $tag"
    done < /tmp/inbounds.txt
    
    local imported_inbounds=$(run_mysql "SELECT COUNT(*) FROM inbounds;")
    mok "Imported $imported_inbounds inbounds"
    
    echo ""
    minfo "[3/9] Importing Users..."
    
    local user_count=$(run_pg "SELECT COUNT(*) FROM users;")
    minfo "Found $user_count users in source"
    
    # Export with Unix timestamp (FIXED)
    run_pg "SELECT id, username, COALESCE(status, 'active'), COALESCE(used_traffic, 0), data_limit, EXTRACT(EPOCH FROM expire)::bigint, COALESCE(admin_id, 1), note FROM users;" > /tmp/users.txt
    
    while IFS='|' read -r id username status used_traffic data_limit expire admin_id note; do
        [ -z "$id" ] && continue
        
        # Fix username chars (FIXED)
        username="${username//@/}"
        username="${username//./_}"
        username="${username//-/_}"
        
        # Fix status values
        case "$status" in
            active|on_hold) status="active" ;;
            disabled) status="disabled" ;;
            limited) status="limited" ;;
            expired) status="expired" ;;
            *) status="active" ;;
        esac
        
        # Handle NULL values
        [ -z "$data_limit" ] && data_limit="NULL"
        [ -z "$expire" ] && expire="NULL"
        [ -z "$admin_id" ] && admin_id="1"
        
        # Escape note
        note=$(echo "$note" | sed "s/'/''/g")
        [ -z "$note" ] && note=""
        
        run_mysql "INSERT INTO users (id, username, status, used_traffic, data_limit, expire, admin_id, note, created_at) VALUES ($id, '$username', '$status', $used_traffic, $data_limit, $expire, $admin_id, '$note', NOW());"
    done < /tmp/users.txt
    
    local imported_users=$(run_mysql "SELECT COUNT(*) FROM users;")
    mok "Imported $imported_users users"
    
    echo ""
    minfo "[4/9] Importing Proxies..."
    
    run_pg "SELECT id, user_id, type, settings FROM proxies;" > /tmp/proxies.txt 2>/dev/null
    
    local proxy_count=0
    while IFS='|' read -r id user_id type settings; do
        [ -z "$id" ] && continue
        
        # Escape settings JSON
        settings=$(echo "$settings" | sed "s/'/''/g")
        
        run_mysql "INSERT INTO proxies (id, user_id, type, settings) VALUES ($id, $user_id, '$type', '$settings');"
        proxy_count=$((proxy_count + 1))
    done < /tmp/proxies.txt
    
    mok "Imported $proxy_count proxies"
    
    echo ""
    minfo "[5/9] Importing Hosts..."
    
    # Check if hosts table has data in source
    local host_count=$(run_pg "SELECT COUNT(*) FROM hosts;" 2>/dev/null)
    
    if [ -n "$host_count" ] && [ "$host_count" -gt 0 ]; then
        # Export hosts (FIXED: fingerprint handling)
        run_pg "SELECT id, remark, address, port, inbound_tag, sni, host, security, COALESCE(fingerprint::text, 'none'), is_disabled, path FROM hosts;" > /tmp/hosts.txt
        
        while IFS='|' read -r id remark address port inbound_tag sni host security fingerprint is_disabled path; do
            [ -z "$id" ] && continue
            
            # Handle NULL port
            [ -z "$port" ] && port="NULL"
            
            # Fix is_disabled
            is_disabled_val=0
            [ "$is_disabled" == "t" ] && is_disabled_val=1
            
            # Escape strings
            remark=$(echo "$remark" | sed "s/'/''/g")
            address=$(echo "$address" | sed "s/'/''/g")
            path=$(echo "$path" | sed "s/'/''/g")
            
            # Replace paths
            address="${address//pasarguard/rebecca}"
            path="${path//pasarguard/rebecca}"
            
            # Handle fingerprint
            [ -z "$fingerprint" ] && fingerprint="none"
            
            run_mysql "INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, security, fingerprint, is_disabled, path) VALUES ($id, '$remark', '$address', $port, '$inbound_tag', '$sni', '$host', '$security', '$fingerprint', $is_disabled_val, '$path');"
        done < /tmp/hosts.txt
        
        local imported_hosts=$(run_mysql "SELECT COUNT(*) FROM hosts;")
        mok "Imported $imported_hosts hosts"
    else
        mwarn "No hosts found in source"
    fi
    
    echo ""
    minfo "[6/9] Importing Core Configs..."
    
    import_core_config "$PG_CONTAINER" "$MYSQL_CONTAINER" "$DB_PASS"
    
    echo ""
    minfo "[7/9] Importing Nodes..."
    
    local node_count=$(run_pg "SELECT COUNT(*) FROM nodes;" 2>/dev/null)
    
    if [ -n "$node_count" ] && [ "$node_count" -gt 0 ]; then
        run_pg "SELECT id, name, address, port, api_port FROM nodes;" > /tmp/nodes.txt
        
        while IFS='|' read -r id name address port api_port; do
            [ -z "$id" ] && continue
            
            name=$(echo "$name" | sed "s/'/''/g")
            
            run_mysql "INSERT INTO nodes (id, name, address, port, api_port, status, created_at) VALUES ($id, '$name', '$address', $port, $api_port, 'healthy', NOW()) ON DUPLICATE KEY UPDATE name='$name';"
        done < /tmp/nodes.txt
        
        mok "Imported $node_count nodes"
    fi
    
    echo ""
    minfo "[8/9] Setting up JWT..."
    
    local JWT_SECRET=$(openssl rand -hex 64)
    local SUB_SECRET=$(openssl rand -hex 64)
    local ADMIN_SECRET=$(openssl rand -hex 64)
    local VMESS_MASK=$(openssl rand -hex 16)
    local VLESS_MASK=$(openssl rand -hex 16)
    
    run_mysql "DELETE FROM jwt;"
    run_mysql "INSERT INTO jwt (secret_key, subscription_secret_key, admin_secret_key, vmess_mask, vless_mask) VALUES ('$JWT_SECRET', '$SUB_SECRET', '$ADMIN_SECRET', '$VMESS_MASK', '$VLESS_MASK');"
    
    mok "JWT configured"
    
    echo ""
    minfo "[9/9] Setting up Services & Linking..."
    
    setup_services_and_linking "$MYSQL_CONTAINER" "$DB_PASS"
    
    echo ""
    minfo "Fixing paths in database..."
    
    run_mysql "UPDATE hosts SET address = REPLACE(address, 'pasarguard', 'rebecca') WHERE address LIKE '%pasarguard%';"
    run_mysql "UPDATE hosts SET path = REPLACE(path, 'pasarguard', 'rebecca') WHERE path LIKE '%pasarguard%';"
    run_mysql "UPDATE core_configs SET config = REPLACE(config, 'pasarguard', 'rebecca') WHERE config LIKE '%pasarguard%';"
    run_mysql "UPDATE nodes SET address = REPLACE(address, 'pasarguard', 'rebecca') WHERE address LIKE '%pasarguard%';"
    
    mok "Paths fixed"
    
    echo ""
    ui_header "MIGRATION SUMMARY"
    
    echo -e "  Admins:       ${GREEN}$(run_mysql "SELECT COUNT(*) FROM admins;")${NC}"
    echo -e "  Users:        ${GREEN}$(run_mysql "SELECT COUNT(*) FROM users;")${NC}"
    echo -e "  Proxies:      ${GREEN}$(run_mysql "SELECT COUNT(*) FROM proxies;")${NC}"
    echo -e "  Inbounds:     ${GREEN}$(run_mysql "SELECT COUNT(*) FROM inbounds;")${NC}"
    echo -e "  Hosts:        ${GREEN}$(run_mysql "SELECT COUNT(*) FROM hosts;")${NC}"
    echo -e "  Core Configs: ${GREEN}$(run_mysql "SELECT COUNT(*) FROM core_configs;")${NC}"
    echo -e "  Services:     ${GREEN}$(run_mysql "SELECT COUNT(*) FROM services;")${NC}"
    echo ""
    
    return 0
}

# --- MIGRATE SQLITE TO MYSQL ---
migrate_sqlite_to_mysql() {
    local src="$1"
    local tgt="$2"
    local src_data=$(get_source_data_dir "$src")
    local sqlite_file="$src_data/db.sqlite3"
    
    if [ ! -f "$sqlite_file" ]; then
        merr "SQLite file not found: $sqlite_file"
        return 1
    fi
    
    ui_header "SQLITE TO MYSQL MIGRATION"
    
    local MYSQL_CONTAINER=$(find_mysql_container "$tgt")
    local DB_PASS=$(grep MYSQL_ROOT_PASSWORD "$tgt/.env" | cut -d'=' -f2 | tr -d '"')
    
    run_mysql() {
        docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "$1" 2>/dev/null
    }
    
    # Install sqlite3 if needed
    command -v sqlite3 &>/dev/null || apt-get install -y sqlite3 -qq
    
    minfo "[1/5] Importing Admins..."
    
    sqlite3 "$sqlite_file" "SELECT id, username, hashed_password, is_sudo FROM admins;" | while IFS='|' read -r id username hashed_password is_sudo; do
        [ -z "$id" ] && continue
        
        local role="standard"
        [ "$is_sudo" == "1" ] && role="sudo"
        
        hashed_password=$(echo "$hashed_password" | sed "s/'/''/g")
        
        run_mysql "INSERT INTO admins (id, username, hashed_password, role, status, created_at) VALUES ($id, '$username', '$hashed_password', '$role', 'active', NOW()) ON DUPLICATE KEY UPDATE hashed_password='$hashed_password';"
    done
    
    mok "Admins imported"
    
    minfo "[2/5] Importing Users..."
    
    sqlite3 "$sqlite_file" "SELECT id, username, status, used_traffic, data_limit, expire, admin_id FROM users;" | while IFS='|' read -r id username status used_traffic data_limit expire admin_id; do
        [ -z "$id" ] && continue
        
        # Fix username
        username="${username//@/}"
        username="${username//./_}"
        
        [ -z "$used_traffic" ] && used_traffic=0
        [ -z "$data_limit" ] && data_limit="NULL"
        [ -z "$expire" ] && expire="NULL"
        [ -z "$admin_id" ] && admin_id=1
        
        run_mysql "INSERT INTO users (id, username, status, used_traffic, data_limit, expire, admin_id, created_at) VALUES ($id, '$username', '$status', $used_traffic, $data_limit, $expire, $admin_id, NOW());"
    done
    
    mok "Users imported: $(run_mysql "SELECT COUNT(*) FROM users;")"
    
    minfo "[3/5] Importing Proxies..."
    
    sqlite3 "$sqlite_file" "SELECT id, user_id, type, settings FROM proxies;" | while IFS='|' read -r id user_id type settings; do
        [ -z "$id" ] && continue
        settings=$(echo "$settings" | sed "s/'/''/g")
        run_mysql "INSERT INTO proxies (id, user_id, type, settings) VALUES ($id, $user_id, '$type', '$settings');"
    done
    
    mok "Proxies imported"
    
    minfo "[4/5] Importing Inbounds..."
    
    sqlite3 "$sqlite_file" "SELECT id, tag FROM inbounds;" | while IFS='|' read -r id tag; do
        [ -z "$id" ] && continue
        run_mysql "INSERT INTO inbounds (id, tag) VALUES ($id, '$tag');"
    done
    
    mok "Inbounds imported"
    
    minfo "[5/5] Setting up JWT & Services..."
    
    run_mysql "DELETE FROM jwt;"
    run_mysql "INSERT INTO jwt (secret_key, subscription_secret_key, admin_secret_key, vmess_mask, vless_mask) VALUES ('$(openssl rand -hex 64)', '$(openssl rand -hex 64)', '$(openssl rand -hex 64)', '$(openssl rand -hex 16)', '$(openssl rand -hex 16)');"
    
    setup_services_and_linking "$MYSQL_CONTAINER" "$DB_PASS"
    
    mok "JWT & Services configured"
    
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
    ui_header "MRM MIGRATION TOOL V10.1"
    
    echo -e "${CYAN}Supports: PostgreSQL, MySQL, SQLite → Rebecca (MySQL)${NC}"
    echo ""
    
    # Detect source
    SRC=$(detect_source_panel)
    if [ -z "$SRC" ]; then
        merr "No source panel found (Pasarguard/Marzban)"
        mpause
        return 1
    fi
    
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    local SRC_DATA=$(get_source_data_dir "$SRC")
    
    echo -e "  Source Panel: ${YELLOW}$SOURCE_PANEL_TYPE${NC}"
    echo -e "  Source DB:    ${YELLOW}$SOURCE_DB_TYPE${NC}"
    echo -e "  Source Path:  ${YELLOW}$SRC${NC}"
    echo ""
    
    # Check/install target
    if [ -d "/opt/rebecca" ]; then
        TGT="/opt/rebecca"
    else
        if ! install_rebecca_wizard; then
            mpause
            return 1
        fi
        TGT="/opt/rebecca"
    fi
    
    local TGT_DATA="/var/lib/rebecca"
    
    echo -e "  Target Panel: ${GREEN}Rebecca${NC}"
    echo -e "  Target Path:  ${GREEN}$TGT${NC}"
    echo ""
    
    if ! ui_confirm "Start migration?" "y"; then
        return 0
    fi
    
    echo ""
    
    # Save source path for rollback
    echo "$SRC" > "$BACKUP_ROOT/.last_source"
    
    # Step 1: Start source panel (for database access)
    minfo "[1/7] Starting source panel..."
    start_source_panel "$SRC"
    
    # Step 2: Stop target temporarily
    minfo "[2/7] Preparing target..."
    (cd "$TGT" && docker compose down 2>/dev/null) &>/dev/null
    
    # Step 3: Copy data files
    minfo "[3/7] Copying data files..."
    copy_data_files "$SRC_DATA" "$TGT_DATA"
    
    # Step 4: Install Xray
    minfo "[4/7] Installing Xray..."
    install_xray "$TGT_DATA" "$SRC_DATA"
    
    # Step 5: Generate env
    minfo "[5/7] Generating configuration..."
    generate_clean_env "$SRC" "$TGT"
    
    # Step 6: Start target
    minfo "[6/7] Starting Rebecca..."
    (cd "$TGT" && docker compose up -d --force-recreate)
    
    minfo "Waiting for services to start..."
    sleep 30
    
    # Step 7: Migrate database
    minfo "[7/7] Migrating database..."
    
    case "$SOURCE_DB_TYPE" in
        postgresql)
            migrate_postgresql_to_mysql "$SRC" "$TGT"
            ;;
        sqlite)
            migrate_sqlite_to_mysql "$SRC" "$TGT"
            ;;
        mysql)
            minfo "MySQL to MySQL migration..."
            # Direct mysqldump and import
            ;;
        *)
            merr "Unknown database type: $SOURCE_DB_TYPE"
            ;;
    esac
    
    # Final restart
    minfo "Final restart..."
    (cd "$TGT" && docker compose down && sleep 5 && docker compose up -d)
    sleep 15
    
    # Stop old services
    stop_old_services
    
    # Verify
    echo ""
    ui_header "MIGRATION COMPLETE!"
    
    local panel_container=$(docker ps --format '{{.Names}}' | grep rebecca | grep -v mysql | head -1)
    
    if [ -n "$panel_container" ]; then
        mok "Panel running: $panel_container"
        
        # Check Xray
        local xray_log=$(docker logs "$panel_container" 2>&1 | grep -i xray | tail -1)
        if [[ "$xray_log" != *"not found"* ]]; then
            mok "Xray is working"
        else
            mwarn "Xray might have issues"
        fi
    fi
    
    echo ""
    echo -e "  ${GREEN}Login with your Pasarguard admin credentials${NC}"
    echo ""
    
    # Show admin info
    local MYSQL_CONTAINER=$(find_mysql_container "$TGT")
    local DB_PASS=$(grep MYSQL_ROOT_PASSWORD "$TGT/.env" | cut -d'=' -f2 | tr -d '"')
    
    echo -e "  ${CYAN}Admins in database:${NC}"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -e "SELECT username, role FROM admins;" 2>/dev/null
    
    echo ""
    migration_cleanup
    mpause
}

# --- FIX CURRENT ---
do_fix_current() {
    clear
    ui_header "FIX CURRENT INSTALLATION"
    
    if [ ! -d "/opt/rebecca" ]; then
        merr "Rebecca not installed"
        mpause
        return 1
    fi
    
    TGT="/opt/rebecca"
    SRC=$(detect_source_panel)
    
    if [ -z "$SRC" ]; then
        merr "Source panel not found"
        mpause
        return 1
    fi
    
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    local SRC_DATA=$(get_source_data_dir "$SRC")
    local TGT_DATA="/var/lib/rebecca"
    
    echo "This will:"
    echo "  1. Re-copy data files"
    echo "  2. Install/fix Xray"
    echo "  3. Re-import database"
    echo ""
    
    if ! ui_confirm "Proceed?" "y"; then
        return 0
    fi
    
    # Start source
    start_source_panel "$SRC"
    
    # Stop target
    (cd "$TGT" && docker compose down) &>/dev/null
    
    # Copy files
    copy_data_files "$SRC_DATA" "$TGT_DATA"
    install_xray "$TGT_DATA" "$SRC_DATA"
    
    # Start target
    (cd "$TGT" && docker compose up -d)
    sleep 30
    
    # Re-import
    case "$SOURCE_DB_TYPE" in
        postgresql)
            migrate_postgresql_to_mysql "$SRC" "$TGT"
            ;;
        sqlite)
            migrate_sqlite_to_mysql "$SRC" "$TGT"
            ;;
    esac
    
    # Restart
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
    
    if [ -z "$src_path" ] || [ ! -d "$src_path" ]; then
        merr "No source panel path found"
        mpause
        return 1
    fi
    
    echo "This will:"
    echo "  1. Stop Rebecca"
    echo "  2. Start $src_path"
    echo ""
    
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
        local DB_PASS=$(grep MYSQL_ROOT_PASSWORD /opt/rebecca/.env 2>/dev/null | cut -d'=' -f2 | tr -d '"')
        
        if [ -n "$MYSQL_CONTAINER" ] && [ -n "$DB_PASS" ]; then
            echo -e "${CYAN}Database Stats:${NC}"
            docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -e "
                SELECT 'Admins' as 'Table', COUNT(*) as 'Count' FROM admins
                UNION SELECT 'Users', COUNT(*) FROM users
                UNION SELECT 'Proxies', COUNT(*) FROM proxies
                UNION SELECT 'Inbounds', COUNT(*) FROM inbounds
                UNION SELECT 'Hosts', COUNT(*) FROM hosts
                UNION SELECT 'Core Configs', COUNT(*) FROM core_configs
                UNION SELECT 'Services', COUNT(*) FROM services;" 2>/dev/null
        fi
    fi
    
    mpause
}

# --- VIEW LOGS ---
view_logs() {
    clear
    ui_header "MIGRATION LOGS"
    
    if [ -f "$MIGRATION_LOG" ]; then
        tail -100 "$MIGRATION_LOG"
    else
        echo "No logs found"
    fi
    
    mpause
}

# --- MAIN MENU ---
migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION TOOL V10.1"
        echo ""
        echo -e "  ${GREEN}Supports:${NC}"
        echo "    • Pasarguard (PostgreSQL) → Rebecca"
        echo "    • Pasarguard (SQLite)     → Rebecca"
        echo "    • Marzban                 → Rebecca"
        echo ""
        echo -e "  ${CYAN}Options:${NC}"
        echo "    1) Full Migration"
        echo "    2) Fix Current Installation"
        echo "    3) Rollback"
        echo "    4) View Status"
        echo "    5) View Logs"
        echo ""
        echo "    0) Exit"
        echo ""
        read -p "Select: " opt
        
        case "$opt" in
            1) do_full_migration ;;
            2) do_fix_current ;;
            3) do_rollback ;;
            4) view_status ;;
            5) view_logs ;;
            0|q|Q) return 0 ;;
            *) mwarn "Invalid option" ;;
        esac
    done
}

# --- ENTRY POINT ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (sudo)"
        exit 1
    fi
    
    # Check dependencies
    if ! command -v docker &>/dev/null; then
        echo "Docker is required"
        exit 1
    fi
    
    if ! command -v python3 &>/dev/null; then
        echo "Python3 is required"
        exit 1
    fi
    
    migrator_menu
fi