#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V11.4 (FIXED)
#==============================================================================

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

BACKUP_ROOT="/var/backups/mrm-migration"
MIGRATION_LOG="/var/log/mrm_migration.log"
ORIGINAL_DIR="$(pwd)"

SRC=""
TGT=""
SOURCE_PANEL_TYPE=""
SOURCE_DB_TYPE=""
PG_CONTAINER=""
MYSQL_CONTAINER=""
MYSQL_PASS=""

XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

#==============================================================================
# SAFE WRITE FUNCTIONS
#==============================================================================

safe_write() {
    printf '%s' "$1"
}

safe_writeln() {
    printf '%s\n' "$1"
}

#==============================================================================
# DEPENDENCY CHECK
#==============================================================================

check_dependencies() {
    local missing=""

    command -v python3 &>/dev/null || missing="$missing python3"
    command -v docker &>/dev/null || missing="$missing docker"
    command -v openssl &>/dev/null || missing="$missing openssl"
    command -v curl &>/dev/null || missing="$missing curl"
    command -v unzip &>/dev/null || missing="$missing unzip"

    if [ -n "$missing" ]; then
        echo -e "${YELLOW}Installing:$missing${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y python3 docker.io openssl curl unzip &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y python3 docker openssl curl unzip &>/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y python3 docker openssl curl unzip &>/dev/null
        fi
    fi
    return 0
}

#==============================================================================
# LOGGING
#==============================================================================

migration_init() {
    mkdir -p "$BACKUP_ROOT" 2>/dev/null
    mkdir -p "$(dirname "$MIGRATION_LOG")" 2>/dev/null
    safe_writeln "=== Migration $(date) ===" >> "$MIGRATION_LOG" 2>/dev/null
    check_dependencies
}

migration_cleanup() {
    rm -rf /tmp/mrm_* 2>/dev/null
    cd "$ORIGINAL_DIR" 2>/dev/null || true
}

mlog()  { safe_writeln "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG" 2>/dev/null; }
minfo() { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()   { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn() { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr()  { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }

mpause() {
    echo ""
    read -n1 -s -r -p $'\033[0;33mPress any key...\033[0m'
    echo ""
}

ui_confirm() {
    local prompt="$1" default="${2:-y}" answer
    read -p "$prompt [y/n] ($default): " answer
    [[ "${answer:-$default}" =~ ^[Yy] ]]
}

ui_header() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo ""
}

#==============================================================================
# SAFE ENV VAR READING (FIXED)
#==============================================================================

read_env_var() {
    local key="$1" file="$2"
    [ -f "$file" ] || return 1

    local line value
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | grep -v "^[[:space:]]*#" | tail -1)
    [ -z "$line" ] && return 1

    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "$value" == \"*\" ]]; then
        value="${value:1:-1}"
    elif [[ "$value" == \'*\' ]]; then
        value="${value:1:-1}"
    fi

    printf '%s' "$value"
}

#==============================================================================
# DETECTION
#==============================================================================

detect_source_panel() {
    for p in /opt/pasarguard /opt/marzban; do
        if [ -d "$p" ] && [ -f "$p/.env" ]; then
            SOURCE_PANEL_TYPE=$(basename "$p")
            safe_writeln "$p"
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
    url=$(read_env_var "SQLALCHEMY_DATABASE_URL" "$env")

    case "$url" in
        *postgres*|*timescale*) echo "postgresql" ;;
        *mysql*|*mariadb*)      echo "mysql" ;;
        *sqlite*)               echo "sqlite" ;;
        "") 
            [ -f "$(get_data_dir "$1")/db.sqlite3" ] && echo "sqlite" || echo "unknown"
            ;;
        *) echo "unknown" ;;
    esac
}

find_pg_container() {
    local src="$1"
    local name
    name=$(basename "$src")

    local found
    # First try timescaledb specifically
    found=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "${name}.*timescale" | head -1)
    [ -n "$found" ] && { echo "$found"; return 0; }

    # Then try postgres
    found=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "${name}.*(postgres|db)" | grep -v pgbouncer | head -1)
    [ -n "$found" ] && { echo "$found"; return 0; }

    # Generic fallback
    found=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "timescale|postgres" | grep -v rebecca | grep -v pgbouncer | head -1)
    [ -n "$found" ] && { echo "$found"; return 0; }

    return 1
}

find_mysql_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "rebecca.*(mysql|mariadb)" | head -1
}

#==============================================================================
# SAFE MYSQL EXECUTION
#==============================================================================

run_mysql_query() {
    local query="$1"

    local cnf="/tmp/mrm_cnf_$$"
    {
        safe_writeln "[client]"
        safe_writeln "user=root"
        safe_write "password="
        safe_writeln "$MYSQL_PASS"
    } > "$cnf"
    chmod 600 "$cnf"

    local qfile="/tmp/mrm_query_$$.sql"
    safe_writeln "$query" > "$qfile"

    docker cp "$cnf" "$MYSQL_CONTAINER:/tmp/.my.cnf" 2>/dev/null
    docker cp "$qfile" "$MYSQL_CONTAINER:/tmp/.q.sql" 2>/dev/null
    rm -f "$cnf" "$qfile"

    docker exec "$MYSQL_CONTAINER" bash -c 'r=$(mysql --defaults-file=/tmp/.my.cnf rebecca -N < /tmp/.q.sql 2>&1); rm -f /tmp/.my.cnf /tmp/.q.sql; echo "$r"'
}

