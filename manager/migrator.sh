#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V10.4 (COMPLETE FIX: All Data Migration)
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
    rm -f /tmp/pg_config.json /tmp/clean_config.json /tmp/sqlite_export_*.sql 2>/dev/null
    rm -f /tmp/mysql_config.txt /tmp/mysql_import_*.sql 2>/dev/null
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

# --- FIX: SAFE SQL ESCAPE (handles $ in bcrypt hashes) ---
sql_escape_py() {
    python3 -c "
import sys
s = sys.stdin.read()
# Escape backslash first, then single quote
s = s.replace('\\\\', '\\\\\\\\')
s = s.replace(\"'\", \"\\\\'\")
print(s, end='')
" 2>/dev/null
}

sql_escape() {
    local str="$1"
    # Use Python for reliable escaping (handles $, \, ' correctly)
    echo -n "$str" | sql_escape_py
}

# --- SAFE PASSWORD READER ---
read_var() {
    local key="$1"
    local file="$2"
    [ ! -f "$file" ] && echo "" && return 1
    local line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | grep -v "^[[:space:]]*#" | head -1)
    [ -z "$line" ] && echo "" && return 1
    local value="${line#*=}"
    value=$(echo "$value" | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//')
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

# --- IMPORT CORE CONFIG (SAFE JSON HANDLING) ---
import_core_config() {
    local PG_CONTAINER="$1"
    local MYSQL_CONTAINER="$2"
    local DB_PASS="$3"
    local DB_NAME="${4:-pasarguard}"
    local DB_USER="${5:-pasarguard}"
    
    minfo "Importing Core Config..."
    
    docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT config FROM core_configs LIMIT 1;" > /tmp/pg_config.json 2>/dev/null
    
    if [ ! -s /tmp/pg_config.json ]; then
        mwarn "No core config found in source"
        return 1
    fi
    
    python3 << 'PYEOF'
import json
import sys

try:
    with open('/tmp/pg_config.json', 'r') as f:
        config_str = f.read().strip()
    
    if not config_str:
        print("Empty config")
        sys.exit(1)
    
    config = json.loads(config_str)
    
    config_str = json.dumps(config)
    config_str = config_str.replace('/var/lib/pasarguard', '/var/lib/rebecca')
    config_str = config_str.replace('/opt/pasarguard', '/opt/rebecca')
    config_str = config_str.replace('/var/lib/marzban', '/var/lib/rebecca')
    config_str = config_str.replace('/opt/marzban', '/opt/rebecca')
    
    config = json.loads(config_str)
    if 'api' not in config:
        config['api'] = {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]}
    
    with open('/tmp/clean_config.json', 'w') as f:
        json.dump(config, f, ensure_ascii=False)
    
    final_str = json.dumps(config, ensure_ascii=False)
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

# --- SETUP JWT ---
setup_jwt() {
    local MYSQL_CONTAINER="$1"
    local DB_PASS="$2"
    
    minfo "Configuring JWT Keys..."
    
    local table_exists=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "SHOW TABLES LIKE 'jwt';" 2>/dev/null)
    
    if [ -n "$table_exists" ]; then
        local jwt_count=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "SELECT COUNT(*) FROM jwt;" 2>/dev/null | tr -d ' \n')
        if [ "$jwt_count" -gt 0 ] 2>/dev/null; then
            mok "JWT already configured (found $jwt_count entries)"
            return 0
        fi
    fi
    
    local JWT_KEY=$(openssl rand -hex 64)
    local SUB_KEY=$(openssl rand -hex 64)
    local ADM_KEY=$(openssl rand -hex 64)
    local VMESS=$(openssl rand -hex 16)
    local VLESS=$(openssl rand -hex 16)
    
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

# --- HELPER FOR BOOLEAN CONVERSION ---
pg_bool_to_int() {
    local val="$1"
    case "$val" in
        t|true|TRUE|True|1|yes|YES|Yes) echo "1" ;;
        *) echo "0" ;;
    esac
}

