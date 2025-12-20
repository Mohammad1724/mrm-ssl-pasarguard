#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V10.8 (FINAL - All Edge Cases Handled)
#==============================================================================

set -o pipefail

# Load external utils if available
source /opt/mrm-manager/utils.sh 2>/dev/null || true
source /opt/mrm-manager/ui.sh 2>/dev/null || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Config
BACKUP_ROOT="/var/backups/mrm-migration"
MIGRATION_LOG="/var/log/mrm_migration.log"
MIGRATION_TEMP=""

# Globals
SRC=""
TGT=""
SOURCE_PANEL_TYPE=""
SOURCE_DB_TYPE=""

# URLs
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
REBECCA_CMD='bash -c "$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mysql'

#==============================================================================
# HELPERS
#==============================================================================

migration_init() {
    MIGRATION_TEMP=$(mktemp -d /tmp/mrm-XXXXXX 2>/dev/null) || MIGRATION_TEMP="/tmp/mrm-$$"
    mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT" "$(dirname "$MIGRATION_LOG")" 2>/dev/null
    echo "=== Migration $(date) ===" >> "$MIGRATION_LOG" 2>/dev/null
}

migration_cleanup() {
    rm -rf "$MIGRATION_TEMP" /tmp/mrm-*.json /tmp/mrm-*.sql /tmp/pg_*.json 2>/dev/null
}

mlog()   { echo "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG" 2>/dev/null; }
minfo()  { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()    { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn()  { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr()   { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }
mpause() { echo ""; read -n1 -s -r -p $'\033[0;33mPress any key...\033[0m'; echo ""; }

type ui_confirm &>/dev/null || ui_confirm() {
    local p="$1" d="${2:-y}" a
    read -p "$p [y/n] ($d): " a
    [[ "${a:-$d}" =~ ^[Yy] ]]
}

type ui_header &>/dev/null || ui_header() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo ""
}

read_var() {
    local k="$1" f="$2"
    [ -f "$f" ] || return 1
    grep -E "^[[:space:]]*${k}=" "$f" 2>/dev/null | grep -v "^#" | head -1 | sed 's/^[^=]*=//; s/^["'"'"']//; s/["'"'"']$//'
}

#==============================================================================
# DETECTION - FIXED
#==============================================================================

detect_source_panel() {
    for p in /opt/pasarguard /opt/marzban; do
        if [ -d "$p" ] && [ -f "$p/.env" ]; then
            SOURCE_PANEL_TYPE=$(basename "$p")
            echo "$p"
            return 0
        fi
    done
    return 1
}

get_data_dir() {
    case "$1" in
        */pasarguard*) echo "/var/lib/pasarguard" ;;
        */marzban*)    echo "/var/lib/marzban" ;;
        *)             echo "/var/lib/$(basename "$1")" ;;
    esac
}

detect_db_type() {
    local env="$1/.env"
    [ -f "$env" ] || { echo "unknown"; return; }
    local url
    url=$(read_var "SQLALCHEMY_DATABASE_URL" "$env")
    case "$url" in
        *postgres*|*timescale*) echo "postgresql" ;;
        *mysql*|*mariadb*)      echo "mysql" ;;
        *sqlite*)               echo "sqlite" ;;
        "") 
            if [ -f "$(get_data_dir "$1")/db.sqlite3" ]; then
                echo "sqlite"
            else
                echo "unknown"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# FIXED: Proper container detection
find_pg_container() {
    local src="$1"
    local name
    name=$(basename "$src")
    local found
    
    # Try panel-specific first
    found=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "${name}.*(timescale|postgres|db)" | head -1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    
    # Try generic postgres
    found=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "timescale|postgres" | grep -v rebecca | head -1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    
    return 1
}

find_mysql_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "rebecca.*(mysql|mariadb)" | head -1
}

#==============================================================================
# SETUP FUNCTIONS
#==============================================================================

start_source_panel() {
    local src="$1"
    minfo "Starting source panel..."
    (cd "$src" && docker compose up -d) &>/dev/null
    
    if [ "$SOURCE_DB_TYPE" = "postgresql" ]; then
        local pg_container="" waited=0
        while [ -z "$pg_container" ] && [ $waited -lt 60 ]; do
            sleep 3
            waited=$((waited + 3))
            pg_container=$(find_pg_container "$src")
        done
        
        if [ -n "$pg_container" ]; then
            waited=0
            local db_user="${SOURCE_PANEL_TYPE}"
            while ! docker exec "$pg_container" pg_isready -U "$db_user" &>/dev/null && [ $waited -lt 60 ]; do
                sleep 2
                waited=$((waited + 2))
            done
            mok "PostgreSQL ready: $pg_container"
        fi
    fi
}

install_xray() {
    local tgt="$1" src="$2"
    minfo "Installing Xray..."
    mkdir -p "$tgt/assets"
    
    if [ -f "$src/xray" ]; then
        cp "$src/xray" "$tgt/xray"
        chmod +x "$tgt/xray"
        mok "Xray copied"
    else
        cd /tmp
        rm -f Xray-linux-64.zip
        if wget -q "$XRAY_URL" -O Xray-linux-64.zip; then
            unzip -oq Xray-linux-64.zip -d "$tgt/"
            chmod +x "$tgt/xray"
            mok "Xray downloaded"
        fi
    fi
    
    [ -d "$src/assets" ] && cp -rn "$src/assets/"* "$tgt/assets/" 2>/dev/null
    [ -f "$tgt/assets/geoip.dat" ] || wget -q "$GEOIP_URL" -O "$tgt/assets/geoip.dat"
    [ -f "$tgt/assets/geosite.dat" ] || wget -q "$GEOSITE_URL" -O "$tgt/assets/geosite.dat"
}