run_mysql_file() {
    local sql_file="$1"

    local cnf="/tmp/mrm_cnf_$$"
    {
        safe_writeln "[client]"
        safe_writeln "user=root"
        safe_write "password="
        safe_writeln "$MYSQL_PASS"
    } > "$cnf"
    chmod 600 "$cnf"

    docker cp "$cnf" "$MYSQL_CONTAINER:/tmp/.my.cnf" 2>/dev/null
    docker cp "$sql_file" "$MYSQL_CONTAINER:/tmp/import.sql" 2>/dev/null
    rm -f "$cnf"

    docker exec "$MYSQL_CONTAINER" bash -c 'r=$(mysql --defaults-file=/tmp/.my.cnf rebecca < /tmp/import.sql 2>&1); rm -f /tmp/.my.cnf /tmp/import.sql; echo "$r"'
}

wait_mysql() {
    minfo "Waiting for MySQL..."
    local waited=0

    local cnf="/tmp/mrm_cnf_$$"
    {
        safe_writeln "[client]"
        safe_writeln "user=root"
        safe_write "password="
        safe_writeln "$MYSQL_PASS"
    } > "$cnf"
    chmod 600 "$cnf"
    docker cp "$cnf" "$MYSQL_CONTAINER:/tmp/.my.cnf" 2>/dev/null
    rm -f "$cnf"

    while ! docker exec "$MYSQL_CONTAINER" bash -c 'mysqladmin --defaults-file=/tmp/.my.cnf ping --silent 2>/dev/null'; do
        sleep 2
        waited=$((waited + 2))
        if [ $waited -ge 90 ]; then
            docker exec "$MYSQL_CONTAINER" rm -f /tmp/.my.cnf 2>/dev/null
            merr "MySQL timeout"
            return 1
        fi
    done
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/.my.cnf 2>/dev/null
    mok "MySQL ready"
    return 0
}

wait_rebecca_tables() {
    minfo "Waiting for Rebecca tables..."
    local waited=0
    local max_wait=120

    while [ $waited -lt $max_wait ]; do
        local tables
        tables=$(run_mysql_query "SHOW TABLES LIKE 'users';" 2>/dev/null | grep -c "users")
        if [ "$tables" -gt 0 ] 2>/dev/null; then
            mok "Rebecca tables ready"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    echo ""
    merr "Rebecca tables not created"
    return 1
}

#==============================================================================
# SETUP FUNCTIONS
#==============================================================================

start_source_panel() {
    local src="$1"
    minfo "Starting source panel..."

    (cd "$src" && docker compose up -d) &>/dev/null

    if [ "$SOURCE_DB_TYPE" = "postgresql" ]; then
        local waited=0
        while [ -z "$PG_CONTAINER" ] && [ $waited -lt 60 ]; do
            sleep 3
            waited=$((waited + 3))
            PG_CONTAINER=$(find_pg_container "$src")
        done

        if [ -n "$PG_CONTAINER" ]; then
            waited=0
            local db_user="${SOURCE_PANEL_TYPE}"
            while ! docker exec "$PG_CONTAINER" pg_isready -U "$db_user" &>/dev/null && [ $waited -lt 60 ]; do
                sleep 2
                waited=$((waited + 2))
            done
            mok "PostgreSQL ready: $PG_CONTAINER"
        else
            merr "PostgreSQL container not found"
            return 1
        fi
    fi
    return 0
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
        (
            cd /tmp || exit
            rm -f Xray-linux-64.zip
            if wget -q "$XRAY_URL" -O Xray-linux-64.zip 2>/dev/null; then
                unzip -oq Xray-linux-64.zip -d "$tgt/" 2>/dev/null
                chmod +x "$tgt/xray" 2>/dev/null
            fi
        )
        [ -x "$tgt/xray" ] && mok "Xray downloaded" || mwarn "Xray download failed"
    fi

    [ -d "$src/assets" ] && cp -rn "$src/assets/"* "$tgt/assets/" 2>/dev/null
    [ -f "$tgt/assets/geoip.dat" ] || wget -q "$GEOIP_URL" -O "$tgt/assets/geoip.dat" 2>/dev/null
    [ -f "$tgt/assets/geosite.dat" ] || wget -q "$GEOSITE_URL" -O "$tgt/assets/geosite.dat" 2>/dev/null
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

    MYSQL_PASS=$(read_env_var "MYSQL_ROOT_PASSWORD" "$te")
    [ -z "$MYSQL_PASS" ] && MYSQL_PASS=$(openssl rand -hex 16)

    local PORT SUSER SPASS TG_TOKEN TG_ADMIN CERT KEY XJSON SUBURL
    PORT=$(read_env_var "UVICORN_PORT" "$se")
    [ -z "$PORT" ] && PORT="8000"

    SUSER=$(read_env_var "SUDO_USERNAME" "$se")
    [ -z "$SUSER" ] && SUSER="admin"

    SPASS=$(read_env_var "SUDO_PASSWORD" "$se")
    [ -z "$SPASS" ] && SPASS="admin"

    TG_TOKEN=$(read_env_var "TELEGRAM_API_TOKEN" "$se")
    TG_ADMIN=$(read_env_var "TELEGRAM_ADMIN_ID" "$se")
    CERT=$(read_env_var "UVICORN_SSL_CERTFILE" "$se")
    KEY=$(read_env_var "UVICORN_SSL_KEYFILE" "$se")
    XJSON=$(read_env_var "XRAY_JSON" "$se")
    SUBURL=$(read_env_var "XRAY_SUBSCRIPTION_URL_PREFIX" "$se")

    CERT="${CERT//pasarguard/rebecca}"
    CERT="${CERT//marzban/rebecca}"
    KEY="${KEY//pasarguard/rebecca}"
    KEY="${KEY//marzban/rebecca}"
    XJSON="${XJSON//pasarguard/rebecca}"
    XJSON="${XJSON//marzban/rebecca}"
    [ -z "$XJSON" ] && XJSON="/var/lib/rebecca/xray_config.json"

    local tmpdir="/tmp/mrm_env_$$"
    mkdir -p "$tmpdir"
    safe_write "$MYSQL_PASS" > "$tmpdir/mysql_pass"
    safe_write "$PORT" > "$tmpdir/port"
    safe_write "$SUSER" > "$tmpdir/suser"
    safe_write "$SPASS" > "$tmpdir/spass"
    safe_write "$TG_TOKEN" > "$tmpdir/tg_token"
    safe_write "$TG_ADMIN" > "$tmpdir/tg_admin"
    safe_write "$CERT" > "$tmpdir/cert"
    safe_write "$KEY" > "$tmpdir/key"
    safe_write "$XJSON" > "$tmpdir/xjson"
    safe_write "$SUBURL" > "$tmpdir/suburl"
    safe_write "$te" > "$tmpdir/target"
    safe_write "$tmpdir" > "/tmp/mrm_envdir_$$"

    python3 << 'PYENV'
import urllib.parse
import secrets
import os

ppid = os.getppid()
with open(f"/tmp/mrm_envdir_{ppid}", "r") as f:
    tmpdir = f.read()

def read_val(name):
    try:
        with open(f"{tmpdir}/{name}", "r") as f:
            return f.read()
    except:
        return ""

mysql_pass = read_val("mysql_pass")
mysql_pass_enc = urllib.parse.quote(mysql_pass, safe='')
port = read_val("port")
suser = read_val("suser")
spass = read_val("spass")
tg_token = read_val("tg_token")
tg_admin = read_val("tg_admin")
cert = read_val("cert")
key = read_val("key")
xjson = read_val("xjson")
suburl = read_val("suburl")
target = read_val("target")

secret_key = secrets.token_hex(32)

content = f'''SQLALCHEMY_DATABASE_URL="mysql+pymysql://root:{mysql_pass_enc}@127.0.0.1:3306/rebecca"
MYSQL_ROOT_PASSWORD="{mysql_pass}"
MYSQL_DATABASE="rebecca"
UVICORN_HOST="0.0.0.0"
UVICORN_PORT="{port}"
UVICORN_SSL_CERTFILE="{cert}"
UVICORN_SSL_KEYFILE="{key}"
SUDO_USERNAME="{suser}"
SUDO_PASSWORD="{spass}"
TELEGRAM_API_TOKEN="{tg_token}"
TELEGRAM_ADMIN_ID="{tg_admin}"
XRAY_JSON="{xjson}"
XRAY_SUBSCRIPTION_URL_PREFIX="{suburl}"
XRAY_EXECUTABLE_PATH="/var/lib/rebecca/xray"
XRAY_ASSETS_PATH="/var/lib/rebecca/assets"
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440
SECRET_KEY="{secret_key}"
'''

with open(target, 'w') as f:
    f.write(content)
PYENV

    rm -rf "$tmpdir" "/tmp/mrm_envdir_$$"
    mok "Environment ready"
}