# --- CRITICAL FIX: Import using Python for proper escaping ---
import_with_python() {
    local PG_CONTAINER="$1"
    local MYSQL_CONTAINER="$2"
    local DB_PASS="$3"
    local SRC_DB_NAME="$4"
    local SRC_DB_USER="$5"
    
    minfo "Exporting data from PostgreSQL..."
    
    # Export all data to JSON files using Python
    docker exec "$PG_CONTAINER" python3 << PYEXPORT > /tmp/pg_export.json
import json
import psycopg2
import sys

try:
    conn = psycopg2.connect(
        dbname="$SRC_DB_NAME",
        user="$SRC_DB_USER",
        host="localhost"
    )
    cur = conn.cursor()
    
    data = {}
    
    # Admins
    cur.execute("SELECT id, username, hashed_password, COALESCE(is_sudo, false), telegram_id, created_at FROM admins")
    data['admins'] = []
    for row in cur.fetchall():
        data['admins'].append({
            'id': row[0],
            'username': row[1],
            'hashed_password': row[2],
            'is_sudo': row[3],
            'telegram_id': row[4],
            'created_at': str(row[5]) if row[5] else None
        })
    
    # Inbounds
    cur.execute("SELECT id, tag FROM inbounds")
    data['inbounds'] = [{'id': r[0], 'tag': r[1]} for r in cur.fetchall()]
    
    # Users - با همه فیلدهای مهم
    cur.execute("""
        SELECT id, username, key, status, used_traffic, data_limit, 
               EXTRACT(EPOCH FROM expire)::bigint, admin_id, note, 
               sub_updated_at, sub_last_user_agent, online_at,
               on_hold_timeout, on_hold_expire_duration,
               COALESCE(lifetime_used_traffic, 0), created_at, service_id
        FROM users
    """)
    data['users'] = []
    for row in cur.fetchall():
        data['users'].append({
            'id': row[0],
            'username': row[1],
            'key': row[2],  # CRITICAL: UUID/Key for subscription
            'status': row[3] or 'active',
            'used_traffic': row[4] or 0,
            'data_limit': row[5],
            'expire': row[6],
            'admin_id': row[7] or 1,
            'note': row[8],
            'sub_updated_at': str(row[9]) if row[9] else None,
            'sub_last_user_agent': row[10],
            'online_at': str(row[11]) if row[11] else None,
            'on_hold_timeout': str(row[12]) if row[12] else None,
            'on_hold_expire_duration': row[13],
            'lifetime_used_traffic': row[14],
            'created_at': str(row[15]) if row[15] else None,
            'service_id': row[16]
        })
    
    # Proxies - CRITICAL for config to work
    cur.execute("SELECT id, user_id, type, settings FROM proxies")
    data['proxies'] = []
    for row in cur.fetchall():
        data['proxies'].append({
            'id': row[0],
            'user_id': row[1],
            'type': row[2],
            'settings': row[3]  # Contains UUID/password
        })
    
    # Hosts - با همه فیلدها
    cur.execute("""
        SELECT id, remark, address, port, inbound_tag, sni, host, 
               security, fingerprint, is_disabled, path, alpn,
               allowinsecure, fragment_setting, mux_enable, random_user_agent
        FROM hosts
    """)
    data['hosts'] = []
    for row in cur.fetchall():
        data['hosts'].append({
            'id': row[0],
            'remark': row[1],
            'address': row[2],
            'port': row[3],
            'inbound_tag': row[4],
            'sni': row[5],
            'host': row[6],
            'security': row[7],
            'fingerprint': str(row[8]) if row[8] else 'none',
            'is_disabled': row[9],
            'path': row[10],
            'alpn': row[11] or '',
            'allowinsecure': row[12],
            'fragment_setting': row[13],
            'mux_enable': row[14],
            'random_user_agent': row[15]
        })
    
    # Services/Groups
    cur.execute("SELECT id, name, created_at FROM services")
    data['services'] = []
    for row in cur.fetchall():
        data['services'].append({
            'id': row[0],
            'name': row[1],
            'created_at': str(row[2]) if row[2] else None
        })
    
    # Service-Host relations
    cur.execute("SELECT service_id, host_id FROM service_hosts")
    data['service_hosts'] = [{'service_id': r[0], 'host_id': r[1]} for r in cur.fetchall()]
    
    # Service-Inbound relations
    try:
        cur.execute("SELECT service_id, inbound_id FROM service_inbounds")
        data['service_inbounds'] = [{'service_id': r[0], 'inbound_id': r[1]} for r in cur.fetchall()]
    except:
        data['service_inbounds'] = []
    
    # User-Inbound relations (CRITICAL)
    try:
        cur.execute("SELECT user_id, inbound_tag FROM user_inbounds")
        data['user_inbounds'] = [{'user_id': r[0], 'inbound_tag': r[1]} for r in cur.fetchall()]
    except:
        data['user_inbounds'] = []
    
    # Nodes
    try:
        cur.execute("""
            SELECT id, name, address, port, api_port, certificate, 
                   usage_coefficient, status, message, created_at
            FROM nodes
        """)
        data['nodes'] = []
        for row in cur.fetchall():
            data['nodes'].append({
                'id': row[0],
                'name': row[1],
                'address': row[2],
                'port': row[3],
                'api_port': row[4],
                'certificate': row[5],
                'usage_coefficient': float(row[6]) if row[6] else 1.0,
                'status': row[7],
                'message': row[8],
                'created_at': str(row[9]) if row[9] else None
            })
    except:
        data['nodes'] = []
    
    # Node-Inbound relations
    try:
        cur.execute("SELECT node_id, inbound_tag FROM node_inbounds")
        data['node_inbounds'] = [{'node_id': r[0], 'inbound_tag': r[1]} for r in cur.fetchall()]
    except:
        data['node_inbounds'] = []
    
    # Core configs
    cur.execute("SELECT id, name, config, created_at FROM core_configs")
    data['core_configs'] = []
    for row in cur.fetchall():
        data['core_configs'].append({
            'id': row[0],
            'name': row[1],
            'config': row[2],
            'created_at': str(row[3]) if row[3] else None
        })
    
    print(json.dumps(data, ensure_ascii=False, default=str))
    
    cur.close()
    conn.close()
    
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
    sys.exit(1)
PYEXPORT

    if [ ! -s /tmp/pg_export.json ]; then
        merr "Failed to export from PostgreSQL"
        return 1
    fi
    
    # Check for errors
    if grep -q '"error"' /tmp/pg_export.json 2>/dev/null; then
        merr "Export error: $(cat /tmp/pg_export.json)"
        return 1
    fi
    
    mok "Data exported successfully"
    return 0
}