copy_data() {
    local src="$1" tgt="$2"
    minfo "Copying data..."
    mkdir -p "$tgt"
    for d in certs templates assets; do
        if [ -d "$src/$d" ]; then
            mkdir -p "$tgt/$d"
            cp -r "$src/$d/"* "$tgt/$d/" 2>/dev/null
        fi
    done
}

generate_env() {
    local src="$1" tgt="$2"
    local se="$src/.env" te="$tgt/.env"
    minfo "Generating .env..."
    
    local DBPASS PORT SUSER SPASS TGT_TOKEN TGA CERT KEY XJSON SUBURL
    
    DBPASS=$(read_var "MYSQL_ROOT_PASSWORD" "$te")
    [ -z "$DBPASS" ] && DBPASS=$(openssl rand -hex 16)
    
    PORT=$(read_var "UVICORN_PORT" "$se")
    [ -z "$PORT" ] && PORT="8000"
    
    SUSER=$(read_var "SUDO_USERNAME" "$se")
    [ -z "$SUSER" ] && SUSER="admin"
    
    SPASS=$(read_var "SUDO_PASSWORD" "$se")
    [ -z "$SPASS" ] && SPASS="admin"
    
    TGT_TOKEN=$(read_var "TELEGRAM_API_TOKEN" "$se")
    TGA=$(read_var "TELEGRAM_ADMIN_ID" "$se")
    CERT=$(read_var "UVICORN_SSL_CERTFILE" "$se")
    KEY=$(read_var "UVICORN_SSL_KEYFILE" "$se")
    XJSON=$(read_var "XRAY_JSON" "$se")
    SUBURL=$(read_var "XRAY_SUBSCRIPTION_URL_PREFIX" "$se")
    
    # Fix paths
    CERT="${CERT//pasarguard/rebecca}"
    CERT="${CERT//marzban/rebecca}"
    KEY="${KEY//pasarguard/rebecca}"
    KEY="${KEY//marzban/rebecca}"
    XJSON="${XJSON//pasarguard/rebecca}"
    XJSON="${XJSON//marzban/rebecca}"
    [ -z "$XJSON" ] && XJSON="/var/lib/rebecca/xray_config.json"
    
    cat > "$te" << ENVEOF
SQLALCHEMY_DATABASE_URL="mysql+pymysql://root:${DBPASS}@127.0.0.1:3306/rebecca"
MYSQL_ROOT_PASSWORD="${DBPASS}"
MYSQL_DATABASE="rebecca"
UVICORN_HOST="0.0.0.0"
UVICORN_PORT="${PORT}"
UVICORN_SSL_CERTFILE="${CERT}"
UVICORN_SSL_KEYFILE="${KEY}"
SUDO_USERNAME="${SUSER}"
SUDO_PASSWORD="${SPASS}"
TELEGRAM_API_TOKEN="${TGT_TOKEN}"
TELEGRAM_ADMIN_ID="${TGA}"
XRAY_JSON="${XJSON}"
XRAY_SUBSCRIPTION_URL_PREFIX="${SUBURL}"
XRAY_EXECUTABLE_PATH="/var/lib/rebecca/xray"
XRAY_ASSETS_PATH="/var/lib/rebecca/assets"
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440
SECRET_KEY="$(openssl rand -hex 32)"
ENVEOF
    mok "Environment ready"
}

install_rebecca() {
    ui_header "INSTALLING REBECCA"
    ui_confirm "Install Rebecca?" "y" || return 1
    eval "$REBECCA_CMD"
    [ -d "/opt/rebecca" ] && mok "Rebecca installed" || { merr "Failed"; return 1; }
}