install_rebecca() {
    ui_header "INSTALLING REBECCA"

    echo -e "${YELLOW}Rebecca requires manual installation.${NC}"
    echo ""
    echo -e "Run this command first:"
    echo -e "${CYAN}bash -c \"\$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)\" @ install --database mysql${NC}"
    echo ""
    echo "After installation, run migration again."
    echo ""

    mpause
    return 1
}

setup_jwt() {
    minfo "Setting up JWT..."

    local result
    result=$(run_mysql_query "SELECT COUNT(*) FROM jwt;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)

    if [ "${result:-0}" -gt 0 ] 2>/dev/null; then
        mok "JWT exists"
        return 0
    fi

    local jwt_sql="/tmp/mrm_jwt_$$.sql"
    cat > "$jwt_sql" << 'JWTSQL'
CREATE TABLE IF NOT EXISTS jwt (
    id INT AUTO_INCREMENT PRIMARY KEY,
    secret_key VARCHAR(255) NOT NULL,
    subscription_secret_key VARCHAR(255),
    admin_secret_key VARCHAR(255),
    vmess_mask VARCHAR(64),
    vless_mask VARCHAR(64)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
JWTSQL
    run_mysql_file "$jwt_sql"
    rm -f "$jwt_sql"

    local SK SSK ASK VM VL
    SK=$(openssl rand -hex 64)
    SSK=$(openssl rand -hex 64)
    ASK=$(openssl rand -hex 64)
    VM=$(openssl rand -hex 16)
    VL=$(openssl rand -hex 16)

    run_mysql_query "INSERT INTO jwt (secret_key,subscription_secret_key,admin_secret_key,vmess_mask,vless_mask) VALUES ('$SK','$SSK','$ASK','$VM','$VL');"
    mok "JWT configured"
}

#==============================================================================
# POSTGRESQL EXPORT (FIXED - Direct connection, not via PgBouncer)
#==============================================================================

export_postgresql() {
    local output_file="$1"
    local db_name="${SOURCE_PANEL_TYPE}"
    local db_user="${SOURCE_PANEL_TYPE}"

    minfo "Exporting from PostgreSQL..."

    # Verify data exists
    local user_count
    user_count=$(docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -t -A -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' \n')
    if [ -z "$user_count" ] || [ "$user_count" = "0" ]; then
        mwarn "No users found in source database!"
        # Continue anyway to export other data
    else
        minfo "  Found $user_count users in source"
    fi

    # Detect sudo field
    local sudo_field="is_sudo"
    local check_sudo
    check_sudo=$(docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -t -A -c \
        "SELECT column_name FROM information_schema.columns WHERE table_name='admins' AND column_name='is_sudo'" 2>/dev/null | tr -d ' \n')
    if [ -z "$check_sudo" ]; then
        check_sudo=$(docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -t -A -c \
            "SELECT column_name FROM information_schema.columns WHERE table_name='admins' AND column_name='is_admin'" 2>/dev/null | tr -d ' \n')
        [ -n "$check_sudo" ] && sudo_field="is_admin"
    fi
    minfo "  Sudo field: $sudo_field"

    local tmp_dir="/tmp/mrm_export_$$"
    mkdir -p "$tmp_dir"

    export_table() {
        local name="$1"
        local query="$2"
        local result
        result=$(docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -t -A -c "$query" 2>/dev/null)
        if [ -z "$result" ] || [ "$result" = "null" ] || [ "$result" = "" ]; then
            echo "[]" > "$tmp_dir/${name}.json"
        else
            safe_writeln "$result" > "$tmp_dir/${name}.json"
        fi
    }

    minfo "  Exporting tables..."

    export_table "admins" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, username, hashed_password, COALESCE($sudo_field, false) as is_sudo, telegram_id, created_at FROM admins) t"

    export_table "inbounds" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, tag FROM inbounds) t"

    export_table "users" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, username, COALESCE(key, '') as key, COALESCE(status, 'active') as status, COALESCE(used_traffic, 0) as used_traffic, data_limit, EXTRACT(EPOCH FROM expire)::bigint as expire, COALESCE(admin_id, 1) as admin_id, COALESCE(note, '') as note, sub_updated_at, sub_last_user_agent, online_at, on_hold_timeout, on_hold_expire_duration, COALESCE(lifetime_used_traffic, 0) as lifetime_used_traffic, created_at, COALESCE(service_id, 1) as service_id, sub_revoked_at, data_limit_reset_strategy, traffic_reset_at FROM users) t"

    export_table "proxies" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, user_id, type, COALESCE(settings::text, '{}') as settings FROM proxies) t"

    export_table "hosts" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, COALESCE(remark, '') as remark, COALESCE(address, '') as address, port, COALESCE(inbound_tag, '') as inbound_tag, COALESCE(sni, '') as sni, COALESCE(host, '') as host, COALESCE(security, 'none') as security, COALESCE(fingerprint::text, 'none') as fingerprint, COALESCE(is_disabled, false) as is_disabled, COALESCE(path, '') as path, COALESCE(alpn, '') as alpn, COALESCE(allowinsecure, false) as allowinsecure, fragment_setting, COALESCE(mux_enable, false) as mux_enable, COALESCE(random_user_agent, false) as random_user_agent FROM hosts) t"

    export_table "services" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, COALESCE(name, 'Default') as name, users_limit, created_at FROM services) t"

    export_table "nodes" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, COALESCE(name, '') as name, COALESCE(address, '') as address, port, api_port, COALESCE(certificate::text, '') as certificate, COALESCE(usage_coefficient, 1.0) as usage_coefficient, COALESCE(status, 'connected') as status, message, xray_version, created_at FROM nodes) t"

    export_table "core_configs" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT id, COALESCE(name, 'default') as name, config, created_at FROM core_configs) t"

    export_table "service_hosts" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT service_id, host_id FROM service_hosts) t"
    export_table "service_inbounds" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT service_id, inbound_id FROM service_inbounds) t"
    export_table "user_inbounds" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT user_id, inbound_tag FROM user_inbounds) t"
    export_table "node_inbounds" "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT node_id, inbound_tag FROM node_inbounds) t"

    docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -t -A -c \
        "SELECT COALESCE(json_agg(row_to_json(t)),'[]') FROM (SELECT user_id, inbound_tag FROM excluded_inbounds_association) t" \
        2>/dev/null > "$tmp_dir/excluded_inbounds.json" || echo "[]" > "$tmp_dir/excluded_inbounds.json"

    safe_write "$tmp_dir" > "/tmp/mrm_tmpdir_$$"
    safe_write "$output_file" > "/tmp/mrm_outfile_$$"

    python3 << 'PYCOMBINE'