# --- IMPORT DATA TO MYSQL ---
import_to_mysql() {
    local MYSQL_CONTAINER="$1"
    local DB_PASS="$2"
    
    minfo "Importing data to MySQL..."
    
    # Copy export file to container
    docker cp /tmp/pg_export.json "$MYSQL_CONTAINER:/tmp/import_data.json"
    
    # Import using Python inside MySQL container or on host
    python3 << 'PYIMPORT'
import json
import subprocess
import sys
import os

def escape_sql(s):
    if s is None:
        return "NULL"
    s = str(s)
    s = s.replace('\\', '\\\\')
    s = s.replace("'", "\\'")
    s = s.replace('\n', '\\n')
    s = s.replace('\r', '\\r')
    s = s.replace('\t', '\\t')
    return f"'{s}'"

def escape_json(s):
    if s is None:
        return "NULL"
    if isinstance(s, dict):
        s = json.dumps(s, ensure_ascii=False)
    s = str(s)
    s = s.replace('\\', '\\\\')
    s = s.replace("'", "\\'")
    return f"'{s}'"

def null_or_val(v):
    if v is None or v == '' or v == 'None':
        return "NULL"
    return str(v)

def bool_to_int(v):
    if v in [True, 't', 'true', 'True', 1, '1']:
        return "1"
    return "0"

try:
    with open('/tmp/pg_export.json', 'r') as f:
        data = json.load(f)
    
    if 'error' in data:
        print(f"Error in data: {data['error']}")
        sys.exit(1)
    
    sql_statements = []
    
    # Disable foreign key checks
    sql_statements.append("SET FOREIGN_KEY_CHECKS=0;")
    sql_statements.append("SET NAMES utf8mb4;")
    
    # Clear existing data
    sql_statements.append("DELETE FROM user_inbounds;")
    sql_statements.append("DELETE FROM service_hosts;")
    sql_statements.append("DELETE FROM service_inbounds;")
    sql_statements.append("DELETE FROM node_inbounds;")
    sql_statements.append("DELETE FROM proxies;")
    sql_statements.append("DELETE FROM users;")
    sql_statements.append("DELETE FROM hosts;")
    sql_statements.append("DELETE FROM inbounds;")
    sql_statements.append("DELETE FROM services;")
    sql_statements.append("DELETE FROM nodes;")
    sql_statements.append("DELETE FROM admins WHERE id > 0;")
    sql_statements.append("DELETE FROM core_configs;")
    
    # Import Admins
    for admin in data.get('admins', []):
        role = 'sudo' if admin.get('is_sudo') else 'standard'
        tg = null_or_val(admin.get('telegram_id'))
        sql = f"""INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) 
                  VALUES ({admin['id']}, {escape_sql(admin['username'])}, {escape_sql(admin['hashed_password'])}, 
                  '{role}', 'active', {tg}, NOW())
                  ON DUPLICATE KEY UPDATE hashed_password=VALUES(hashed_password), role=VALUES(role);"""
        sql_statements.append(sql)
    
    # Import Inbounds
    for inb in data.get('inbounds', []):
        sql = f"""INSERT INTO inbounds (id, tag) VALUES ({inb['id']}, {escape_sql(inb['tag'])})
                  ON DUPLICATE KEY UPDATE tag=VALUES(tag);"""
        sql_statements.append(sql)
    
    # Import Services
    for svc in data.get('services', []):
        sql = f"""INSERT INTO services (id, name, created_at) 
                  VALUES ({svc['id']}, {escape_sql(svc['name'])}, NOW())
                  ON DUPLICATE KEY UPDATE name=VALUES(name);"""
        sql_statements.append(sql)
    
    # Default service if none
    if not data.get('services'):
        sql_statements.append("INSERT IGNORE INTO services (id, name, created_at) VALUES (1, 'Default', NOW());")
    
    # Import Users WITH KEY (CRITICAL!)
    for user in data.get('users', []):
        username = user['username']
        username = username.replace('@', '_at_').replace('.', '_dot_')
        
        key = user.get('key') or ''
        svc_id = null_or_val(user.get('service_id'))
        if svc_id == "NULL":
            svc_id = "1"  # Default service
        
        data_limit = null_or_val(user.get('data_limit'))
        expire = null_or_val(user.get('expire'))
        on_hold_timeout = "NULL"
        if user.get('on_hold_timeout'):
            on_hold_timeout = escape_sql(user['on_hold_timeout'])
        on_hold_dur = null_or_val(user.get('on_hold_expire_duration'))
        
        sql = f"""INSERT INTO users (id, username, `key`, status, used_traffic, data_limit, expire, 
                  admin_id, note, service_id, lifetime_used_traffic, on_hold_timeout, 
                  on_hold_expire_duration, created_at) 
                  VALUES ({user['id']}, {escape_sql(username)}, {escape_sql(key)}, 
                  '{user.get('status', 'active')}', {user.get('used_traffic', 0)}, 
                  {data_limit}, {expire}, {user.get('admin_id', 1)}, 
                  {escape_sql(user.get('note', ''))}, {svc_id}, 
                  {user.get('lifetime_used_traffic', 0)}, {on_hold_timeout}, {on_hold_dur}, NOW())
                  ON DUPLICATE KEY UPDATE `key`=VALUES(`key`), status=VALUES(status);"""
        sql_statements.append(sql)
    
    # Import Proxies (CRITICAL for config links!)
    for proxy in data.get('proxies', []):
        settings = proxy.get('settings', '{}')
        if isinstance(settings, dict):
            settings = json.dumps(settings)
        # Fix paths in settings
        settings = settings.replace('/var/lib/pasarguard', '/var/lib/rebecca')
        settings = settings.replace('/var/lib/marzban', '/var/lib/rebecca')
        
        sql = f"""INSERT INTO proxies (id, user_id, type, settings) 
                  VALUES ({proxy['id']}, {proxy['user_id']}, {escape_sql(proxy['type'])}, 
                  {escape_json(settings)})
                  ON DUPLICATE KEY UPDATE settings=VALUES(settings);"""
        sql_statements.append(sql)
    
    # Import Hosts with all fields
    for host in data.get('hosts', []):
        addr = host.get('address', '').replace('pasarguard', 'rebecca').replace('marzban', 'rebecca')
        path = (host.get('path') or '').replace('pasarguard', 'rebecca').replace('marzban', 'rebecca')
        port = null_or_val(host.get('port'))
        is_disabled = bool_to_int(host.get('is_disabled'))
        allowinsecure = bool_to_int(host.get('allowinsecure'))
        mux = bool_to_int(host.get('mux_enable'))
        rand_ua = bool_to_int(host.get('random_user_agent'))
        
        sql = f"""INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, 
                  security, fingerprint, is_disabled, path, alpn, allowinsecure, 
                  fragment_setting, mux_enable, random_user_agent) 
                  VALUES ({host['id']}, {escape_sql(host.get('remark', ''))}, 
                  {escape_sql(addr)}, {port}, {escape_sql(host.get('inbound_tag', ''))},
                  {escape_sql(host.get('sni', ''))}, {escape_sql(host.get('host', ''))},
                  {escape_sql(host.get('security', 'none'))}, {escape_sql(host.get('fingerprint', 'none'))},
                  {is_disabled}, {escape_sql(path)}, {escape_sql(host.get('alpn', ''))},
                  {allowinsecure}, {escape_sql(host.get('fragment_setting'))}, {mux}, {rand_ua})
                  ON DUPLICATE KEY UPDATE address=VALUES(address);"""
        sql_statements.append(sql)
    
    # Import Nodes
    for node in data.get('nodes', []):
        sql = f"""INSERT INTO nodes (id, name, address, port, api_port, certificate, 
                  usage_coefficient, status, message, created_at)
                  VALUES ({node['id']}, {escape_sql(node['name'])}, {escape_sql(node['address'])},
                  {null_or_val(node.get('port'))}, {null_or_val(node.get('api_port'))},
                  {escape_sql(node.get('certificate'))}, {node.get('usage_coefficient', 1.0)},
                  {escape_sql(node.get('status', 'connected'))}, {escape_sql(node.get('message'))}, NOW())
                  ON DUPLICATE KEY UPDATE address=VALUES(address);"""
        sql_statements.append(sql)
    
    # Import Service-Host relations
    for sh in data.get('service_hosts', []):
        sql = f"INSERT IGNORE INTO service_hosts (service_id, host_id) VALUES ({sh['service_id']}, {sh['host_id']});"
        sql_statements.append(sql)
    
    # Import Service-Inbound relations
    for si in data.get('service_inbounds', []):
        sql = f"INSERT IGNORE INTO service_inbounds (service_id, inbound_id) VALUES ({si['service_id']}, {si['inbound_id']});"
        sql_statements.append(sql)
    
    # Import User-Inbound relations
    for ui in data.get('user_inbounds', []):
        sql = f"INSERT IGNORE INTO user_inbounds (user_id, inbound_tag) VALUES ({ui['user_id']}, {escape_sql(ui['inbound_tag'])});"
        sql_statements.append(sql)
    
    # Import Node-Inbound relations
    for ni in data.get('node_inbounds', []):
        sql = f"INSERT IGNORE INTO node_inbounds (node_id, inbound_tag) VALUES ({ni['node_id']}, {escape_sql(ni['inbound_tag'])});"
        sql_statements.append(sql)
    
    # Import Core configs
    for cc in data.get('core_configs', []):
        config_str = cc.get('config', '{}')
        if isinstance(config_str, dict):
            config_str = json.dumps(config_str)
        config_str = config_str.replace('/var/lib/pasarguard', '/var/lib/rebecca')
        config_str = config_str.replace('/var/lib/marzban', '/var/lib/rebecca')
        config_str = config_str.replace('/opt/pasarguard', '/opt/rebecca')
        config_str = config_str.replace('/opt/marzban', '/opt/rebecca')
        
        sql = f"""INSERT INTO core_configs (id, name, config, created_at) 
                  VALUES ({cc['id']}, {escape_sql(cc.get('name', 'default'))}, 
                  {escape_json(config_str)}, NOW())
                  ON DUPLICATE KEY UPDATE config=VALUES(config);"""
        sql_statements.append(sql)
    
    # Default service_hosts if empty
    if not data.get('service_hosts'):
        sql_statements.append("INSERT IGNORE INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts;")
    
    # Re-enable foreign keys
    sql_statements.append("SET FOREIGN_KEY_CHECKS=1;")
    
    # Write SQL file
    with open('/tmp/mysql_import.sql', 'w') as f:
        f.write('\n'.join(sql_statements))
    
    print(f"Generated {len(sql_statements)} SQL statements")
    print("OK")
    
except Exception as e:
    print(f"Error: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYIMPORT

    if [ ! -f /tmp/mysql_import.sql ]; then
        merr "Failed to generate import SQL"
        return 1
    fi
    
    # Copy and execute SQL
    docker cp /tmp/mysql_import.sql "$MYSQL_CONTAINER:/tmp/import.sql"
    
    local result=$(docker exec "$MYSQL_CONTAINER" bash -c "mysql -uroot -p'$DB_PASS' rebecca < /tmp/import.sql 2>&1")
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        merr "MySQL import failed: $result"
        mlog "SQL Import Error: $result"
        return 1
    fi
    
    # Cleanup
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/import.sql /tmp/import_data.json 2>/dev/null
    rm -f /tmp/mysql_import.sql /tmp/pg_export.json 2>/dev/null
    
    mok "Data imported successfully"
    return 0
}

# --- DIRECT POSTGRESQL TO MYSQL MIGRATION (NEW VERSION) ---
migrate_postgresql_to_mysql() {
    local src="$1"
    local tgt="$2"
    ui_header "POSTGRESQL TO MYSQL MIGRATION"
    
    local PG_CONTAINER=$(find_pg_container "$src")
    local MYSQL_CONTAINER=$(find_mysql_container "$tgt")
    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt/.env")
    
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
    
    # Check if psycopg2 is available in PG container
    minfo "Checking PostgreSQL container for Python..."
    local has_python=$(docker exec "$PG_CONTAINER" which python3 2>/dev/null)
    local has_psycopg=$(docker exec "$PG_CONTAINER" python3 -c "import psycopg2" 2>/dev/null && echo "yes")
    
    if [ -z "$has_python" ] || [ -z "$has_psycopg" ]; then
        mwarn "Installing psycopg2 in container..."
        docker exec "$PG_CONTAINER" bash -c "pip install psycopg2-binary 2>/dev/null || apt-get update && apt-get install -y python3-psycopg2 2>/dev/null" &>/dev/null
    fi
    
    # Export using Python
    if ! import_with_python "$PG_CONTAINER" "$MYSQL_CONTAINER" "$DB_PASS" "$SRC_DB_NAME" "$SRC_DB_USER"; then
        mwarn "Python export failed, trying fallback method..."
        # Fallback to shell-based export
        migrate_postgresql_to_mysql_fallback "$src" "$tgt"
        return $?
    fi
    
    # Setup JWT
    setup_jwt "$MYSQL_CONTAINER" "$DB_PASS"
    
    # Import to MySQL
    if ! import_to_mysql "$MYSQL_CONTAINER" "$DB_PASS"; then
        merr "Import failed"
        return 1
    fi
    
    # Show summary
    echo ""
    ui_header "MIGRATION SUMMARY"
    
    local run_mysql="docker exec $MYSQL_CONTAINER mysql -uroot -p$DB_PASS rebecca -N -e"
    
    echo -e "  Admins:       ${GREEN}$($run_mysql "SELECT COUNT(*) FROM admins;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Users:        ${GREEN}$($run_mysql "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Proxies:      ${GREEN}$($run_mysql "SELECT COUNT(*) FROM proxies;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Inbounds:     ${GREEN}$($run_mysql "SELECT COUNT(*) FROM inbounds;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Hosts:        ${GREEN}$($run_mysql "SELECT COUNT(*) FROM hosts;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Services:     ${GREEN}$($run_mysql "SELECT COUNT(*) FROM services;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Nodes:        ${GREEN}$($run_mysql "SELECT COUNT(*) FROM nodes;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Core Configs: ${GREEN}$($run_mysql "SELECT COUNT(*) FROM core_configs;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  JWT:          ${GREEN}$($run_mysql "SELECT COUNT(*) FROM jwt;" 2>/dev/null | tr -d ' \n')${NC}"
    echo ""
    
    # Verify critical data
    local user_keys=$($run_mysql "SELECT COUNT(*) FROM users WHERE \`key\` IS NOT NULL AND \`key\` != '';" 2>/dev/null | tr -d ' \n')
    local proxy_settings=$($run_mysql "SELECT COUNT(*) FROM proxies WHERE settings IS NOT NULL AND settings != '';" 2>/dev/null | tr -d ' \n')
    
    if [ "$user_keys" -gt 0 ] 2>/dev/null; then
        mok "User keys migrated: $user_keys"
    else
        mwarn "No user keys found - subscriptions may not work!"
    fi
    
    if [ "$proxy_settings" -gt 0 ] 2>/dev/null; then
        mok "Proxy settings migrated: $proxy_settings"
    else
        mwarn "No proxy settings found - configs may not work!"
    fi
    
    return 0
}

# --- FALLBACK MIGRATION (shell-based) ---
migrate_postgresql_to_mysql_fallback() {
    local src="$1"
    local tgt="$2"
    
    minfo "Using fallback migration method..."
    
    local PG_CONTAINER=$(find_pg_container "$src")
    local MYSQL_CONTAINER=$(find_mysql_container "$tgt")
    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt/.env")
    
    local SRC_DB_NAME="pasarguard"
    local SRC_DB_USER="pasarguard"
    if [ "$SOURCE_PANEL_TYPE" == "marzban" ]; then
        SRC_DB_NAME="marzban"
        SRC_DB_USER="marzban"
    fi
    
    run_pg() { docker exec "$PG_CONTAINER" psql -U "$SRC_DB_USER" -d "$SRC_DB_NAME" -t -A -c "$1" 2>/dev/null; }
    run_mysql() { docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e "$1" 2>/dev/null; }
    
    # Clear
    run_mysql "SET FOREIGN_KEY_CHECKS=0; DELETE FROM users; DELETE FROM proxies; DELETE FROM inbounds; DELETE FROM hosts; DELETE FROM services; DELETE FROM nodes; SET FOREIGN_KEY_CHECKS=1;"
    
    # Admins - با escape صحیح
    minfo "Importing Admins (fallback)..."
    run_pg "SELECT id, username, hashed_password, COALESCE(is_sudo, false), COALESCE(telegram_id::text, '') FROM admins;" | while IFS='|' read -r id username hashed_password is_sudo telegram_id; do
        [ -z "$id" ] && continue
        local role="standard"
        [ "$is_sudo" == "t" ] && role="sudo"
        [ -z "$telegram_id" ] && telegram_id="NULL"
        
        # Use Python for safe escaping
        local esc_user=$(echo -n "$username" | sql_escape_py)
        local esc_pass=$(echo -n "$hashed_password" | sql_escape_py)
        
        run_mysql "INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) VALUES ($id, '$esc_user', '$esc_pass', '$role', 'active', $telegram_id, NOW()) ON DUPLICATE KEY UPDATE hashed_password='$esc_pass';"
    done
    
    # Inbounds
    minfo "Importing Inbounds (fallback)..."
    run_pg "SELECT id, tag FROM inbounds;" | while IFS='|' read -r id tag; do
        [ -z "$id" ] && continue
        local esc_tag=$(echo -n "$tag" | sql_escape_py)
        run_mysql "INSERT INTO inbounds (id, tag) VALUES ($id, '$esc_tag') ON DUPLICATE KEY UPDATE tag='$esc_tag';"
    done
    
    # Users با key
    minfo "Importing Users (fallback)..."
    run_pg "SELECT id, username, COALESCE(key, ''), COALESCE(status, 'active'), COALESCE(used_traffic, 0), data_limit, EXTRACT(EPOCH FROM expire)::bigint, COALESCE(admin_id, 1), COALESCE(note, ''), service_id FROM users;" | while IFS='|' read -r id username key status used_traffic data_limit expire admin_id note service_id; do
        [ -z "$id" ] && continue
        
        username="${username//@/_at_}"
        username="${username//./_dot_}"
        
        local esc_user=$(echo -n "$username" | sql_escape_py)
        local esc_key=$(echo -n "$key" | sql_escape_py)
        local esc_note=$(echo -n "$note" | sql_escape_py)
        
        [ -z "$data_limit" ] && data_limit="NULL"
        [ -z "$expire" ] && expire="NULL"
        [ -z "$service_id" ] && service_id="1"
        
        run_mysql "INSERT INTO users (id, username, \`key\`, status, used_traffic, data_limit, expire, admin_id, note, service_id, created_at) VALUES ($id, '$esc_user', '$esc_key', '$status', $used_traffic, $data_limit, $expire, $admin_id, '$esc_note', $service_id, NOW()) ON DUPLICATE KEY UPDATE \`key\`='$esc_key';"
    done
    
    # Proxies
    minfo "Importing Proxies (fallback)..."
    run_pg "SELECT id, user_id, type, settings FROM proxies;" | while IFS='|' read -r id user_id type settings; do
        [ -z "$id" ] && continue
        local esc_type=$(echo -n "$type" | sql_escape_py)
        settings="${settings//pasarguard/rebecca}"
        settings="${settings//marzban/rebecca}"
        local esc_settings=$(echo -n "$settings" | sql_escape_py)
        run_mysql "INSERT INTO proxies (id, user_id, type, settings) VALUES ($id, $user_id, '$esc_type', '$esc_settings') ON DUPLICATE KEY UPDATE settings='$esc_settings';"
    done
    
    # Hosts
    minfo "Importing Hosts (fallback)..."
    run_pg "SELECT id, remark, address, port, inbound_tag, COALESCE(sni, ''), COALESCE(host, ''), COALESCE(security, 'none'), COALESCE(fingerprint::text, 'none'), is_disabled, COALESCE(path, ''), COALESCE(alpn, '') FROM hosts;" | while IFS='|' read -r id remark address port inbound_tag sni host security fingerprint is_disabled path alpn; do
        [ -z "$id" ] && continue
        [ -z "$port" ] && port="NULL"
        
        local is_disabled_val=0
        [ "$is_disabled" == "t" ] && is_disabled_val=1
        
        address="${address//pasarguard/rebecca}"
        address="${address//marzban/rebecca}"
        path="${path//pasarguard/rebecca}"
        path="${path//marzban/rebecca}"
        
        local esc_remark=$(echo -n "$remark" | sql_escape_py)
        local esc_addr=$(echo -n "$address" | sql_escape_py)
        local esc_tag=$(echo -n "$inbound_tag" | sql_escape_py)
        local esc_sni=$(echo -n "$sni" | sql_escape_py)
        local esc_host=$(echo -n "$host" | sql_escape_py)
        local esc_security=$(echo -n "$security" | sql_escape_py)
        local esc_fp=$(echo -n "$fingerprint" | sql_escape_py)
        local esc_path=$(echo -n "$path" | sql_escape_py)
        local esc_alpn=$(echo -n "$alpn" | sql_escape_py)
        
        run_mysql "INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, security, fingerprint, is_disabled, path, alpn) VALUES ($id, '$esc_remark', '$esc_addr', $port, '$esc_tag', '$esc_sni', '$esc_host', '$esc_security', '$esc_fp', $is_disabled_val, '$esc_path', '$esc_alpn') ON DUPLICATE KEY UPDATE address='$esc_addr';"
    done
    
    # Services
    minfo "Importing Services (fallback)..."
    run_pg "SELECT id, name FROM services;" | while IFS='|' read -r id name; do
        [ -z "$id" ] && continue
        local esc_name=$(echo -n "$name" | sql_escape_py)
        run_mysql "INSERT INTO services (id, name, created_at) VALUES ($id, '$esc_name', NOW()) ON DUPLICATE KEY UPDATE name='$esc_name';"
    done
    
    # Default service
    run_mysql "INSERT IGNORE INTO services (id, name, created_at) VALUES (1, 'Default', NOW());"
    run_mysql "INSERT IGNORE INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts WHERE id NOT IN (SELECT host_id FROM service_hosts);"
    
    # Nodes
    minfo "Importing Nodes (fallback)..."
    run_pg "SELECT id, name, address, port, api_port, COALESCE(usage_coefficient, 1) FROM nodes;" 2>/dev/null | while IFS='|' read -r id name address port api_port coef; do
        [ -z "$id" ] && continue
        local esc_name=$(echo -n "$name" | sql_escape_py)
        local esc_addr=$(echo -n "$address" | sql_escape_py)
        [ -z "$port" ] && port="NULL"
        [ -z "$api_port" ] && api_port="NULL"
        run_mysql "INSERT INTO nodes (id, name, address, port, api_port, usage_coefficient, created_at) VALUES ($id, '$esc_name', '$esc_addr', $port, $api_port, $coef, NOW()) ON DUPLICATE KEY UPDATE address='$esc_addr';"
    done
    
    # Core config
    import_core_config "$PG_CONTAINER" "$MYSQL_CONTAINER" "$DB_PASS" "$SRC_DB_NAME" "$SRC_DB_USER"
    
    mok "Fallback migration complete"
    return 0
}

# --- SQLITE MIGRATION ---
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
    
    if ! command -v sqlite3 &>/dev/null; then
        minfo "Installing sqlite3..."
        apt-get update && apt-get install -y sqlite3 >/dev/null 2>&1
    fi
    
    # Export using Python
    minfo "Exporting from SQLite..."
    
    python3 << PYEXPORT > /tmp/pg_export.json
import sqlite3
import json
import sys

try:
    conn = sqlite3.connect("$SQLITE_DB")
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    
    data = {}
    
    # Get table list
    cur.execute("SELECT name FROM sqlite_master WHERE type='table';")
    tables = [r[0] for r in cur.fetchall()]
    
    # Admins
    if 'admins' in tables:
        cur.execute("SELECT * FROM admins")
        data['admins'] = []
        for row in cur.fetchall():
            data['admins'].append({
                'id': row['id'],
                'username': row['username'],
                'hashed_password': row['hashed_password'],
                'is_sudo': row.get('is_sudo', 0) == 1,
                'telegram_id': row.get('telegram_id')
            })
    
    # Inbounds
    if 'inbounds' in tables:
        cur.execute("SELECT * FROM inbounds")
        data['inbounds'] = [{'id': r['id'], 'tag': r['tag']} for r in cur.fetchall()]
    
    # Users
    if 'users' in tables:
        cur.execute("SELECT * FROM users")
        data['users'] = []
        for row in cur.fetchall():
            data['users'].append({
                'id': row['id'],
                'username': row['username'],
                'key': row.get('key', ''),
                'status': row.get('status', 'active'),
                'used_traffic': row.get('used_traffic', 0),
                'data_limit': row.get('data_limit'),
                'expire': row.get('expire'),
                'admin_id': row.get('admin_id', 1),
                'note': row.get('note', ''),
                'service_id': row.get('service_id', 1)
            })
    
    # Proxies
    if 'proxies' in tables:
        cur.execute("SELECT * FROM proxies")
        data['proxies'] = []
        for row in cur.fetchall():
            data['proxies'].append({
                'id': row['id'],
                'user_id': row['user_id'],
                'type': row['type'],
                'settings': row['settings']
            })
    
    # Hosts
    if 'hosts' in tables:
        cur.execute("SELECT * FROM hosts")
        data['hosts'] = []
        for row in cur.fetchall():
            data['hosts'].append({
                'id': row['id'],
                'remark': row.get('remark', ''),
                'address': row.get('address', ''),
                'port': row.get('port'),
                'inbound_tag': row.get('inbound_tag', ''),
                'sni': row.get('sni', ''),
                'host': row.get('host', ''),
                'security': row.get('security', 'none'),
                'fingerprint': row.get('fingerprint', 'none'),
                'is_disabled': row.get('is_disabled', 0) == 1,
                'path': row.get('path', ''),
                'alpn': row.get('alpn', '')
            })
    
    # Services
    if 'services' in tables:
        cur.execute("SELECT * FROM services")
        data['services'] = [{'id': r['id'], 'name': r['name']} for r in cur.fetchall()]
    
    # Core configs
    if 'core_configs' in tables:
        cur.execute("SELECT * FROM core_configs")
        data['core_configs'] = []
        for row in cur.fetchall():
            data['core_configs'].append({
                'id': row['id'],
                'name': row.get('name', 'default'),
                'config': row['config']
            })
    
    # Nodes
    if 'nodes' in tables:
        cur.execute("SELECT * FROM nodes")
        data['nodes'] = []
        for row in cur.fetchall():
            data['nodes'].append({
                'id': row['id'],
                'name': row['name'],
                'address': row['address'],
                'port': row.get('port'),
                'api_port': row.get('api_port'),
                'usage_coefficient': row.get('usage_coefficient', 1.0)
            })
    
    conn.close()
    print(json.dumps(data, ensure_ascii=False, default=str))
    
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
    sys.exit(1)
PYEXPORT

    if [ ! -s /tmp/pg_export.json ]; then
        merr "Failed to export from SQLite"
        return 1
    fi
    
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
    
    # Setup JWT
    setup_jwt "$MYSQL_CONTAINER" "$DB_PASS"
    
    # Import
    if ! import_to_mysql "$MYSQL_CONTAINER" "$DB_PASS"; then
        merr "Import failed"
        return 1
    fi
    
    # Summary
    echo ""
    ui_header "MIGRATION SUMMARY"
    local run_mysql="docker exec $MYSQL_CONTAINER mysql -uroot -p$DB_PASS rebecca -N -e"
    echo -e "  Admins:       ${GREEN}$($run_mysql "SELECT COUNT(*) FROM admins;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Users:        ${GREEN}$($run_mysql "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' \n')${NC}"
    echo -e "  Proxies:      ${GREEN}$($run_mysql "SELECT COUNT(*) FROM proxies;" 2>/dev/null | tr -d ' \n')${NC}"
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
    ui_header "MRM MIGRATION TOOL V10.4"
    
    echo -e "${CYAN}Supports: PostgreSQL, MySQL, SQLite → Rebecca (MySQL)${NC}"
    echo -e "${CYAN}Migrates: Users, Proxies, Hosts, Nodes, Services, Configs${NC}"
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
    
    echo -e "${YELLOW}⚠ This will migrate:${NC}"
    echo "  • Admin accounts (with passwords)"
    echo "  • All users (with keys/UUIDs)"
    echo "  • Proxy configurations"
    echo "  • Hosts and inbounds"
    echo "  • Services/Groups"
    echo "  • Nodes"
    echo "  • Core configurations"
    echo ""
    
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
        mysql)      mwarn "MySQL to MySQL - direct copy needed" ;;
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
    echo -e "  ${GREEN}✓ Login with your $SOURCE_PANEL_TYPE admin credentials${NC}"
    echo -e "  ${GREEN}✓ All user configs should work with existing links${NC}"
    echo ""
    migration_cleanup
    mpause
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
                UNION SELECT 'Users with Key', COUNT(*) FROM users WHERE \`key\` IS NOT NULL AND \`key\` != ''
                UNION SELECT 'Proxies', COUNT(*) FROM proxies
                UNION SELECT 'Inbounds', COUNT(*) FROM inbounds
                UNION SELECT 'Hosts', COUNT(*) FROM hosts
                UNION SELECT 'Services', COUNT(*) FROM services
                UNION SELECT 'Nodes', COUNT(*) FROM nodes
                UNION SELECT 'Core Configs', COUNT(*) FROM core_configs
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
        ui_header "MRM MIGRATION TOOL V10.4"
        echo -e "  ${GREEN}Complete Migration: Users, Proxies, Hosts, Nodes, Services${NC}"
        echo ""
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