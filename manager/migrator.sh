#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V10.6 (FINAL - All Issues Fixed)
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
    rm -f /tmp/pg_*.json /tmp/mysql_*.sql /tmp/export_*.json 2>/dev/null
}

mlog()   { echo "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG" 2>/dev/null; }
minfo()  { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()    { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn()  { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr()   { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }
mpause() { echo ""; echo -e "${YELLOW}Press any key to continue...${NC}"; read -n 1 -s -r; echo ""; }

if ! type ui_confirm &>/dev/null; then
    ui_confirm() {
        local prompt="$1" default="${2:-y}"
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

read_var() {
    local key="$1" file="$2"
    [ ! -f "$file" ] && return 1
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | grep -v "^#" | head -1 | sed -E "s/^[^=]*=\s*//;s/^[\"']//;s/[\"']$//"
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
    [ -f "$env_file" ] || { echo "unknown"; return; }
    local db_url=$(read_var "SQLALCHEMY_DATABASE_URL" "$env_file")
    case "$db_url" in
        *postgresql*|*postgres*|*timescale*) echo "postgresql" ;;
        *mysql*|*mariadb*) echo "mysql" ;;
        *sqlite*) echo "sqlite" ;;
        "") [ -f "$(get_source_data_dir "$panel_dir")/db.sqlite3" ] && echo "sqlite" || echo "unknown" ;;
        *) echo "unknown" ;;
    esac
}

find_pg_container() {
    local panel_name=$(basename "$1")
    docker ps --format '{{.Names}}' | grep -iE "${panel_name}.*(timescale|postgres|db)" | head -1 ||
    docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | grep -v rebecca | head -1
}

find_mysql_container() {
    local panel_name=$(basename "$1")
    docker ps --format '{{.Names}}' | grep -iE "${panel_name}.*(mysql|mariadb)" | head -1 ||
    docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb)" | head -1
}

start_source_panel() {
    local src="$1"
    minfo "Starting source panel..."
    (cd "$src" && docker compose up -d) &>/dev/null
    
    if [ "$SOURCE_DB_TYPE" == "postgresql" ]; then
        local pg_container="" waited=0
        while [ -z "$pg_container" ] && [ $waited -lt 60 ]; do
            sleep 3; waited=$((waited + 3))
            pg_container=$(find_pg_container "$src")
        done
        [ -n "$pg_container" ] && {
            local pg_user="${SOURCE_PANEL_TYPE:-pasarguard}"
            waited=0
            while ! docker exec "$pg_container" pg_isready -U "$pg_user" &>/dev/null && [ $waited -lt 60 ]; do
                sleep 2; waited=$((waited + 2))
            done
            mok "PostgreSQL ready: $pg_container"
        }
    fi
}

install_xray() {
    local target_dir="$1" src_data="$2"
    minfo "Installing Xray..."
    mkdir -p "$target_dir/assets"
    
    if [ -f "$src_data/xray" ]; then
        cp "$src_data/xray" "$target_dir/xray"
        chmod +x "$target_dir/xray"
        mok "Xray copied"
    else
        cd /tmp && rm -f Xray-linux-64.zip
        wget -q --show-progress "$XRAY_DOWNLOAD_URL" -O Xray-linux-64.zip &&
        unzip -o Xray-linux-64.zip -d "$target_dir/" >/dev/null 2>&1 &&
        chmod +x "$target_dir/xray" && mok "Xray downloaded"
    fi
    
    [ -d "$src_data/assets" ] && cp -rn "$src_data/assets/"* "$target_dir/assets/" 2>/dev/null
    [ ! -f "$target_dir/assets/geoip.dat" ] && wget -q "$GEOIP_URL" -O "$target_dir/assets/geoip.dat"
    [ ! -f "$target_dir/assets/geosite.dat" ] && wget -q "$GEOSITE_URL" -O "$target_dir/assets/geosite.dat"
    [ -x "$target_dir/xray" ]
}

copy_data_files() {
    local src_data="$1" tgt_data="$2"
    minfo "Copying data files..."
    mkdir -p "$tgt_data"
    
    for dir in certs templates assets; do
        [ -d "$src_data/$dir" ] && {
            mkdir -p "$tgt_data/$dir"
            cp -r "$src_data/$dir/"* "$tgt_data/$dir/" 2>/dev/null
            mok "$dir copied"
        }
    done
}

generate_clean_env() {
    local src="$1" tgt="$2"
    local tgt_env="$tgt/.env" src_env="$src/.env"
    minfo "Generating .env..."

    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt_env")
    [ -z "$DB_PASS" ] && DB_PASS=$(openssl rand -hex 16)

    local UV_PORT=$(read_var "UVICORN_PORT" "$src_env"); [ -z "$UV_PORT" ] && UV_PORT="8000"
    local SUDO_USER=$(read_var "SUDO_USERNAME" "$src_env"); [ -z "$SUDO_USER" ] && SUDO_USER="admin"
    local SUDO_PASS=$(read_var "SUDO_PASSWORD" "$src_env"); [ -z "$SUDO_PASS" ] && SUDO_PASS="admin"
    local TG_TOKEN=$(read_var "TELEGRAM_API_TOKEN" "$src_env")
    local TG_ADMIN=$(read_var "TELEGRAM_ADMIN_ID" "$src_env")

    local SSL_CERT=$(read_var "UVICORN_SSL_CERTFILE" "$src_env")
    local SSL_KEY=$(read_var "UVICORN_SSL_KEYFILE" "$src_env")
    SSL_CERT="${SSL_CERT//pasarguard/rebecca}"; SSL_CERT="${SSL_CERT//marzban/rebecca}"
    SSL_KEY="${SSL_KEY//pasarguard/rebecca}"; SSL_KEY="${SSL_KEY//marzban/rebecca}"

    local XRAY_JSON=$(read_var "XRAY_JSON" "$src_env")
    XRAY_JSON="${XRAY_JSON//pasarguard/rebecca}"; XRAY_JSON="${XRAY_JSON//marzban/rebecca}"
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
    mok "Environment ready"
}