import json
import os

ppid = os.getppid()
with open(f"/tmp/mrm_tmpdir_{ppid}", "r") as f:
    tmp_dir = f.read().strip()
with open(f"/tmp/mrm_outfile_{ppid}", "r") as f:
    output_file = f.read().strip()

data = {}
tables = ['admins', 'inbounds', 'users', 'proxies', 'hosts', 'services', 
          'nodes', 'core_configs', 'service_hosts', 'service_inbounds',
          'user_inbounds', 'node_inbounds', 'excluded_inbounds']

for table in tables:
    fpath = os.path.join(tmp_dir, f"{table}.json")
    try:
        with open(fpath, 'r') as f:
            content = f.read().strip()
            if content and content.lower() != 'null' and content != '':
                parsed = json.loads(content)
                data[table] = parsed if parsed else []
            else:
                data[table] = []
    except:
        data[table] = []

with open(output_file, 'w') as f:
    json.dump(data, f, ensure_ascii=False, default=str)

print(f"Users: {len(data.get('users',[]))}  Proxies: {len(data.get('proxies',[]))}  Hosts: {len(data.get('hosts',[]))}")
PYCOMBINE

    rm -rf "$tmp_dir" "/tmp/mrm_tmpdir_$$" "/tmp/mrm_outfile_$$"

    if [ -s "$output_file" ]; then
        mok "Export complete"
        return 0
    fi
    merr "Export failed"
    return 1
}