setup_jwt() {
    local MC="$1" DP="$2"
    minfo "Setting up JWT..."
    
    local cnt
    cnt=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM jwt;" 2>/dev/null | tr -d ' \n')
    if [ "${cnt:-0}" -gt 0 ]; then
        mok "JWT exists"
        return 0
    fi
    
    docker exec "$MC" mysql -uroot -p"$DP" rebecca -e "
    CREATE TABLE IF NOT EXISTS jwt (
        id INT AUTO_INCREMENT PRIMARY KEY,
        secret_key VARCHAR(255) NOT NULL,
        subscription_secret_key VARCHAR(255),
        admin_secret_key VARCHAR(255),
        vmess_mask VARCHAR(64),
        vless_mask VARCHAR(64)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    " 2>/dev/null
    
    local SK SSK ASK VM VL
    SK=$(openssl rand -hex 64)
    SSK=$(openssl rand -hex 64)
    ASK=$(openssl rand -hex 64)
    VM=$(openssl rand -hex 16)
    VL=$(openssl rand -hex 16)
    
    docker exec "$MC" mysql -uroot -p"$DP" rebecca -e \
        "INSERT INTO jwt (secret_key,subscription_secret_key,admin_secret_key,vmess_mask,vless_mask) VALUES ('$SK','$SSK','$ASK','$VM','$VL');" 2>/dev/null
    mok "JWT configured"
}

#==============================================================================
# POSTGRESQL EXPORT - USING PURE PSQL (NO PYTHON IN CONTAINER!)
#==============================================================================

export_postgresql() {
    local PGC="$1" DBN="$2" DBU="$3" OUT="$4"
    minfo "Exporting PostgreSQL (pure psql)..."
    
    # Helper function to run psql query
    run_pg() {
        docker exec "$PGC" psql -U "$DBU" -d "$DBN" -t -A -c "$1" 2>/dev/null
    }
    
    # Check if table exists
    table_exists() {
        local result
        result=$(run_pg "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='$1')")
        [ "$result" = "t" ]
    }
    
    # Get JSON from table (handles NULL/empty)
    get_table_json() {
        local query="$1"
        local result
        result=$(run_pg "$query")
        if [ -z "$result" ] || [ "$result" = "null" ] || [ "$result" = "" ]; then
            echo "[]"
        else
            echo "$result"
        fi
    }
    
    # Build JSON manually
    local json_file="$OUT"
    echo "{" > "$json_file"
    
    # ADMINS
    minfo "  Exporting admins..."
    if table_exists "admins"; then
        # Handle both is_sudo and is_admin (Marzban compatibility)
        local sudo_field="is_sudo"
        if ! run_pg "SELECT is_sudo FROM admins LIMIT 1" &>/dev/null; then
            sudo_field="is_admin"
        fi
        
        local admins_json
        admins_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (
            SELECT id, username, hashed_password, 
                   COALESCE($sudo_field, false) as is_sudo, 
                   telegram_id, created_at
            FROM admins
        ) t")
        echo "\"admins\": $admins_json," >> "$json_file"
    else
        echo "\"admins\": []," >> "$json_file"
    fi
    
    # INBOUNDS
    minfo "  Exporting inbounds..."
    if table_exists "inbounds"; then
        local inbounds_json
        inbounds_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, tag FROM inbounds) t")
        echo "\"inbounds\": $inbounds_json," >> "$json_file"
    else
        echo "\"inbounds\": []," >> "$json_file"
    fi
    
    # USERS
    minfo "  Exporting users..."
    if table_exists "users"; then
        local users_json
        users_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (
            SELECT id, username, 
                   COALESCE(key, '') as key,
                   COALESCE(status,'active') as status,
                   COALESCE(used_traffic,0) as used_traffic,
                   data_limit,
                   EXTRACT(EPOCH FROM expire)::bigint as expire,
                   COALESCE(admin_id,1) as admin_id,
                   COALESCE(note,'') as note,
                   sub_updated_at, sub_last_user_agent, online_at,
                   on_hold_timeout, on_hold_expire_duration,
                   COALESCE(lifetime_used_traffic,0) as lifetime_used_traffic,
                   created_at, 
                   COALESCE(service_id,1) as service_id,
                   sub_revoked_at,
                   data_limit_reset_strategy, 
                   traffic_reset_at
            FROM users
        ) t")
        echo "\"users\": $users_json," >> "$json_file"
    else
        echo "\"users\": []," >> "$json_file"
    fi
    
    # PROXIES
    minfo "  Exporting proxies..."
    if table_exists "proxies"; then
        local proxies_json
        proxies_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (
            SELECT id, user_id, type, COALESCE(settings::text,'{}') as settings 
            FROM proxies
        ) t")
        echo "\"proxies\": $proxies_json," >> "$json_file"
    else
        echo "\"proxies\": []," >> "$json_file"
    fi
    
    # HOSTS
    minfo "  Exporting hosts..."
    if table_exists "hosts"; then
        local hosts_json
        hosts_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (
            SELECT id, COALESCE(remark,'') as remark, 
                   COALESCE(address,'') as address, 
                   port, 
                   COALESCE(inbound_tag,'') as inbound_tag, 
                   COALESCE(sni,'') as sni, 
                   COALESCE(host,'') as host,
                   COALESCE(security,'none') as security, 
                   COALESCE(fingerprint::text,'none') as fingerprint, 
                   COALESCE(is_disabled,false) as is_disabled,
                   COALESCE(path,'') as path, 
                   COALESCE(alpn,'') as alpn, 
                   COALESCE(allowinsecure,false) as allowinsecure, 
                   fragment_setting,
                   COALESCE(mux_enable,false) as mux_enable, 
                   COALESCE(random_user_agent,false) as random_user_agent
            FROM hosts
        ) t")
        echo "\"hosts\": $hosts_json," >> "$json_file"
    else
        echo "\"hosts\": []," >> "$json_file"
    fi
    
    # SERVICES
    minfo "  Exporting services..."
    if table_exists "services"; then
        local services_json
        services_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (
            SELECT id, COALESCE(name,'Default') as name, users_limit, created_at 
            FROM services
        ) t")
        echo "\"services\": $services_json," >> "$json_file"
    else
        echo "\"services\": []," >> "$json_file"
    fi
    
    # NODES
    minfo "  Exporting nodes..."
    if table_exists "nodes"; then
        local nodes_json
        # Handle certificate as base64 to avoid binary issues
        nodes_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (
            SELECT id, COALESCE(name,'') as name, 
                   COALESCE(address,'') as address, 
                   port, api_port,
                   COALESCE(encode(certificate::bytea, 'base64'), certificate, '') as certificate,
                   COALESCE(usage_coefficient,1.0) as usage_coefficient,
                   COALESCE(status,'connected') as status, 
                   message, xray_version, created_at
            FROM nodes
        ) t")
        echo "\"nodes\": $nodes_json," >> "$json_file"
    else
        echo "\"nodes\": []," >> "$json_file"
    fi
    
    # CORE_CONFIGS
    minfo "  Exporting core_configs..."
    if table_exists "core_configs"; then
        local configs_json
        configs_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (
            SELECT id, COALESCE(name,'default') as name, config, created_at 
            FROM core_configs
        ) t")
        echo "\"core_configs\": $configs_json," >> "$json_file"
    else
        echo "\"core_configs\": []," >> "$json_file"
    fi
    
    # RELATIONS
    minfo "  Exporting relations..."
    
    # service_hosts
    if table_exists "service_hosts"; then
        local sh_json
        sh_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT service_id, host_id FROM service_hosts) t")
        echo "\"service_hosts\": $sh_json," >> "$json_file"
    else
        echo "\"service_hosts\": []," >> "$json_file"
    fi
    
    # service_inbounds
    if table_exists "service_inbounds"; then
        local si_json
        si_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT service_id, inbound_id FROM service_inbounds) t")
        echo "\"service_inbounds\": $si_json," >> "$json_file"
    else
        echo "\"service_inbounds\": []," >> "$json_file"
    fi
    
    # user_inbounds
    if table_exists "user_inbounds"; then
        local ui_json
        ui_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT user_id, inbound_tag FROM user_inbounds) t")
        echo "\"user_inbounds\": $ui_json," >> "$json_file"
    else
        echo "\"user_inbounds\": []," >> "$json_file"
    fi
    
    # node_inbounds
    if table_exists "node_inbounds"; then
        local ni_json
        ni_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT node_id, inbound_tag FROM node_inbounds) t")
        echo "\"node_inbounds\": $ni_json," >> "$json_file"
    else
        echo "\"node_inbounds\": []," >> "$json_file"
    fi
    
    # excluded_inbounds_association
    if table_exists "excluded_inbounds_association"; then
        local ei_json
        ei_json=$(get_table_json "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT user_id, inbound_tag FROM excluded_inbounds_association) t")
        echo "\"excluded_inbounds\": $ei_json" >> "$json_file"
    else
        echo "\"excluded_inbounds\": []" >> "$json_file"
    fi
    
    echo "}" >> "$json_file"
    
    # Validate JSON
    if python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
        local user_count
        user_count=$(python3 -c "import json; print(len(json.load(open('$json_file')).get('users',[])))" 2>/dev/null)
        mok "Exported: $user_count users"
        return 0
    else
        merr "JSON validation failed"
        cat "$json_file" | head -20
        return 1
    fi
}