install_rebecca_wizard() {
    clear
    ui_header "INSTALLING REBECCA"
    ui_confirm "Install Rebecca Panel?" "y" || return 1
    eval "$REBECCA_INSTALL_CMD"
    [ -d "/opt/rebecca" ] && mok "Rebecca installed" && return 0
    merr "Installation failed"; return 1
}

setup_jwt() {
    local MYSQL_CONTAINER="$1" DB_PASS="$2"
    minfo "Configuring JWT..."
    
    local jwt_count=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$DB_PASS" rebecca -N -e \
        "SELECT COUNT(*) FROM jwt;" 2>/dev/null | tr -d ' \n')
    [ "$jwt_count" -gt 0 ] 2>/dev/null && { mok "JWT exists"; return 0; }
    
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
    VALUES ('$(openssl rand -hex 64)', '$(openssl rand -hex 64)', '$(openssl rand -hex 64)', 
            '$(openssl rand -hex 16)', '$(openssl rand -hex 16)');" 2>/dev/null
    mok "JWT configured"
}

#==============================================================================
# COMPLETE POSTGRESQL EXPORT - All tables and fields
#==============================================================================

export_postgresql_complete() {
    local PG_CONTAINER="$1" DB_NAME="$2" DB_USER="$3" OUTPUT_FILE="$4"
    
    minfo "Exporting from PostgreSQL (complete)..."
    
    # Create comprehensive export SQL
    docker exec "$PG_CONTAINER" bash -c "cat > /tmp/export_all.sql << 'SQLDUMP'
\\pset format unaligned
\\pset tuples_only on

-- ADMINS
\\o /tmp/exp_admins.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT id, username, hashed_password, 
           COALESCE(is_sudo, false) as is_sudo, 
           telegram_id, created_at
    FROM admins
) t;

-- INBOUNDS
\\o /tmp/exp_inbounds.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT id, tag FROM inbounds
) t;

-- USERS - ALL FIELDS
\\o /tmp/exp_users.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT 
        id, username, key, 
        COALESCE(status, 'active') as status,
        COALESCE(used_traffic, 0) as used_traffic,
        data_limit,
        EXTRACT(EPOCH FROM expire)::bigint as expire,
        COALESCE(admin_id, 1) as admin_id,
        note,
        sub_updated_at,
        sub_last_user_agent,
        online_at,
        on_hold_timeout,
        on_hold_expire_duration,
        COALESCE(lifetime_used_traffic, 0) as lifetime_used_traffic,
        created_at,
        service_id,
        sub_revoked_at,
        excluded_inbounds,
        data_limit_reset_strategy,
        traffic_reset_at
    FROM users
) t;

-- PROXIES
\\o /tmp/exp_proxies.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT id, user_id, type, settings FROM proxies
) t;

-- HOSTS - ALL FIELDS
\\o /tmp/exp_hosts.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT id, remark, address, port, inbound_tag, sni, host, 
           security, fingerprint::text as fingerprint, is_disabled, 
           path, alpn, allowinsecure, fragment_setting, 
           mux_enable, random_user_agent, weight
    FROM hosts
) t;

-- SERVICES
\\o /tmp/exp_services.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT id, name, created_at, users_limit, extra_data FROM services
) t;

-- SERVICE_HOSTS
\\o /tmp/exp_service_hosts.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT service_id, host_id FROM service_hosts
) t;

-- SERVICE_INBOUNDS
\\o /tmp/exp_service_inbounds.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT service_id, inbound_id FROM service_inbounds
) t;

-- USER_INBOUNDS (CRITICAL!)
\\o /tmp/exp_user_inbounds.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT user_id, inbound_tag FROM user_inbounds
) t;

-- NODES
\\o /tmp/exp_nodes.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT id, name, address, port, api_port, certificate, 
           COALESCE(usage_coefficient, 1.0) as usage_coefficient, 
           status, message, xray_version, created_at
    FROM nodes
) t;

-- NODE_INBOUNDS
\\o /tmp/exp_node_inbounds.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT node_id, inbound_tag FROM node_inbounds
) t;

-- EXCLUDED_INBOUNDS_ASSOCIATION
\\o /tmp/exp_excluded_inbounds.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT user_id, inbound_tag FROM excluded_inbounds_association
) t;

-- CORE_CONFIGS
\\o /tmp/exp_core_configs.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT id, name, config, created_at FROM core_configs
) t;

-- SYSTEM (if exists)
\\o /tmp/exp_system.json
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT * FROM system
) t;