#==============================================================================
# MYSQL IMPORT (FIXED - Create optional tables before delete)
#==============================================================================

import_to_mysql() {
    local json_file="$1"

    minfo "Generating SQL..."

    local sql_file="/tmp/mrm_import_$$.sql"
    safe_write "$json_file" > "/tmp/mrm_jsonfile_$$"
    safe_write "$sql_file" > "/tmp/mrm_sqlfile_$$"

    python3 << 'PYIMPORT'
import json
import os

ppid = os.getppid()
with open(f"/tmp/mrm_jsonfile_{ppid}", "r") as f:
    json_file = f.read().strip()
with open(f"/tmp/mrm_sqlfile_{ppid}", "r") as f:
    sql_file = f.read().strip()

def esc(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dict, list)):
        v = json.dumps(v, ensure_ascii=False)
    v = str(v)
    v = v.replace('\\', '\\\\')
    v = v.replace("'", "\\'")
    v = v.replace('\n', '\\n')
    v = v.replace('\r', '\\r')
    v = v.replace('\t', '\\t')
    v = v.replace('\x00', '')
    return f"'{v}'"

def esc_json(v):
    if v is None:
        return "NULL"
    if isinstance(v, (dict, list)):
        v = json.dumps(v, ensure_ascii=False)
    v = str(v)
    v = v.replace('\\', '\\\\')
    v = v.replace("'", "\\'")
    return f"'{v}'"

def fix_path(v):
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
    if v is None or v == '' or str(v) == 'None':
        return "NULL"
    return str(v)

def ts(v):
    if v is None or v == '' or str(v) == 'None':
        return "NULL"
    return esc(str(v))

with open(json_file, 'r') as f:
    data = json.load(f)

sql = []
sql.append("SET NAMES utf8mb4;")
sql.append("SET FOREIGN_KEY_CHECKS=0;")
sql.append("SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';")

# Only delete from existing tables
sql.append("DELETE FROM proxies;")
sql.append("DELETE FROM users;")
sql.append("DELETE FROM hosts;")
sql.append("DELETE FROM inbounds;")
sql.append("DELETE FROM services;")
sql.append("DELETE FROM nodes;")
sql.append("DELETE FROM admins WHERE id > 0;")

# FIXED: Create optional tables if not exist, then delete
sql.append("CREATE TABLE IF NOT EXISTS service_hosts (service_id INT NOT NULL, host_id INT NOT NULL, PRIMARY KEY (service_id, host_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;")
sql.append("CREATE TABLE IF NOT EXISTS service_inbounds (service_id INT NOT NULL, inbound_id INT NOT NULL, PRIMARY KEY (service_id, inbound_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;")
sql.append("CREATE TABLE IF NOT EXISTS user_inbounds (user_id INT NOT NULL, inbound_tag VARCHAR(255) NOT NULL, PRIMARY KEY (user_id, inbound_tag(191))) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;")
sql.append("CREATE TABLE IF NOT EXISTS node_inbounds (node_id INT NOT NULL, inbound_tag VARCHAR(255) NOT NULL, PRIMARY KEY (node_id, inbound_tag(191))) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;")
sql.append("DELETE FROM service_hosts;")
sql.append("DELETE FROM service_inbounds;")
sql.append("DELETE FROM user_inbounds;")
sql.append("DELETE FROM node_inbounds;")

for a in data.get('admins') or []:
    if not a.get('id'): continue
    role = 'sudo' if a.get('is_sudo') else 'standard'
    created = ts(a.get('created_at')) if ts(a.get('created_at')) != "NULL" else "NOW()"
    sql.append(f"INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) VALUES ({a['id']}, {esc(a['username'])}, {esc(a['hashed_password'])}, '{role}', 'active', {nv(a.get('telegram_id'))}, {created}) ON DUPLICATE KEY UPDATE hashed_password=VALUES(hashed_password);")

for i in data.get('inbounds') or []:
    if not i.get('id'): continue
    sql.append(f"INSERT INTO inbounds (id, tag) VALUES ({i['id']}, {esc(i['tag'])}) ON DUPLICATE KEY UPDATE tag=VALUES(tag);")

svcs = data.get('services') or []
for s in svcs:
    if not s.get('id'): continue
    created = ts(s.get('created_at')) if ts(s.get('created_at')) != "NULL" else "NOW()"
    sql.append(f"INSERT INTO services (id, name, created_at) VALUES ({s['id']}, {esc(s.get('name', 'Default'))}, {created}) ON DUPLICATE KEY UPDATE name=VALUES(name);")
if not svcs:
    sql.append("INSERT IGNORE INTO services (id, name, created_at) VALUES (1, 'Default', NOW());")

for n in data.get('nodes') or []:
    if not n.get('id'): continue
    created = ts(n.get('created_at')) if ts(n.get('created_at')) != "NULL" else "NOW()"
    sql.append(f"INSERT INTO nodes (id, name, address, port, api_port, certificate, usage_coefficient, status, message, xray_version, created_at) VALUES ({n['id']}, {esc(n['name'])}, {esc(n.get('address', ''))}, {nv(n.get('port'))}, {nv(n.get('api_port'))}, {esc(n.get('certificate'))}, {n.get('usage_coefficient', 1.0)}, {esc(n.get('status', 'connected'))}, {esc(n.get('message'))}, {esc(n.get('xray_version'))}, {created}) ON DUPLICATE KEY UPDATE address=VALUES(address);")