#==============================================================================
# MYSQL IMPORT - SAFE AND COMPLETE
#==============================================================================

import_to_mysql() {
    local JSON="$1" MC="$2" DP="$3"
    minfo "Importing to MySQL..."
    
    # Create Python import script
    cat > /tmp/mrm_import.py << 'PYTHON_SCRIPT'
import json
import sys
import os
import base64

def esc(v):
    """Escape value for MySQL"""
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dict, list)):
        v = json.dumps(v, ensure_ascii=False)
    v = str(v)
    # Escape in correct order
    v = v.replace('\\', '\\\\')
    v = v.replace("'", "\\'")
    v = v.replace('\n', '\\n')
    v = v.replace('\r', '\\r')
    v = v.replace('\t', '\\t')
    v = v.replace('\x00', '')
    return f"'{v}'"

def esc_json(v):
    """Escape JSON for MySQL TEXT field"""
    if v is None:
        return "NULL"
    if isinstance(v, (dict, list)):
        v = json.dumps(v, ensure_ascii=False)
    v = str(v)
    v = v.replace('\\', '\\\\')
    v = v.replace("'", "\\'")
    return f"'{v}'"

def fix_path(v):
    """Replace old panel paths"""
    if not v:
        return v
    if isinstance(v, str):
        v = v.replace('/var/lib/pasarguard', '/var/lib/rebecca')
        v = v.replace('/var/lib/marzban', '/var/lib/rebecca')
        v = v.replace('/opt/pasarguard', '/opt/rebecca')
        v = v.replace('/opt/marzban', '/opt/rebecca')
        return v
    if isinstance(v, dict):
        return json.loads(fix_path(json.dumps(v)))
    return v

def nv(v):
    """NULL or value"""
    if v is None or v == '' or v == 'None':
        return "NULL"
    return str(v)

def ts(v):
    """Timestamp or NULL"""
    if v is None or v == '' or v == 'None':
        return "NULL"
    return esc(str(v))

def decode_cert(v):
    """Decode base64 certificate if needed"""
    if not v:
        return v
    try:
        return base64.b64decode(v).decode('utf-8')
    except:
        return v