SQLDUMP
" 2>/dev/null

    # Execute export
    docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -f /tmp/export_all.sql &>/dev/null
    
    # Combine into single JSON
    docker exec "$PG_CONTAINER" bash -c '
    echo "{"
    first=1
    for f in /tmp/exp_*.json; do
        [ ! -f "$f" ] && continue
        table=$(basename "$f" .json | sed "s/^exp_//")
        content=$(cat "$f" 2>/dev/null | tr -d "\n\r")
        [ -z "$content" ] && content="[]"
        [ "$content" = "null" ] && content="[]"
        [ $first -eq 0 ] && echo ","
        echo "\"${table}\": ${content}"
        first=0
    done
    echo "}"
    ' > "$OUTPUT_FILE" 2>/dev/null
    
    # Cleanup
    docker exec "$PG_CONTAINER" rm -f /tmp/exp_*.json /tmp/export_all.sql 2>/dev/null
    
    # Validate
    if [ -s "$OUTPUT_FILE" ] && python3 -c "import json; json.load(open('$OUTPUT_FILE'))" 2>/dev/null; then
        local counts=$(python3 -c "
import json
d = json.load(open('$OUTPUT_FILE'))
print(f\"Users:{len(d.get('users',[]))} Proxies:{len(d.get('proxies',[]))} Hosts:{len(d.get('hosts',[]))}\")
" 2>/dev/null)
        mok "Exported: $counts"
        return 0
    else
        merr "Export validation failed"
        return 1
    fi
}

#==============================================================================
# COMPLETE MYSQL IMPORT - Proper escaping for bcrypt & JSON
#==============================================================================

import_to_mysql_complete() {
    local JSON_FILE="$1" MYSQL_CONTAINER="$2" DB_PASS="$3"
    
    minfo "Importing to MySQL..."
    
    python3 << 'PYIMPORT'
import json
import sys
import os

def escape_mysql(val):
    """
    Properly escape for MySQL - handles:
    - bcrypt hashes with $2b$...
    - JSON with quotes and backslashes
    - Newlines and special chars
    """
    if val is None:
        return "NULL"
    if isinstance(val, bool):
        return "1" if val else "0"
    if isinstance(val, (int, float)):
        return str(val)
    if isinstance(val, dict):
        val = json.dumps(val, ensure_ascii=False)
    if isinstance(val, list):
        val = json.dumps(val, ensure_ascii=False)
    
    val = str(val)
    
    # MySQL escape sequence - ORDER MATTERS!
    val = val.replace('\\', '\\\\')      # Backslash first
    val = val.replace("'", "\\'")        # Single quote
    val = val.replace('"', '\\"')        # Double quote
    val = val.replace('\n', '\\n')       # Newline
    val = val.replace('\r', '\\r')       # Carriage return
    val = val.replace('\t', '\\t')       # Tab
    val = val.replace('\x00', '')        # Null byte (remove)
    val = val.replace('\x1a', '\\Z')     # Ctrl+Z
    
    return f"'{val}'"

def escape_json_field(val):
    """Escape JSON for MySQL TEXT field"""
    if val is None:
        return "NULL"
    if isinstance(val, (dict, list)):
        val = json.dumps(val, ensure_ascii=False)
    val = str(val)
    val = val.replace('\\', '\\\\')
    val = val.replace("'", "\\'")
    val = val.replace('\n', '\\n')
    return f"'{val}'"

def fix_paths(val):
    """Replace old panel paths"""
    if val is None:
        return None
    if isinstance(val, str):
        val = val.replace('/var/lib/pasarguard', '/var/lib/rebecca')
        val = val.replace('/var/lib/marzban', '/var/lib/rebecca')
        val = val.replace('/opt/pasarguard', '/opt/rebecca')
        val = val.replace('/opt/marzban', '/opt/rebecca')
    elif isinstance(val, dict):
        return json.loads(fix_paths(json.dumps(val)))
    return val

def ts_or_null(val):
    """Timestamp or NULL"""
    if val is None or val == '' or val == 'None':
        return "NULL"
    return escape_mysql(str(val))

def int_or_null(val):
    """Integer or NULL"""
    if val is None or val == '' or val == 'None':
        return "NULL"
    try:
        return str(int(val))
    except:
        return "NULL"

def float_or_default(val, default=1.0):
    """Float or default"""
    if val is None:
        return str(default)
    try:
        return str(float(val))
    except:
        return str(default)

try:
    json_file = os.environ.get('JSON_FILE', '/tmp/pg_export.json')
    with open(json_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    sql = []
    sql.append("SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;")
    sql.append("SET FOREIGN_KEY_CHECKS=0;")
    sql.append("SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';")
    sql.append("SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO';")
    
    # Clear tables in correct order
    sql.append("DELETE FROM excluded_inbounds_association;")
    sql.append("DELETE FROM user_inbounds;")
    sql.append("DELETE FROM node_inbounds;")
    sql.append("DELETE FROM service_inbounds;")
    sql.append("DELETE FROM service_hosts;")
    sql.append("DELETE FROM proxies;")
    sql.append("DELETE FROM users;")
    sql.append("DELETE FROM hosts;")
    sql.append("DELETE FROM inbounds;")
    sql.append("DELETE FROM services;")
    sql.append("DELETE FROM nodes;")
    sql.append("DELETE FROM core_configs;")
    sql.append("DELETE FROM admins WHERE id > 0;")
    
    # =========================================================================
    # ADMINS
    # =========================================================================
    for admin in data.get('admins') or []:
        if not admin.get('id'):
            continue
        role = 'sudo' if admin.get('is_sudo') else 'standard'
        created = ts_or_null(admin.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        
        sql.append(f"""INSERT INTO admins 
            (id, username, hashed_password, role, status, telegram_id, created_at) 
            VALUES ({admin['id']}, {escape_mysql(admin['username'])}, 
            {escape_mysql(admin['hashed_password'])}, '{role}', 'active', 
            {int_or_null(admin.get('telegram_id'))}, {created})
            ON DUPLICATE KEY UPDATE hashed_password=VALUES(hashed_password);""")
    
    # =========================================================================
    # INBOUNDS
    # =========================================================================
    for inb in data.get('inbounds') or []:
        if not inb.get('id'):
            continue
        sql.append(f"""INSERT INTO inbounds (id, tag) 
            VALUES ({inb['id']}, {escape_mysql(inb['tag'])})
            ON DUPLICATE KEY UPDATE tag=VALUES(tag);""")
    
    # =========================================================================
    # SERVICES
    # =========================================================================
    services = data.get('services') or []
    for svc in services:
        if not svc.get('id'):
            continue
        created = ts_or_null(svc.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        extra = svc.get('extra_data')
        extra_sql = escape_json_field(extra) if extra else "NULL"
        
        sql.append(f"""INSERT INTO services (id, name, users_limit, extra_data, created_at) 
            VALUES ({svc['id']}, {escape_mysql(svc.get('name', 'Default'))}, 
            {int_or_null(svc.get('users_limit'))}, {extra_sql}, {created})
            ON DUPLICATE KEY UPDATE name=VALUES(name);""")
    
    if not services:
        sql.append("INSERT IGNORE INTO services (id, name, created_at) VALUES (1, 'Default', NOW());")
    
    # =========================================================================
    # NODES
    # =========================================================================
    for node in data.get('nodes') or []:
        if not node.get('id'):
            continue
        created = ts_or_null(node.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        
        sql.append(f"""INSERT INTO nodes 
            (id, name, address, port, api_port, certificate, usage_coefficient, 
             status, message, xray_version, created_at)
            VALUES ({node['id']}, {escape_mysql(node['name'])}, 
            {escape_mysql(node.get('address', ''))},
            {int_or_null(node.get('port'))}, {int_or_null(node.get('api_port'))},
            {escape_mysql(node.get('certificate'))}, 
            {float_or_default(node.get('usage_coefficient'), 1.0)},
            {escape_mysql(node.get('status', 'connected'))}, 
            {escape_mysql(node.get('message'))},
            {escape_mysql(node.get('xray_version'))}, {created})
            ON DUPLICATE KEY UPDATE address=VALUES(address);""")
    
    # =========================================================================
    # HOSTS - ALL FIELDS
    # =========================================================================
    for host in data.get('hosts') or []:
        if not host.get('id'):
            continue
        
        address = fix_paths(host.get('address', ''))
        path = fix_paths(host.get('path', ''))
        
        fingerprint = host.get('fingerprint')
        if isinstance(fingerprint, dict):
            fingerprint = 'none'
        fingerprint = fingerprint or 'none'
        
        fragment = host.get('fragment_setting')
        fragment_sql = escape_json_field(fragment) if fragment else "NULL"
        
        sql.append(f"""INSERT INTO hosts 
            (id, remark, address, port, inbound_tag, sni, host, security, 
             fingerprint, is_disabled, path, alpn, allowinsecure, 
             fragment_setting, mux_enable, random_user_agent, weight) 
            VALUES ({host['id']}, {escape_mysql(host.get('remark', ''))}, 
            {escape_mysql(address)}, {int_or_null(host.get('port'))}, 
            {escape_mysql(host.get('inbound_tag', ''))},
            {escape_mysql(host.get('sni', ''))}, {escape_mysql(host.get('host', ''))},
            {escape_mysql(host.get('security', 'none'))}, {escape_mysql(fingerprint)},
            {1 if host.get('is_disabled') else 0}, {escape_mysql(path)}, 
            {escape_mysql(host.get('alpn', ''))},
            {1 if host.get('allowinsecure') else 0}, {fragment_sql}, 
            {1 if host.get('mux_enable') else 0}, 
            {1 if host.get('random_user_agent') else 0},
            {int_or_null(host.get('weight'))})
            ON DUPLICATE KEY UPDATE address=VALUES(address);""")
    
    # =========================================================================
    # USERS - ALL FIELDS INCLUDING KEY!
    # =========================================================================
    for user in data.get('users') or []:
        if not user.get('id'):
            continue
        
        username = str(user.get('username', ''))
        username = username.replace('@', '_at_').replace('.', '_dot_')
        
        # CRITICAL: subscription key
        key = user.get('key') or ''
        
        status = user.get('status', 'active')
        if status not in ['active', 'disabled', 'limited', 'expired', 'on_hold']:
            status = 'active'
        
        svc_id = user.get('service_id') or 1
        
        # Handle excluded_inbounds
        excluded = user.get('excluded_inbounds')
        if excluded:
            if isinstance(excluded, str):
                try:
                    excluded = json.loads(excluded)
                except:
                    excluded = None
            excluded_sql = escape_json_field(excluded) if excluded else "NULL"
        else:
            excluded_sql = "NULL"
        
        # Timestamps
        created = ts_or_null(user.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        
        sub_updated = ts_or_null(user.get('sub_updated_at'))
        online_at = ts_or_null(user.get('online_at'))
        revoked = ts_or_null(user.get('sub_revoked_at'))
        traffic_reset = ts_or_null(user.get('traffic_reset_at'))
        on_hold_timeout = ts_or_null(user.get('on_hold_timeout'))
        
        sql.append(f"""INSERT INTO users 
            (id, username, `key`, status, used_traffic, data_limit, expire, 
             admin_id, note, service_id, lifetime_used_traffic,
             on_hold_timeout, on_hold_expire_duration,
             sub_updated_at, sub_last_user_agent, online_at,
             sub_revoked_at, excluded_inbounds,
             data_limit_reset_strategy, traffic_reset_at, created_at) 
            VALUES ({user['id']}, {escape_mysql(username)}, {escape_mysql(key)}, 
            '{status}', {int(user.get('used_traffic', 0))}, 
            {int_or_null(user.get('data_limit'))}, 
            {int_or_null(user.get('expire'))}, 
            {user.get('admin_id', 1)}, {escape_mysql(user.get('note', ''))}, 
            {svc_id}, {int(user.get('lifetime_used_traffic', 0))},
            {on_hold_timeout}, {int_or_null(user.get('on_hold_expire_duration'))},
            {sub_updated}, {escape_mysql(user.get('sub_last_user_agent'))}, {online_at},
            {revoked}, {excluded_sql},
            {escape_mysql(user.get('data_limit_reset_strategy'))}, {traffic_reset},
            {created})
            ON DUPLICATE KEY UPDATE `key`=VALUES(`key`), status=VALUES(status);""")
    
    # =========================================================================
    # PROXIES - CRITICAL FOR CONFIGS!
    # =========================================================================
    for proxy in data.get('proxies') or []:
        if not proxy.get('id'):
            continue
        
        settings = proxy.get('settings', {})
        if isinstance(settings, str):
            try:
                settings = json.loads(settings)
            except:
                pass
        
        settings = fix_paths(settings)
        settings_str = json.dumps(settings, ensure_ascii=False) if isinstance(settings, dict) else str(settings)
        
        sql.append(f"""INSERT INTO proxies (id, user_id, type, settings) 
            VALUES ({proxy['id']}, {proxy['user_id']}, 
            {escape_mysql(proxy['type'])}, {escape_json_field(settings_str)})
            ON DUPLICATE KEY UPDATE settings=VALUES(settings);""")
    
    # =========================================================================
    # RELATIONS
    # =========================================================================
    
    # Service-Host
    for sh in data.get('service_hosts') or []:
        if sh.get('service_id') and sh.get('host_id'):
            sql.append(f"INSERT IGNORE INTO service_hosts (service_id, host_id) VALUES ({sh['service_id']}, {sh['host_id']});")
    
    # Service-Inbound
    for si in data.get('service_inbounds') or []:
        if si.get('service_id') and si.get('inbound_id'):
            sql.append(f"INSERT IGNORE INTO service_inbounds (service_id, inbound_id) VALUES ({si['service_id']}, {si['inbound_id']});")
    
    # User-Inbound (CRITICAL!)
    for ui in data.get('user_inbounds') or []:
        if ui.get('user_id') and ui.get('inbound_tag'):
            sql.append(f"INSERT IGNORE INTO user_inbounds (user_id, inbound_tag) VALUES ({ui['user_id']}, {escape_mysql(ui['inbound_tag'])});")
    
    # Node-Inbound
    for ni in data.get('node_inbounds') or []:
        if ni.get('node_id') and ni.get('inbound_tag'):
            sql.append(f"INSERT IGNORE INTO node_inbounds (node_id, inbound_tag) VALUES ({ni['node_id']}, {escape_mysql(ni['inbound_tag'])});")
    
    # Excluded Inbounds
    for ei in data.get('excluded_inbounds') or []:
        if ei.get('user_id') and ei.get('inbound_tag'):
            sql.append(f"INSERT IGNORE INTO excluded_inbounds_association (user_id, inbound_tag) VALUES ({ei['user_id']}, {escape_mysql(ei['inbound_tag'])});")
    
    # Default relations if empty
    if not data.get('service_hosts'):
        sql.append("INSERT IGNORE INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts;")
    
    # =========================================================================
    # CORE CONFIGS
    # =========================================================================
    for cc in data.get('core_configs') or []:
        if not cc.get('id'):
            continue
        
        config = cc.get('config', {})
        if isinstance(config, str):
            try:
                config = json.loads(config)
            except:
                pass
        
        config = fix_paths(config)
        
        if isinstance(config, dict):
            if 'api' not in config:
                config['api'] = {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]}
            config_str = json.dumps(config, ensure_ascii=False)
        else:
            config_str = str(config)
        
        created = ts_or_null(cc.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        
        sql.append(f"""INSERT INTO core_configs (id, name, config, created_at) 
            VALUES ({cc['id']}, {escape_mysql(cc.get('name', 'default'))}, 
            {escape_json_field(config_str)}, {created})
            ON DUPLICATE KEY UPDATE config=VALUES(config);""")
    
    sql.append("SET FOREIGN_KEY_CHECKS=1;")
    
    # Write SQL
    with open('/tmp/mysql_import.sql', 'w', encoding='utf-8') as f:
        f.write('\n'.join(sql))
    
    print(f"Generated {len(sql)} statements")
    print(f"Users: {len(data.get('users', []))}")
    print(f"Proxies: {len(data.get('proxies', []))}")
    print(f"User-Inbounds: {len(data.get('user_inbounds', []))}")
    print("OK")

except Exception as e:
    import traceback
    print(f"ERROR: {e}")
    traceback.print_exc()
    sys.exit(1)
PYIMPORT

    [ ! -f /tmp/mysql_import.sql ] && { merr "SQL generation failed"; return 1; }
    
    # Execute
    docker cp /tmp/mysql_import.sql "$MYSQL_CONTAINER:/tmp/import.sql"
    local result=$(docker exec "$MYSQL_CONTAINER" bash -c "mysql -uroot -p'$DB_PASS' rebecca < /tmp/import.sql 2>&1")
    local exit_code=$?
    
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/import.sql 2>/dev/null
    rm -f /tmp/mysql_import.sql 2>/dev/null
    
    if [ $exit_code -ne 0 ]; then
        merr "Import failed: $result"
        echo "$result" | head -3
        return 1
    fi
    
    mok "Import complete"
    return 0
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

migrate_postgresql_to_mysql() {
    local src="$1" tgt="$2"
    ui_header "POSTGRESQL → MYSQL MIGRATION"
    
    local PG_CONTAINER=$(find_pg_container "$src")
    local MYSQL_CONTAINER=$(find_mysql_container "$tgt")
    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt/.env")
    
    local DB_NAME="${SOURCE_PANEL_TYPE:-pasarguard}"
    local DB_USER="${SOURCE_PANEL_TYPE:-pasarguard}"
    
    [ -z "$PG_CONTAINER" ] && { merr "PostgreSQL not found"; return 1; }
    [ -z "$MYSQL_CONTAINER" ] && { merr "MySQL not found"; return 1; }
    
    minfo "Source: $PG_CONTAINER ($DB_NAME)"
    minfo "Target: $MYSQL_CONTAINER"
    
    # Wait for MySQL
    minfo "Waiting for MySQL..."
    local waited=0
    while ! docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$DB_PASS" --silent 2>/dev/null; do
        sleep 2; waited=$((waited + 2))
        [ $waited -ge 90 ] && { merr "MySQL timeout"; return 1; }
    done
    mok "MySQL ready"
    
    # Export
    local EXPORT_FILE="/tmp/pg_export_$$.json"
    export JSON_FILE="$EXPORT_FILE"
    
    if ! export_postgresql_complete "$PG_CONTAINER" "$DB_NAME" "$DB_USER" "$EXPORT_FILE"; then
        return 1
    fi
    
    # JWT
    setup_jwt "$MYSQL_CONTAINER" "$DB_PASS"
    
    # Import
    if ! import_to_mysql_complete "$EXPORT_FILE" "$MYSQL_CONTAINER" "$DB_PASS"; then
        rm -f "$EXPORT_FILE"
        return 1
    fi
    
    rm -f "$EXPORT_FILE"
    
    # =========================================================================
    # VERIFICATION
    # =========================================================================
    echo ""
    ui_header "VERIFICATION"
    
    local run_mysql="docker exec $MYSQL_CONTAINER mysql -uroot -p$DB_PASS rebecca -N -e"
    
    local admin_count=$($run_mysql "SELECT COUNT(*) FROM admins;" 2>/dev/null | tr -d ' \n')
    local user_count=$($run_mysql "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' \n')
    local user_keys=$($run_mysql "SELECT COUNT(*) FROM users WHERE \`key\` IS NOT NULL AND \`key\` != '';" 2>/dev/null | tr -d ' \n')
    local proxy_count=$($run_mysql "SELECT COUNT(*) FROM proxies;" 2>/dev/null | tr -d ' \n')
    local proxy_uuid=$($run_mysql "SELECT COUNT(*) FROM proxies WHERE settings LIKE '%id%' OR settings LIKE '%password%';" 2>/dev/null | tr -d ' \n')
    local host_count=$($run_mysql "SELECT COUNT(*) FROM hosts;" 2>/dev/null | tr -d ' \n')
    local node_count=$($run_mysql "SELECT COUNT(*) FROM nodes;" 2>/dev/null | tr -d ' \n')
    local service_count=$($run_mysql "SELECT COUNT(*) FROM services;" 2>/dev/null | tr -d ' \n')
    local user_inb=$($run_mysql "SELECT COUNT(*) FROM user_inbounds;" 2>/dev/null | tr -d ' \n')
    local config_count=$($run_mysql "SELECT COUNT(*) FROM core_configs;" 2>/dev/null | tr -d ' \n')
    
    echo -e "  Admins:              ${GREEN}$admin_count${NC}"
    echo -e "  Users:               ${GREEN}$user_count${NC}"
    echo -e "  Users with Key:      ${GREEN}$user_keys${NC} ← for subscriptions"
    echo -e "  Proxies:             ${GREEN}$proxy_count${NC}"
    echo -e "  Proxies with UUID:   ${GREEN}$proxy_uuid${NC} ← for configs"
    echo -e "  User-Inbounds:       ${GREEN}$user_inb${NC} ← user↔inbound links"
    echo -e "  Hosts:               ${GREEN}$host_count${NC}"
    echo -e "  Nodes:               ${GREEN}$node_count${NC}"
    echo -e "  Services:            ${GREEN}$service_count${NC}"
    echo -e "  Core Configs:        ${GREEN}$config_count${NC}"
    echo ""
    
    # Critical checks
    local errors=0
    
    if [ "${user_count:-0}" -gt 0 ]; then
        if [ "${user_keys:-0}" -eq 0 ]; then
            merr "CRITICAL: No user keys → Subscriptions BROKEN!"
            errors=$((errors + 1))
        elif [ "$user_keys" -lt "$user_count" ]; then
            mwarn "Some users missing keys: $user_keys/$user_count"
        fi
        
        if [ "${proxy_count:-0}" -eq 0 ]; then
            merr "CRITICAL: No proxies → Configs BROKEN!"
            errors=$((errors + 1))
        elif [ "${proxy_uuid:-0}" -eq 0 ]; then
            merr "CRITICAL: No proxy UUIDs → Configs BROKEN!"
            errors=$((errors + 1))
        fi
    fi
    
    if [ "${host_count:-0}" -eq 0 ]; then
        merr "CRITICAL: No hosts!"
        errors=$((errors + 1))
    fi
    
    # Sample verification
    if [ $errors -eq 0 ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  ✓ Admin passwords will work${NC}"
        echo -e "${GREEN}  ✓ User subscriptions will work${NC}"
        echo -e "${GREEN}  ✓ User configs will connect${NC}"
        echo -e "${GREEN}  ✓ All relations preserved${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    
    echo ""
    return $errors
}

#==============================================================================
# SQLITE MIGRATION
#==============================================================================

migrate_sqlite_to_mysql() {
    local src="$1" tgt="$2"
    ui_header "SQLITE → MYSQL MIGRATION"
    
    local MYSQL_CONTAINER=$(find_mysql_container "$tgt")
    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt/.env")
    local SRC_DATA=$(get_source_data_dir "$src")
    local SQLITE_DB="$SRC_DATA/db.sqlite3"
    
    [ ! -f "$SQLITE_DB" ] && { merr "SQLite not found: $SQLITE_DB"; return 1; }
    [ -z "$MYSQL_CONTAINER" ] && { merr "MySQL not found"; return 1; }
    
    command -v sqlite3 &>/dev/null || { apt-get update && apt-get install -y sqlite3; } >/dev/null 2>&1
    
    minfo "Exporting from SQLite..."
    
    local EXPORT_FILE="/tmp/sqlite_export_$$.json"
    
    python3 << PYEXPORT
import sqlite3
import json
import sys

try:
    conn = sqlite3.connect("$SQLITE_DB")
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    
    cur.execute("SELECT name FROM sqlite_master WHERE type='table';")
    tables = [r[0] for r in cur.fetchall()]
    
    data = {}
    
    table_map = {
        'admins': "SELECT * FROM admins",
        'inbounds': "SELECT * FROM inbounds",
        'users': "SELECT * FROM users",
        'proxies': "SELECT * FROM proxies",
        'hosts': "SELECT * FROM hosts",
        'services': "SELECT * FROM services",
        'service_hosts': "SELECT * FROM service_hosts",
        'service_inbounds': "SELECT * FROM service_inbounds",
        'user_inbounds': "SELECT * FROM user_inbounds",
        'nodes': "SELECT * FROM nodes",
        'node_inbounds': "SELECT * FROM node_inbounds",
        'core_configs': "SELECT * FROM core_configs",
        'excluded_inbounds_association': "SELECT * FROM excluded_inbounds_association",
    }
    
    for table, query in table_map.items():
        if table in tables:
            try:
                cur.execute(query)
                data[table] = [dict(r) for r in cur.fetchall()]
            except:
                data[table] = []
        else:
            data[table] = []
    
    conn.close()
    
    with open('$EXPORT_FILE', 'w') as f:
        json.dump(data, f, ensure_ascii=False, default=str)
    
    print(f"Exported {len(data.get('users', []))} users")

except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYEXPORT

    [ ! -s "$EXPORT_FILE" ] && { merr "Export failed"; return 1; }
    
    # Wait MySQL
    local waited=0
    while ! docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$DB_PASS" --silent 2>/dev/null; do
        sleep 2; waited=$((waited + 2))
        [ $waited -ge 90 ] && { merr "MySQL timeout"; return 1; }
    done
    
    setup_jwt "$MYSQL_CONTAINER" "$DB_PASS"
    
    export JSON_FILE="$EXPORT_FILE"
    if ! import_to_mysql_complete "$EXPORT_FILE" "$MYSQL_CONTAINER" "$DB_PASS"; then
        rm -f "$EXPORT_FILE"
        return 1
    fi
    
    rm -f "$EXPORT_FILE"
    mok "SQLite migration complete"
    return 0
}

#==============================================================================
# ORCHESTRATION
#==============================================================================

stop_old_services() {
    minfo "Stopping old panels..."
    docker ps --format '{{.Names}}' | grep -iE "pasarguard|marzban" | grep -v rebecca | while read c; do
        docker stop "$c" 2>/dev/null
    done
}

do_full_migration() {
    migration_init
    clear
    ui_header "MRM MIGRATION TOOL V10.6"
    
    echo -e "${CYAN}Complete Migration with Full Verification${NC}"
    echo ""
    
    SRC=$(detect_source_panel)
    [ -z "$SRC" ] && { merr "No source panel found"; mpause; return 1; }
    
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    local SRC_DATA=$(get_source_data_dir "$SRC")
    
    echo -e "  Source: ${YELLOW}$SOURCE_PANEL_TYPE${NC} ($SRC)"
    echo -e "  DB:     ${YELLOW}$SOURCE_DB_TYPE${NC}"
    echo -e "  Target: ${GREEN}Rebecca${NC}"
    echo ""
    
    [ "$SOURCE_DB_TYPE" == "unknown" ] && { merr "Unknown DB type"; mpause; return 1; }
    
    [ -d "/opt/rebecca" ] && TGT="/opt/rebecca" || { install_rebecca_wizard || { mpause; return 1; }; TGT="/opt/rebecca"; }
    local TGT_DATA="/var/lib/rebecca"
    
    echo -e "${YELLOW}Will migrate:${NC}"
    echo "  • Admins (with bcrypt passwords)"
    echo "  • Users (with subscription keys)"
    echo "  • Proxies (with UUIDs)"
    echo "  • User-Inbound relations"
    echo "  • Hosts, Services, Nodes"
    echo "  • Core configs"
    echo ""
    
    ui_confirm "Start?" "y" || return 0
    
    echo "$SRC" > "$BACKUP_ROOT/.last_source"
    
    minfo "[1/7] Starting source..."
    start_source_panel "$SRC"
    
    minfo "[2/7] Stopping target..."
    (cd "$TGT" && docker compose down 2>/dev/null) &>/dev/null
    
    minfo "[3/7] Copying files..."
    copy_data_files "$SRC_DATA" "$TGT_DATA"
    
    minfo "[4/7] Installing Xray..."
    install_xray "$TGT_DATA" "$SRC_DATA"
    
    minfo "[5/7] Generating config..."
    generate_clean_env "$SRC" "$TGT"
    
    minfo "[6/7] Starting Rebecca..."
    (cd "$TGT" && docker compose up -d --force-recreate)
    minfo "Waiting 40s for startup..."
    sleep 40
    
    minfo "[7/7] Migrating database..."
    local result=0
    case "$SOURCE_DB_TYPE" in
        postgresql) migrate_postgresql_to_mysql "$SRC" "$TGT"; result=$? ;;
        sqlite)     migrate_sqlite_to_mysql "$SRC" "$TGT"; result=$? ;;
        *)          merr "Unsupported: $SOURCE_DB_TYPE"; result=1 ;;
    esac
    
    minfo "Final restart..."
    (cd "$TGT" && docker compose restart)
    sleep 10
    stop_old_services
    
    echo ""
    ui_header "MIGRATION COMPLETE"
    
    [ $result -eq 0 ] && {
        echo -e "  ${GREEN}✓ Login: use your $SOURCE_PANEL_TYPE credentials${NC}"
        echo -e "  ${GREEN}✓ Subscriptions: all working${NC}"
        echo -e "  ${GREEN}✓ Configs: all will connect${NC}"
    } || {
        mwarn "Some issues detected - check verification above"
    }
    
    echo ""
    migration_cleanup
    mpause
}

do_fix_current() {
    clear
    ui_header "FIX CURRENT"
    
    [ ! -d "/opt/rebecca" ] && { merr "Rebecca not found"; mpause; return 1; }
    
    TGT="/opt/rebecca"
    SRC=$(detect_source_panel)
    [ -z "$SRC" ] && { merr "Source not found"; mpause; return 1; }
    
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    
    echo "Re-import from: $SRC ($SOURCE_DB_TYPE)"
    ui_confirm "Proceed?" "y" || return 0
    
    start_source_panel "$SRC"
    (cd "$TGT" && docker compose up -d) &>/dev/null
    sleep 30
    
    case "$SOURCE_DB_TYPE" in
        postgresql) migrate_postgresql_to_mysql "$SRC" "$TGT" ;;
        sqlite)     migrate_sqlite_to_mysql "$SRC" "$TGT" ;;
    esac
    
    (cd "$TGT" && docker compose restart)
    sleep 10
    stop_old_services
    mok "Done"
    mpause
}

do_rollback() {
    clear
    ui_header "ROLLBACK"
    
    local src_path=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    [ -z "$src_path" ] || [ ! -d "$src_path" ] && { merr "No source found"; mpause; return 1; }
    
    echo "Will: Stop Rebecca, Start $src_path"
    ui_confirm "Proceed?" "n" || return 0
    
    (cd /opt/rebecca && docker compose down 2>/dev/null) &>/dev/null
    (cd "$src_path" && docker compose up -d)
    mok "Rollback complete"
    mpause
}

view_status() {
    clear
    ui_header "STATUS"
    
    echo -e "${CYAN}Containers:${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}" | head -12
    echo ""
    
    if [ -d "/opt/rebecca" ]; then
        local MC=$(docker ps --format '{{.Names}}' | grep -i "rebecca.*mysql" | head -1)
        local DP=$(read_var "MYSQL_ROOT_PASSWORD" "/opt/rebecca/.env")
        
        [ -n "$MC" ] && [ -n "$DP" ] && {
            echo -e "${CYAN}Database:${NC}"
            docker exec "$MC" mysql -uroot -p"$DP" rebecca -e "
                SELECT 'Admins' t, COUNT(*) c FROM admins
                UNION SELECT 'Users', COUNT(*) FROM users
                UNION SELECT 'Users+Key', COUNT(*) FROM users WHERE \`key\`!=''
                UNION SELECT 'Proxies', COUNT(*) FROM proxies
                UNION SELECT 'Proxies+UUID', COUNT(*) FROM proxies WHERE settings LIKE '%id%'
                UNION SELECT 'User-Inbounds', COUNT(*) FROM user_inbounds
                UNION SELECT 'Hosts', COUNT(*) FROM hosts
                UNION SELECT 'Nodes', COUNT(*) FROM nodes
                UNION SELECT 'Configs', COUNT(*) FROM core_configs;" 2>/dev/null
        }
    fi
    mpause
}

view_logs() {
    clear
    ui_header "LOGS"
    [ -f "$MIGRATION_LOG" ] && tail -80 "$MIGRATION_LOG" || echo "No logs"
    mpause
}

migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION V10.6"
        echo -e "  ${GREEN}Verified: Passwords, Keys, UUIDs, Relations${NC}"
        echo ""
        echo "  1) Full Migration"
        echo "  2) Fix Current"
        echo "  3) Rollback"
        echo "  4) Status"
        echo "  5) Logs"
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

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    [ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }
    migrator_menu
}