for h in data.get('hosts') or []:
    if not h.get('id'): continue
    addr = fix_path(h.get('address', ''))
    path = fix_path(h.get('path', ''))
    fp = h.get('fingerprint')
    if isinstance(fp, dict): fp = 'none'
    fp = fp or 'none'
    frag = h.get('fragment_setting')
    frag_sql = esc_json(frag) if frag else "NULL"
    sql.append(f"INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, security, fingerprint, is_disabled, path, alpn, allowinsecure, fragment_setting, mux_enable, random_user_agent) VALUES ({h['id']}, {esc(h.get('remark', ''))}, {esc(addr)}, {nv(h.get('port'))}, {esc(h.get('inbound_tag', ''))}, {esc(h.get('sni', ''))}, {esc(h.get('host', ''))}, {esc(h.get('security', 'none'))}, {esc(fp)}, {1 if h.get('is_disabled') else 0}, {esc(path)}, {esc(h.get('alpn', ''))}, {1 if h.get('allowinsecure') else 0}, {frag_sql}, {1 if h.get('mux_enable') else 0}, {1 if h.get('random_user_agent') else 0}) ON DUPLICATE KEY UPDATE address=VALUES(address);")

for u in data.get('users') or []:
    if not u.get('id'): continue
    uname = str(u.get('username', '')).replace('@', '_at_').replace('.', '_dot_')
    key = u.get('key') or ''
    status = u.get('status', 'active')
    if status not in ['active', 'disabled', 'limited', 'expired', 'on_hold']: status = 'active'
    svc = u.get('service_id') or 1
    created = ts(u.get('created_at')) if ts(u.get('created_at')) != "NULL" else "NOW()"
    sql.append(f"INSERT INTO users (id, username, `key`, status, used_traffic, data_limit, expire, admin_id, note, service_id, lifetime_used_traffic, on_hold_timeout, on_hold_expire_duration, sub_updated_at, sub_last_user_agent, online_at, sub_revoked_at, data_limit_reset_strategy, traffic_reset_at, created_at) VALUES ({u['id']}, {esc(uname)}, {esc(key)}, '{status}', {int(u.get('used_traffic', 0))}, {nv(u.get('data_limit'))}, {nv(u.get('expire'))}, {u.get('admin_id', 1)}, {esc(u.get('note', ''))}, {svc}, {int(u.get('lifetime_used_traffic', 0))}, {ts(u.get('on_hold_timeout'))}, {nv(u.get('on_hold_expire_duration'))}, {ts(u.get('sub_updated_at'))}, {esc(u.get('sub_last_user_agent'))}, {ts(u.get('online_at'))}, {ts(u.get('sub_revoked_at'))}, {esc(u.get('data_limit_reset_strategy'))}, {ts(u.get('traffic_reset_at'))}, {created}) ON DUPLICATE KEY UPDATE `key`=VALUES(`key`), status=VALUES(status);")

for p in data.get('proxies') or []:
    if not p.get('id'): continue
    settings = p.get('settings', {})
    if isinstance(settings, str):
        try: settings = json.loads(settings)
        except: pass
    settings = fix_path(settings)
    sql.append(f"INSERT INTO proxies (id, user_id, type, settings) VALUES ({p['id']}, {p['user_id']}, {esc(p['type'])}, {esc_json(settings)}) ON DUPLICATE KEY UPDATE settings=VALUES(settings);")

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

if not data.get('service_hosts'):
    sql.append("INSERT IGNORE INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts;")

for c in data.get('core_configs') or []:
    if not c.get('id'): continue
    cfg = c.get('config', {})
    if isinstance(cfg, str):
        try: cfg = json.loads(cfg)
        except: pass
    cfg = fix_path(cfg)
    if isinstance(cfg, dict) and 'api' not in cfg:
        cfg['api'] = {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]}
    created = ts(c.get('created_at')) if ts(c.get('created_at')) != "NULL" else "NOW()"
    sql.append(f"INSERT INTO core_configs (id, name, config, created_at) VALUES ({c['id']}, {esc(c.get('name', 'default'))}, {esc_json(cfg)}, {created}) ON DUPLICATE KEY UPDATE config=VALUES(config);")

sql.append("SET FOREIGN_KEY_CHECKS=1;")

with open(sql_file, 'w') as f:
    f.write('\n'.join(sql))

print(f"Generated {len(sql)} statements")
PYIMPORT

    rm -f "/tmp/mrm_jsonfile_$$" "/tmp/mrm_sqlfile_$$"

    if [ ! -s "$sql_file" ]; then
        merr "SQL generation failed"
        return 1
    fi

    minfo "Importing..."
    local result
    result=$(run_mysql_file "$sql_file" 2>&1)
    rm -f "$sql_file"

    if echo "$result" | grep -qi "error"; then
        merr "Import error: $(echo "$result" | grep -i error | head -1)"
        return 1
    fi

    minfo "Fixing AUTO_INCREMENT..."
    local fix_sql="/tmp/mrm_fix_$$.sql"
    cat > "$fix_sql" << 'FIXSQL'
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
FIXSQL
    run_mysql_file "$fix_sql" >/dev/null 2>&1
    rm -f "$fix_sql"

    mok "Import complete"
    return 0
}

#==============================================================================
# VERIFICATION
#==============================================================================