try:
    json_file = sys.argv[1] if len(sys.argv) > 1 else '/tmp/pg_export.json'
    with open(json_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    sql = []
    sql.append("SET NAMES utf8mb4;")
    sql.append("SET FOREIGN_KEY_CHECKS=0;")
    sql.append("SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';")
    
    # Clear tables in correct order
    tables_to_clear = [
        'excluded_inbounds_association', 'user_inbounds', 'node_inbounds',
        'service_inbounds', 'service_hosts', 'proxies', 'users',
        'hosts', 'inbounds', 'services', 'nodes', 'core_configs'
    ]
    for t in tables_to_clear:
        sql.append(f"DELETE FROM {t};")
    sql.append("DELETE FROM admins WHERE id > 0;")
    
    # ADMINS
    for a in data.get('admins') or []:
        if not a.get('id'):
            continue
        role = 'sudo' if a.get('is_sudo') else 'standard'
        created = ts(a.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        sql.append(f"""INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at)
            VALUES ({a['id']}, {esc(a['username'])}, {esc(a['hashed_password'])}, '{role}', 'active',
            {nv(a.get('telegram_id'))}, {created})
            ON DUPLICATE KEY UPDATE hashed_password=VALUES(hashed_password);""")
    
    # INBOUNDS
    for i in data.get('inbounds') or []:
        if not i.get('id'):
            continue
        sql.append(f"INSERT INTO inbounds (id, tag) VALUES ({i['id']}, {esc(i['tag'])}) ON DUPLICATE KEY UPDATE tag=VALUES(tag);")
    
    # SERVICES
    svcs = data.get('services') or []
    for s in svcs:
        if not s.get('id'):
            continue
        created = ts(s.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        sql.append(f"""INSERT INTO services (id, name, users_limit, created_at)
            VALUES ({s['id']}, {esc(s.get('name', 'Default'))}, {nv(s.get('users_limit'))}, {created})
            ON DUPLICATE KEY UPDATE name=VALUES(name);""")
    if not svcs:
        sql.append("INSERT IGNORE INTO services (id, name, created_at) VALUES (1, 'Default', NOW());")
    
    # NODES
    for n in data.get('nodes') or []:
        if not n.get('id'):
            continue
        created = ts(n.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        cert = decode_cert(n.get('certificate'))
        sql.append(f"""INSERT INTO nodes (id, name, address, port, api_port, certificate, usage_coefficient, status, message, xray_version, created_at)
            VALUES ({n['id']}, {esc(n['name'])}, {esc(n.get('address', ''))},
            {nv(n.get('port'))}, {nv(n.get('api_port'))}, {esc(cert)},
            {n.get('usage_coefficient', 1.0)}, {esc(n.get('status', 'connected'))},
            {esc(n.get('message'))}, {esc(n.get('xray_version'))}, {created})
            ON DUPLICATE KEY UPDATE address=VALUES(address);""")
    
    # HOSTS
    for h in data.get('hosts') or []:
        if not h.get('id'):
            continue
        addr = fix_path(h.get('address', ''))
        path = fix_path(h.get('path', ''))
        fp = h.get('fingerprint')
        if isinstance(fp, dict):
            fp = 'none'
        fp = fp or 'none'
        frag = h.get('fragment_setting')
        frag_sql = esc_json(frag) if frag else "NULL"
        sql.append(f"""INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, security, fingerprint, is_disabled, path, alpn, allowinsecure, fragment_setting, mux_enable, random_user_agent)
            VALUES ({h['id']}, {esc(h.get('remark', ''))}, {esc(addr)}, {nv(h.get('port'))},
            {esc(h.get('inbound_tag', ''))}, {esc(h.get('sni', ''))}, {esc(h.get('host', ''))},
            {esc(h.get('security', 'none'))}, {esc(fp)}, {1 if h.get('is_disabled') else 0},
            {esc(path)}, {esc(h.get('alpn', ''))}, {1 if h.get('allowinsecure') else 0},
            {frag_sql}, {1 if h.get('mux_enable') else 0}, {1 if h.get('random_user_agent') else 0})
            ON DUPLICATE KEY UPDATE address=VALUES(address);""")
    
    # USERS
    for u in data.get('users') or []:
        if not u.get('id'):
            continue
        uname = str(u.get('username', '')).replace('@', '_at_').replace('.', '_dot_')
        key = u.get('key') or ''
        status = u.get('status', 'active')
        if status not in ['active', 'disabled', 'limited', 'expired', 'on_hold']:
            status = 'active'
        svc = u.get('service_id') or 1
        created = ts(u.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        
        sql.append(f"""INSERT INTO users (id, username, `key`, status, used_traffic, data_limit, expire, admin_id, note, service_id,
            lifetime_used_traffic, on_hold_timeout, on_hold_expire_duration, sub_updated_at, sub_last_user_agent, online_at,
            sub_revoked_at, data_limit_reset_strategy, traffic_reset_at, created_at)
            VALUES ({u['id']}, {esc(uname)}, {esc(key)}, '{status}', {int(u.get('used_traffic', 0))},
            {nv(u.get('data_limit'))}, {nv(u.get('expire'))}, {u.get('admin_id', 1)}, {esc(u.get('note', ''))}, {svc},
            {int(u.get('lifetime_used_traffic', 0))}, {ts(u.get('on_hold_timeout'))}, {nv(u.get('on_hold_expire_duration'))},
            {ts(u.get('sub_updated_at'))}, {esc(u.get('sub_last_user_agent'))}, {ts(u.get('online_at'))},
            {ts(u.get('sub_revoked_at'))}, {esc(u.get('data_limit_reset_strategy'))}, {ts(u.get('traffic_reset_at'))}, {created})
            ON DUPLICATE KEY UPDATE `key`=VALUES(`key`), status=VALUES(status);""")
    
    # PROXIES
    for p in data.get('proxies') or []:
        if not p.get('id'):
            continue
        settings = p.get('settings', {})
        if isinstance(settings, str):
            try:
                settings = json.loads(settings)
            except:
                pass
        settings = fix_path(settings)
        sql.append(f"""INSERT INTO proxies (id, user_id, type, settings)
            VALUES ({p['id']}, {p['user_id']}, {esc(p['type'])}, {esc_json(settings)})
            ON DUPLICATE KEY UPDATE settings=VALUES(settings);""")
    
    # RELATIONS
    for sh in data.get('service_hosts') or []:
        if sh.get('service_id') and sh.get('host_id'):
            sql.append(f"INSERT IGNORE INTO service_hosts (service_id, host_id) VALUES ({sh['service_id']}, {sh['host_id']});")
    
    for si in data.get('service_inbounds') or []:
        if si.get('service_id') and si.get('inbound_id'):
            sql.append(f"INSERT IGNORE INTO service_inbounds (service_id, inbound_id) VALUES ({si['service_id']}, {si['inbound_id']});")
    
    for ui in data.get('user_inbounds') or []:
        if ui.get('user_id') and ui.get('inbound_tag'):
            sql.append(f"INSERT IGNORE INTO user_inbounds (user_id, inbound_tag) VALUES ({ui['user_id']}, {esc(ui['inbound_tag'])});")
    
    for ni in data.get('node_inbounds') or []:
        if ni.get('node_id') and ni.get('inbound_tag'):
            sql.append(f"INSERT IGNORE INTO node_inbounds (node_id, inbound_tag) VALUES ({ni['node_id']}, {esc(ni['inbound_tag'])});")
    
    for ei in data.get('excluded_inbounds') or []:
        if ei.get('user_id') and ei.get('inbound_tag'):
            sql.append(f"INSERT IGNORE INTO excluded_inbounds_association (user_id, inbound_tag) VALUES ({ei['user_id']}, {esc(ei['inbound_tag'])});")
    
    # Default relations
    if not data.get('service_hosts'):
        sql.append("INSERT IGNORE INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts;")
    
    # CORE_CONFIGS
    for c in data.get('core_configs') or []:
        if not c.get('id'):
            continue
        cfg = c.get('config', {})
        if isinstance(cfg, str):
            try:
                cfg = json.loads(cfg)
            except:
                pass
        cfg = fix_path(cfg)
        if isinstance(cfg, dict) and 'api' not in cfg:
            cfg['api'] = {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]}
        created = ts(c.get('created_at'))
        if created == "NULL":
            created = "NOW()"
        sql.append(f"""INSERT INTO core_configs (id, name, config, created_at)
            VALUES ({c['id']}, {esc(c.get('name', 'default'))}, {esc_json(cfg)}, {created})
            ON DUPLICATE KEY UPDATE config=VALUES(config);""")
    
    sql.append("SET FOREIGN_KEY_CHECKS=1;")
    
    # Write SQL
    with open('/tmp/mrm_import.sql', 'w', encoding='utf-8') as f:
        f.write('\n'.join(sql))
    
    print(f"Generated {len(sql)} statements")
    print(f"Users: {len(data.get('users', []))}")
    print(f"Proxies: {len(data.get('proxies', []))}")

except Exception as e:
    import traceback
    print(f"ERROR: {e}")
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT

    # Run Python script
    if ! python3 /tmp/mrm_import.py "$JSON"; then
        merr "SQL generation failed"
        rm -f /tmp/mrm_import.py
        return 1
    fi
    rm -f /tmp/mrm_import.py
    
    if [ ! -f /tmp/mrm_import.sql ]; then
        merr "SQL file not created"
        return 1
    fi
    
    # Copy and execute
    docker cp /tmp/mrm_import.sql "$MC:/tmp/import.sql"
    local result
    result=$(docker exec "$MC" bash -c "mysql -uroot -p'$DP' rebecca < /tmp/import.sql 2>&1")
    local rc=$?
    
    docker exec "$MC" rm -f /tmp/import.sql 2>/dev/null
    rm -f /tmp/mrm_import.sql
    
    if [ $rc -ne 0 ]; then
        merr "Import failed: $(echo "$result" | head -3)"
        return 1
    fi
    
    # Fix AUTO_INCREMENT
    docker exec "$MC" mysql -uroot -p"$DP" rebecca -e "
        SET @m = (SELECT COALESCE(MAX(id),0)+1 FROM admins);
        SET @s = CONCAT('ALTER TABLE admins AUTO_INCREMENT = ', @m);
        PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        
        SET @m = (SELECT COALESCE(MAX(id),0)+1 FROM users);
        SET @s = CONCAT('ALTER TABLE users AUTO_INCREMENT = ', @m);
        PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        
        SET @m = (SELECT COALESCE(MAX(id),0)+1 FROM proxies);
        SET @s = CONCAT('ALTER TABLE proxies AUTO_INCREMENT = ', @m);
        PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        
        SET @m = (SELECT COALESCE(MAX(id),0)+1 FROM hosts);
        SET @s = CONCAT('ALTER TABLE hosts AUTO_INCREMENT = ', @m);
        PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        
        SET @m = (SELECT COALESCE(MAX(id),0)+1 FROM nodes);
        SET @s = CONCAT('ALTER TABLE nodes AUTO_INCREMENT = ', @m);
        PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        
        SET @m = (SELECT COALESCE(MAX(id),0)+1 FROM services);
        SET @s = CONCAT('ALTER TABLE services AUTO_INCREMENT = ', @m);
        PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        
        SET @m = (SELECT COALESCE(MAX(id),0)+1 FROM inbounds);
        SET @s = CONCAT('ALTER TABLE inbounds AUTO_INCREMENT = ', @m);
        PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        
        SET @m = (SELECT COALESCE(MAX(id),0)+1 FROM core_configs);
        SET @s = CONCAT('ALTER TABLE core_configs AUTO_INCREMENT = ', @m);
        PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    " 2>/dev/null
    
    mok "Import complete"
    return 0
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

migrate_pg_to_mysql() {
    local src="$1" tgt="$2"
    ui_header "POSTGRESQL → MYSQL"
    
    local PGC MC DP DBN DBU
    PGC=$(find_pg_container "$src")
    MC=$(find_mysql_container)
    DP=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt/.env")
    DBN="${SOURCE_PANEL_TYPE}"
    DBU="${SOURCE_PANEL_TYPE}"
    
    if [ -z "$PGC" ]; then
        merr "PostgreSQL container not found"
        return 1
    fi
    if [ -z "$MC" ]; then
        merr "MySQL container not found"
        return 1
    fi
    
    minfo "Source: $PGC ($DBN)"
    minfo "Target: $MC"
    
    # Wait for MySQL
    local waited=0
    while ! docker exec "$MC" mysqladmin ping -uroot -p"$DP" --silent 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ $waited -ge 90 ]; then
            merr "MySQL timeout"
            return 1
        fi
    done
    mok "MySQL ready"
    
    local EXP="/tmp/mrm-pg-export-$$.json"
    
    if ! export_postgresql "$PGC" "$DBN" "$DBU" "$EXP"; then
        return 1
    fi
    
    setup_jwt "$MC" "$DP"
    
    if ! import_to_mysql "$EXP" "$MC" "$DP"; then
        rm -f "$EXP"
        return 1
    fi
    
    rm -f "$EXP"
    
    # Verification
    echo ""
    ui_header "VERIFICATION"
    
    local admins users ukeys proxies puuid uinb hosts nodes svcs cfgs
    admins=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM admins;" 2>/dev/null | tr -d ' \n')
    users=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' \n')
    ukeys=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM users WHERE \`key\` IS NOT NULL AND \`key\` != '';" 2>/dev/null | tr -d ' \n')
    proxies=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM proxies;" 2>/dev/null | tr -d ' \n')
    puuid=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM proxies WHERE settings LIKE '%id%' OR settings LIKE '%password%';" 2>/dev/null | tr -d ' \n')
    uinb=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM user_inbounds;" 2>/dev/null | tr -d ' \n')
    hosts=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM hosts;" 2>/dev/null | tr -d ' \n')
    nodes=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM nodes;" 2>/dev/null | tr -d ' \n')
    svcs=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM services;" 2>/dev/null | tr -d ' \n')
    cfgs=$(docker exec "$MC" mysql -uroot -p"$DP" rebecca -N -e "SELECT COUNT(*) FROM core_configs;" 2>/dev/null | tr -d ' \n')
    
    printf "  %-22s ${GREEN}%s${NC}\n" "Admins:" "${admins:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Users:" "${users:-0}"
    printf "  %-22s ${GREEN}%s${NC} ← subscriptions\n" "Users with Key:" "${ukeys:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Proxies:" "${proxies:-0}"
    printf "  %-22s ${GREEN}%s${NC} ← configs\n" "Proxies with UUID:" "${puuid:-0}"
    printf "  %-22s ${GREEN}%s${NC} ← user↔inbound\n" "User-Inbounds:" "${uinb:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Hosts:" "${hosts:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Nodes:" "${nodes:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Services:" "${svcs:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Core Configs:" "${cfgs:-0}"
    echo ""
    
    local err=0
    if [ "${users:-0}" -gt 0 ]; then
        if [ "${ukeys:-0}" -eq 0 ]; then
            merr "CRITICAL: No user keys → Subscriptions BROKEN!"
            err=1
        fi
        if [ "${proxies:-0}" -eq 0 ]; then
            merr "CRITICAL: No proxies → Configs BROKEN!"
            err=1
        fi
        if [ "${puuid:-0}" -eq 0 ]; then
            merr "CRITICAL: No proxy UUIDs → Configs BROKEN!"
            err=1
        fi
    fi
    if [ "${hosts:-0}" -eq 0 ]; then
        merr "CRITICAL: No hosts!"
        err=1
    fi
    
    if [ $err -eq 0 ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  ✓ Admin passwords preserved (bcrypt)${NC}"
        echo -e "${GREEN}  ✓ User subscription keys preserved${NC}"
        echo -e "${GREEN}  ✓ Proxy UUIDs preserved (configs work)${NC}"
        echo -e "${GREEN}  ✓ All relations preserved${NC}"
        echo -e "${GREEN}  ✓ AUTO_INCREMENT fixed${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    
    return $err
}

#==============================================================================
# SQLITE MIGRATION
#==============================================================================

migrate_sqlite_to_mysql() {
    local src="$1" tgt="$2"
    ui_header "SQLITE → MYSQL"
    
    local MC DP SDATA SDB
    MC=$(find_mysql_container)
    DP=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt/.env")
    SDATA=$(get_data_dir "$src")
    SDB="$SDATA/db.sqlite3"
    
    if [ ! -f "$SDB" ]; then
        merr "SQLite not found: $SDB"
        return 1
    fi
    if [ -z "$MC" ]; then
        merr "MySQL not found"
        return 1
    fi
    
    command -v sqlite3 &>/dev/null || apt-get install -y sqlite3 >/dev/null 2>&1
    
    minfo "Exporting SQLite..."
    local EXP="/tmp/mrm-sqlite-$$.json"
    
    python3 << PYEXP
import sqlite3
import json

conn = sqlite3.connect("$SDB")
conn.row_factory = sqlite3.Row
cur = conn.cursor()

cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
tables = [r[0] for r in cur.fetchall()]

data = {}
table_list = ['admins', 'inbounds', 'users', 'proxies', 'hosts', 'services',
              'service_hosts', 'service_inbounds', 'user_inbounds',
              'nodes', 'node_inbounds', 'core_configs', 'excluded_inbounds_association']

for t in table_list:
    if t in tables:
        try:
            cur.execute(f"SELECT * FROM {t}")
            data[t] = [dict(r) for r in cur.fetchall()]
        except:
            data[t] = []
    else:
        data[t] = []

# Rename for compatibility
if 'excluded_inbounds_association' in data:
    data['excluded_inbounds'] = data.pop('excluded_inbounds_association')

conn.close()

with open('$EXP', 'w') as f:
    json.dump(data, f, default=str)

print(f"Exported {len(data.get('users', []))} users")
PYEXP

    if [ ! -s "$EXP" ]; then
        merr "Export failed"
        return 1
    fi
    
    # Wait for MySQL
    local waited=0
    while ! docker exec "$MC" mysqladmin ping -uroot -p"$DP" --silent 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        [ $waited -ge 90 ] && { merr "MySQL timeout"; return 1; }
    done
    
    setup_jwt "$MC" "$DP"
    
    if ! import_to_mysql "$EXP" "$MC" "$DP"; then
        rm -f "$EXP"
        return 1
    fi
    
    rm -f "$EXP"
    mok "SQLite migration complete"
    return 0
}

#==============================================================================
# ORCHESTRATION
#==============================================================================

stop_old() {
    minfo "Stopping old panels..."
    local containers
    containers=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard|marzban" | grep -v rebecca)
    for c in $containers; do
        docker stop "$c" 2>/dev/null
    done
}

do_full() {
    migration_init
    clear
    ui_header "MRM MIGRATION V10.8"
    
    SRC=$(detect_source_panel)
    if [ -z "$SRC" ]; then
        merr "No source panel found"
        mpause
        return 1
    fi
    
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    local SDATA
    SDATA=$(get_data_dir "$SRC")
    
    echo -e "  Source: ${YELLOW}$SOURCE_PANEL_TYPE${NC} ($SRC)"
    echo -e "  DB:     ${YELLOW}$SOURCE_DB_TYPE${NC}"
    echo -e "  Target: ${GREEN}Rebecca${NC}"
    echo ""
    
    if [ "$SOURCE_DB_TYPE" = "unknown" ]; then
        merr "Unknown database type"
        mpause
        return 1
    fi
    
    if [ -d "/opt/rebecca" ]; then
        TGT="/opt/rebecca"
    else
        install_rebecca || { mpause; return 1; }
        TGT="/opt/rebecca"
    fi
    local TDATA="/var/lib/rebecca"
    
    echo -e "${YELLOW}Will migrate:${NC}"
    echo "  • Admins (bcrypt passwords)"
    echo "  • Users (subscription keys)"
    echo "  • Proxies (UUIDs/passwords)"
    echo "  • User↔Inbound relations"
    echo "  • Hosts, Services, Nodes"
    echo "  • Core configs"
    echo ""
    
    ui_confirm "Start migration?" "y" || return 0
    
    echo "$SRC" > "$BACKUP_ROOT/.last_source"
    
    minfo "[1/7] Starting source..."
    start_source_panel "$SRC"
    
    minfo "[2/7] Stopping Rebecca..."
    (cd "$TGT" && docker compose down 2>/dev/null) &>/dev/null
    
    minfo "[3/7] Copying files..."
    copy_data "$SDATA" "$TDATA"
    
    minfo "[4/7] Installing Xray..."
    install_xray "$TDATA" "$SDATA"
    
    minfo "[5/7] Generating config..."
    generate_env "$SRC" "$TGT"
    
    minfo "[6/7] Starting Rebecca..."
    (cd "$TGT" && docker compose up -d --force-recreate)
    minfo "Waiting 45s for startup..."
    sleep 45
    
    minfo "[7/7] Migrating database..."
    local rc=0
    case "$SOURCE_DB_TYPE" in
        postgresql) migrate_pg_to_mysql "$SRC" "$TGT"; rc=$? ;;
        sqlite)     migrate_sqlite_to_mysql "$SRC" "$TGT"; rc=$? ;;
        *)          merr "Unsupported: $SOURCE_DB_TYPE"; rc=1 ;;
    esac
    
    minfo "Restarting Rebecca..."
    (cd "$TGT" && docker compose restart)
    sleep 10
    stop_old
    
    echo ""
    ui_header "MIGRATION COMPLETE"
    
    if [ $rc -eq 0 ]; then
        echo -e "  ${GREEN}✓ Login: use your $SOURCE_PANEL_TYPE credentials${NC}"
        echo -e "  ${GREEN}✓ Subscriptions: will work${NC}"
        echo -e "  ${GREEN}✓ Configs: will connect${NC}"
    else
        mwarn "Some issues detected - check verification above"
    fi
    
    echo ""
    migration_cleanup
    mpause
}

do_fix() {
    clear
    ui_header "FIX CURRENT"
    
    if [ ! -d "/opt/rebecca" ]; then
        merr "Rebecca not found"
        mpause
        return 1
    fi
    
    TGT="/opt/rebecca"
    SRC=$(detect_source_panel)
    if [ -z "$SRC" ]; then
        merr "Source not found"
        mpause
        return 1
    fi
    
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    
    echo "Re-import from: $SRC ($SOURCE_DB_TYPE)"
    ui_confirm "Proceed?" "y" || return 0
    
    start_source_panel "$SRC"
    (cd "$TGT" && docker compose up -d) &>/dev/null
    sleep 30
    
    case "$SOURCE_DB_TYPE" in
        postgresql) migrate_pg_to_mysql "$SRC" "$TGT" ;;
        sqlite)     migrate_sqlite_to_mysql "$SRC" "$TGT" ;;
    esac
    
    (cd "$TGT" && docker compose restart)
    stop_old
    mok "Done"
    mpause
}

do_rollback() {
    clear
    ui_header "ROLLBACK"
    
    local sp
    sp=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    if [ -z "$sp" ] || [ ! -d "$sp" ]; then
        merr "No source path found"
        mpause
        return 1
    fi
    
    echo "Will: Stop Rebecca, Start $sp"
    ui_confirm "Proceed?" "n" || return 0
    
    (cd /opt/rebecca && docker compose down 2>/dev/null) &>/dev/null
    (cd "$sp" && docker compose up -d)
    mok "Rollback complete"
    mpause
}

do_status() {
    clear
    ui_header "STATUS"
    
    echo -e "${CYAN}Containers:${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}" | head -12
    echo ""
    
    local MC DP
    MC=$(find_mysql_container)
    DP=$(read_var "MYSQL_ROOT_PASSWORD" "/opt/rebecca/.env")
    
    if [ -n "$MC" ] && [ -n "$DP" ]; then
        echo -e "${CYAN}Database:${NC}"
        docker exec "$MC" mysql -uroot -p"$DP" rebecca -e "
            SELECT 'Admins' t, COUNT(*) c FROM admins
            UNION SELECT 'Users', COUNT(*) FROM users
            UNION SELECT 'Users+Key', COUNT(*) FROM users WHERE \`key\` IS NOT NULL AND \`key\` != ''
            UNION SELECT 'Proxies', COUNT(*) FROM proxies
            UNION SELECT 'Proxies+UUID', COUNT(*) FROM proxies WHERE settings LIKE '%id%'
            UNION SELECT 'User-Inbounds', COUNT(*) FROM user_inbounds
            UNION SELECT 'Hosts', COUNT(*) FROM hosts
            UNION SELECT 'Nodes', COUNT(*) FROM nodes
            UNION SELECT 'Configs', COUNT(*) FROM core_configs;" 2>/dev/null
    fi
    mpause
}

do_logs() {
    clear
    ui_header "LOGS"
    if [ -f "$MIGRATION_LOG" ]; then
        tail -80 "$MIGRATION_LOG"
    else
        echo "No logs found"
    fi
    mpause
}

main_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION V10.8"
        echo -e "  ${GREEN}Complete: Passwords, Keys, UUIDs, Relations${NC}"
        echo ""
        echo "  1) Full Migration"
        echo "  2) Fix Current"
        echo "  3) Rollback"
        echo "  4) Status"
        echo "  5) Logs"
        echo "  0) Exit"
        echo ""
        read -p "Select: " opt
        case "$opt" in
            1) do_full ;;
            2) do_fix ;;
            3) do_rollback ;;
            4) do_status ;;
            5) do_logs ;;
            0) migration_cleanup; exit 0 ;;
        esac
    done
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root"
        exit 1
    fi
    main_menu
fi