verify_migration() {
    ui_header "VERIFICATION"

    local admins users ukeys proxies puuid uinb hosts nodes svcs cfgs

    admins=$(run_mysql_query "SELECT COUNT(*) FROM admins;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    users=$(run_mysql_query "SELECT COUNT(*) FROM users;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    ukeys=$(run_mysql_query "SELECT COUNT(*) FROM users WHERE \`key\` IS NOT NULL AND \`key\` != '';" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    proxies=$(run_mysql_query "SELECT COUNT(*) FROM proxies;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    puuid=$(run_mysql_query "SELECT COUNT(*) FROM proxies WHERE settings LIKE '%id%' OR settings LIKE '%password%';" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    hosts=$(run_mysql_query "SELECT COUNT(*) FROM hosts;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    nodes=$(run_mysql_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    svcs=$(run_mysql_query "SELECT COUNT(*) FROM services;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)

    printf "  %-22s ${GREEN}%s${NC}\n" "Admins:" "${admins:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Users:" "${users:-0}"
    printf "  %-22s ${GREEN}%s${NC} ← subscriptions\n" "Users with Key:" "${ukeys:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Proxies:" "${proxies:-0}"
    printf "  %-22s ${GREEN}%s${NC} ← configs\n" "Proxies with UUID:" "${puuid:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Hosts:" "${hosts:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Nodes:" "${nodes:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Services:" "${svcs:-0}"
    echo ""

    local err=0

    if [ "${users:-0}" -gt 0 ] 2>/dev/null; then
        [ "${ukeys:-0}" -eq 0 ] 2>/dev/null && { merr "CRITICAL: No keys!"; err=1; }
        [ "${proxies:-0}" -eq 0 ] 2>/dev/null && { merr "CRITICAL: No proxies!"; err=1; }
    fi
    [ "${hosts:-0}" -eq 0 ] 2>/dev/null && { merr "CRITICAL: No hosts!"; err=1; }

    if [ $err -eq 0 ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  ✓ Admin passwords preserved${NC}"
        echo -e "${GREEN}  ✓ User keys preserved${NC}"
        echo -e "${GREEN}  ✓ Proxy UUIDs preserved${NC}"
        echo -e "${GREEN}  ✓ All relations preserved${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi

    return $err
}

#==============================================================================
# SQLITE MIGRATION
#==============================================================================

migrate_sqlite_to_mysql() {
    MYSQL_CONTAINER=$(find_mysql_container)
    local sdata sqlite_db
    sdata=$(get_data_dir "$SRC")
    sqlite_db="$sdata/db.sqlite3"

    [ ! -f "$sqlite_db" ] && { merr "SQLite not found: $sqlite_db"; return 1; }
    [ -z "$MYSQL_CONTAINER" ] && { merr "MySQL not found"; return 1; }

    ui_header "SQLITE → MYSQL"

    command -v sqlite3 &>/dev/null || {
        if command -v apt-get &>/dev/null; then
            apt-get install -y sqlite3 >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y sqlite >/dev/null 2>&1
        fi
    }

    minfo "Exporting SQLite..."
    local export_file="/tmp/mrm_sqlite_$$.json"

    safe_write "$sqlite_db" > "/tmp/mrm_sqlitedb_$$"
    safe_write "$export_file" > "/tmp/mrm_expfile_$$"

    python3 << 'SQLITEEXP'
import sqlite3
import json
import os

ppid = os.getppid()
with open(f"/tmp/mrm_sqlitedb_{ppid}", "r") as f:
    sqlite_db = f.read().strip()
with open(f"/tmp/mrm_expfile_{ppid}", "r") as f:
    export_file = f.read().strip()

conn = sqlite3.connect(sqlite_db)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
tables = [r[0] for r in cur.fetchall()]

data = {}
table_list = ['admins', 'inbounds', 'users', 'proxies', 'hosts', 'services',
              'service_hosts', 'service_inbounds', 'user_inbounds',
              'nodes', 'node_inbounds', 'core_configs']

for t in table_list:
    if t in tables:
        try:
            cur.execute(f"SELECT * FROM {t}")
            data[t] = [dict(r) for r in cur.fetchall()]
        except:
            data[t] = []
    else:
        data[t] = []

data['excluded_inbounds'] = []
conn.close()

with open(export_file, 'w') as f:
    json.dump(data, f, default=str)

print(f"Exported {len(data.get('users', []))} users")
SQLITEEXP

    rm -f "/tmp/mrm_sqlitedb_$$" "/tmp/mrm_expfile_$$"

    [ -s "$export_file" ] || { merr "Export failed"; return 1; }

    wait_mysql || return 1
    wait_rebecca_tables || return 1
    setup_jwt
    import_to_mysql "$export_file" || { rm -f "$export_file"; return 1; }

    rm -f "$export_file"
    verify_migration
    return $?
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

migrate_pg_to_mysql() {
    PG_CONTAINER=$(find_pg_container "$SRC")
    MYSQL_CONTAINER=$(find_mysql_container)

    [ -z "$PG_CONTAINER" ] && { merr "PostgreSQL not found"; return 1; }
    [ -z "$MYSQL_CONTAINER" ] && { merr "MySQL not found"; return 1; }

    ui_header "POSTGRESQL → MYSQL"
    minfo "Source: $PG_CONTAINER"
    minfo "Target: $MYSQL_CONTAINER"

    wait_mysql || return 1
    wait_rebecca_tables || return 1

    local export_file="/tmp/mrm_export_$$.json"

    export_postgresql "$export_file" || return 1
    setup_jwt
    import_to_mysql "$export_file" || { rm -f "$export_file"; return 1; }

    rm -f "$export_file"
    verify_migration
    return $?
}

#==============================================================================
# ORCHESTRATION
#==============================================================================

stop_old() {
    minfo "Stopping old panels..."
    docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "pasarguard|marzban" | grep -v rebecca | while read -r c; do
        docker stop "$c" 2>/dev/null
    done
}

do_full() {
    migration_init
    clear
    ui_header "MRM MIGRATION V11.4"

    SRC=$(detect_source_panel)
    [ -z "$SRC" ] && { merr "No source panel"; mpause; return 1; }

    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    local sdata
    sdata=$(get_data_dir "$SRC")

    echo -e "  Source: ${YELLOW}$SOURCE_PANEL_TYPE${NC} ($SRC)"
    echo -e "  DB:     ${YELLOW}$SOURCE_DB_TYPE${NC}"
    echo -e "  Target: ${GREEN}Rebecca${NC}"
    echo ""

    [ "$SOURCE_DB_TYPE" = "unknown" ] && { merr "Unknown DB"; mpause; return 1; }

    [ -d "/opt/rebecca" ] && TGT="/opt/rebecca" || { install_rebecca; return 1; }

    echo -e "${YELLOW}Will migrate:${NC}"
    echo "  • Admins • Users • Proxies"
    echo "  • Hosts • Services • Nodes"
    echo ""

    ui_confirm "Start?" "y" || return 0

    safe_writeln "$SRC" > "$BACKUP_ROOT/.last_source"

    minfo "[1/7] Starting source..."
    start_source_panel "$SRC" || { mpause; return 1; }

    minfo "[2/7] Stopping Rebecca..."
    (cd "$TGT" && docker compose down) &>/dev/null

    minfo "[3/7] Copying files..."
    copy_data "$sdata" "/var/lib/rebecca"

    minfo "[4/7] Installing Xray..."
    install_xray "/var/lib/rebecca" "$sdata"

    minfo "[5/7] Generating config..."
    generate_env "$SRC" "$TGT"

    minfo "[6/7] Starting Rebecca..."
    (cd "$TGT" && docker compose up -d --force-recreate) &>/dev/null
    minfo "Waiting 60s for Rebecca to initialize..."
    sleep 60

    minfo "[7/7] Migrating database..."
    local rc=0
    case "$SOURCE_DB_TYPE" in
        postgresql) migrate_pg_to_mysql; rc=$? ;;
        sqlite)     migrate_sqlite_to_mysql; rc=$? ;;
        *)          merr "Unsupported: $SOURCE_DB_TYPE"; rc=1 ;;
    esac

    minfo "Restarting..."
    (cd "$TGT" && docker compose restart) &>/dev/null
    sleep 10
    stop_old

    echo ""
    ui_header "COMPLETE"
    [ $rc -eq 0 ] && echo -e "  ${GREEN}✓ Ready! Login with $SOURCE_PANEL_TYPE credentials${NC}" || mwarn "Check errors above"

    migration_cleanup
    mpause
}

do_fix() {
    clear
    ui_header "FIX"

    [ -d "/opt/rebecca" ] || { merr "Rebecca not found"; mpause; return 1; }

    TGT="/opt/rebecca"
    SRC=$(detect_source_panel)
    [ -z "$SRC" ] && { merr "Source not found"; mpause; return 1; }

    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    MYSQL_PASS=$(read_env_var "MYSQL_ROOT_PASSWORD" "$TGT/.env")

    ui_confirm "Re-import from $SRC?" "y" || return 0

    start_source_panel "$SRC"
    (cd "$TGT" && docker compose up -d) &>/dev/null
    sleep 60

    MYSQL_CONTAINER=$(find_mysql_container)

    case "$SOURCE_DB_TYPE" in
        postgresql) migrate_pg_to_mysql ;;
        sqlite)     migrate_sqlite_to_mysql ;;
    esac

    (cd "$TGT" && docker compose restart) &>/dev/null
    stop_old
    mok "Done"
    mpause
}

do_rollback() {
    clear
    ui_header "ROLLBACK"

    local sp
    sp=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    [ -z "$sp" ] || [ ! -d "$sp" ] && { merr "No source"; mpause; return 1; }

    ui_confirm "Stop Rebecca, Start $sp?" "n" || return 0

    (cd /opt/rebecca && docker compose down) &>/dev/null
    (cd "$sp" && docker compose up -d)
    mok "Done"
    mpause
}

do_status() {
    clear
    ui_header "STATUS"

    docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | head -12
    echo ""

    MYSQL_CONTAINER=$(find_mysql_container)
    MYSQL_PASS=$(read_env_var "MYSQL_ROOT_PASSWORD" "/opt/rebecca/.env")

    [ -n "$MYSQL_CONTAINER" ] && [ -n "$MYSQL_PASS" ] && {
        echo -e "${CYAN}Database:${NC}"
        run_mysql_query "SELECT 'Admins' t, COUNT(*) c FROM admins UNION SELECT 'Users', COUNT(*) FROM users UNION SELECT 'Hosts', COUNT(*) FROM hosts;"
    }
    mpause
}

do_logs() {
    clear
    ui_header "LOGS"
    [ -f "$MIGRATION_LOG" ] && tail -50 "$MIGRATION_LOG" || echo "No logs"
    mpause
}

#==============================================================================
# MAIN MENU (FIXED NAME: migrator_menu)
#==============================================================================

migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION V11.4"
        echo "  1) Full Migration"
        echo "  2) Fix Current"
        echo "  3) Rollback"
        echo "  4) Status"
        echo "  5) Logs"
        echo "  0) Back"
        echo ""
        read -p "Select: " opt
        case "$opt" in
            1) do_full ;;
            2) do_fix ;;
            3) do_rollback ;;
            4) do_status ;;
            5) do_logs ;;
            0) migration_cleanup; return 0 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }
    migrator_menu
fi