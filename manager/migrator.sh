#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V12.10 (SCHEMA COMPATIBILITY FIX)
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
PG_DB_NAME=""
PG_DB_USER=""

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
# SAFE ENV VAR READING
#==============================================================================

read_env_var() {
    local key="$1" file="$2"
    [ -f "$file" ] || return 1

    local line value
    # Regex updated to handle spaces around =
    line=$(grep -E "^${key}[[:space:]]*=" "$file" 2>/dev/null | grep -v "^[[:space:]]*#" | tail -1)
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
# PARSE POSTGRESQL URL
#==============================================================================

parse_pg_connection() {
    local src="$1"
    local env_file="$src/.env"

    [ -f "$env_file" ] || return 1

    local db_url
    db_url=$(read_env_var "SQLALCHEMY_DATABASE_URL" "$env_file")

    if [ -z "$db_url" ]; then
        PG_DB_NAME="${SOURCE_PANEL_TYPE}"
        PG_DB_USER="${SOURCE_PANEL_TYPE}"
        return 0
    fi

    safe_write "$db_url" > "/tmp/mrm_dburl_$$"

    python3 << 'PYPARSE'
import os
import re

ppid = os.getppid()
with open(f"/tmp/mrm_dburl_{ppid}", "r") as f:
    url = f.read().strip()

match = re.match(r'(?:postgresql|postgres)(?:\+\w+)?://([^:]+):([^@]+)@([^:/]+)(?::(\d+))?/(.+?)(?:\?.*)?$', url)

if match:
    user = match.group(1)
    database = match.group(5)
else:
    match = re.match(r'(?:postgresql|postgres)(?:\+\w+)?://([^@]+)@([^:/]+)(?::(\d+))?/(.+?)(?:\?.*)?$', url)
    if match:
        user = match.group(1)
        database = match.group(4)
    else:
        user = "postgres"
        database = "postgres"

with open(f"/tmp/mrm_pguser_{ppid}", "w") as f:
    f.write(user)
with open(f"/tmp/mrm_pgdb_{ppid}", "w") as f:
    f.write(database)
PYPARSE

    PG_DB_USER=$(cat "/tmp/mrm_pguser_$$" 2>/dev/null)
    PG_DB_NAME=$(cat "/tmp/mrm_pgdb_$$" 2>/dev/null)

    rm -f "/tmp/mrm_dburl_$$" "/tmp/mrm_pguser_$$" "/tmp/mrm_pgdb_$$"

    [ -z "$PG_DB_USER" ] && PG_DB_USER="${SOURCE_PANEL_TYPE}"
    [ -z "$PG_DB_NAME" ] && PG_DB_NAME="${SOURCE_PANEL_TYPE}"

    return 0
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
    found=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "${name}.*timescale" | head -1)
    [ -n "$found" ] && { echo "$found"; return 0; }

    found=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "${name}.*(postgres|db)" | grep -v pgbouncer | head -1)
    [ -n "$found" ] && { echo "$found"; return 0; }

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
            parse_pg_connection "$src"
            minfo "  DB User: $PG_DB_USER, DB Name: $PG_DB_NAME"

            waited=0
            while ! docker exec "$PG_CONTAINER" pg_isready -U "$PG_DB_USER" &>/dev/null && [ $waited -lt 60 ]; do
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
# POSTGRESQL EXPORT (CSV method)
#==============================================================================

export_postgresql() {
    local output_file="$1"
    local db_name="$PG_DB_NAME"
    local db_user="$PG_DB_USER"

    minfo "Exporting from PostgreSQL..."
    minfo "  Database: $db_name, User: $db_user"

    # Show table counts
    minfo "  Checking tables..."
    for tbl in users admins proxies hosts inbounds services nodes; do
        local cnt
        cnt=$(docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -t -A -c "SELECT COUNT(*) FROM $tbl;" 2>/dev/null | tr -d ' \n\r')
        [ -n "$cnt" ] && [ "$cnt" != "0" ] && echo "    $tbl: $cnt"
    done

    local tmp_dir="/tmp/mrm_exp_$$"
    mkdir -p "$tmp_dir"

    minfo "  Exporting tables via CSV..."

    # Export each table
    for tbl in admins inbounds users proxies hosts services nodes service_hosts service_inbounds user_inbounds node_inbounds; do
        docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -c \
            "COPY (SELECT * FROM $tbl) TO '/tmp/${tbl}.csv' WITH (FORMAT csv, HEADER true);" 2>/dev/null
        docker cp "$PG_CONTAINER:/tmp/${tbl}.csv" "$tmp_dir/${tbl}.csv" 2>/dev/null
        docker exec "$PG_CONTAINER" rm -f "/tmp/${tbl}.csv" 2>/dev/null
    done

    # Try core_configs
    docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -c \
        "COPY (SELECT * FROM core_configs) TO '/tmp/core_configs.csv' WITH (FORMAT csv, HEADER true);" 2>/dev/null
    docker cp "$PG_CONTAINER:/tmp/core_configs.csv" "$tmp_dir/core_configs.csv" 2>/dev/null
    docker exec "$PG_CONTAINER" rm -f "/tmp/core_configs.csv" 2>/dev/null

    # Convert CSVs to JSON
    safe_write "$tmp_dir" > "/tmp/mrm_tmpdir_$$"
    safe_write "$output_file" > "/tmp/mrm_outfile_$$"

    python3 << 'PYCONVERT'
import csv
import json
import os

ppid = os.getppid()

def read_file(name):
    try:
        with open(f"/tmp/mrm_{name}_{ppid}", "r") as f:
            return f.read().strip()
    except:
        return ""

tmp_dir = read_file("tmpdir")
output_file = read_file("outfile")

data = {}
tables = ['admins', 'inbounds', 'users', 'proxies', 'hosts', 'services', 
          'nodes', 'service_hosts', 'service_inbounds', 'user_inbounds', 
          'node_inbounds', 'core_configs']

def parse_value(val, col_name):
    if val == '' or val is None:
        return None
    if val.lower() in ('t', 'true'):
        return True
    if val.lower() in ('f', 'false'):
        return False
    try:
        if '.' not in val and (val.isdigit() or (val.startswith('-') and val[1:].isdigit())):
            return int(val)
    except:
        pass
    try:
        if '.' in val:
            return float(val)
    except:
        pass
    if col_name in ('settings', 'config', 'fragment_setting') or val.startswith('{') or val.startswith('['):
        try:
            return json.loads(val)
        except:
            pass
    return val

for table in tables:
    csv_path = os.path.join(tmp_dir, f"{table}.csv")
    try:
        if os.path.exists(csv_path) and os.path.getsize(csv_path) > 0:
            with open(csv_path, 'r', encoding='utf-8', errors='replace') as f:
                reader = csv.DictReader(f)
                rows = []
                for row in reader:
                    parsed_row = {}
                    for k, v in row.items():
                        parsed_row[k] = parse_value(v, k)
                    rows.append(parsed_row)
                data[table] = rows
                if rows:
                    print(f"    {table}: {len(rows)} rows")
        else:
            data[table] = []
    except Exception as e:
        print(f"    Error {table}: {e}")
        data[table] = []

data['excluded_inbounds'] = []

# Normalize
def normalize_user(u):
    if 'key' not in u and 'uuid' in u:
        u['key'] = u['uuid']
    if 'key' not in u and 'subscription_key' in u:
        u['key'] = u['subscription_key']
    return u

def normalize_admin(a):
    if 'is_sudo' not in a:
        a['is_sudo'] = a.get('is_admin', False)
    return a

data['users'] = [normalize_user(u) for u in data.get('users', [])]
data['admins'] = [normalize_admin(a) for a in data.get('admins', [])]

with open(output_file, 'w') as f:
    json.dump(data, f, ensure_ascii=False, default=str)

print(f"  Total: Users={len(data.get('users',[]))} Proxies={len(data.get('proxies',[]))} Hosts={len(data.get('hosts',[]))}")
PYCONVERT

    rm -rf "$tmp_dir" "/tmp/mrm_tmpdir_$$" "/tmp/mrm_outfile_$$"

    if [ -s "$output_file" ]; then
        mok "Export complete"
        return 0
    fi
    merr "Export failed"
    return 1
}

#==============================================================================
# GET MYSQL TABLE COLUMNS
#==============================================================================

get_mysql_columns() {
    local table="$1"
    run_mysql_query "SELECT GROUP_CONCAT(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='rebecca' AND TABLE_NAME='$table';" 2>/dev/null | tr -d ' \n\r'
}

#==============================================================================
# MYSQL IMPORT (SCHEMA-AWARE)
#==============================================================================

import_to_mysql() {
    local json_file="$1"

    minfo "Getting target schema..."
    
    # Detect available tables in target
    local target_tables
    target_tables=$(run_mysql_query "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='rebecca';" 2>/dev/null | tr -d '\r')

    # Get column info from MySQL
    local nodes_cols hosts_cols users_cols
    nodes_cols=$(get_mysql_columns "nodes")
    hosts_cols=$(get_mysql_columns "hosts")
    users_cols=$(get_mysql_columns "users")

    minfo "Generating SQL..."

    local sql_file="/tmp/mrm_import_$$.sql"
    safe_write "$json_file" > "/tmp/mrm_jsonfile_$$"
    safe_write "$sql_file" > "/tmp/mrm_sqlfile_$$"
    safe_write "$nodes_cols" > "/tmp/mrm_nodescols_$$"
    safe_write "$hosts_cols" > "/tmp/mrm_hostscols_$$"
    safe_write "$users_cols" > "/tmp/mrm_userscols_$$"
    safe_write "$target_tables" > "/tmp/mrm_tables_$$"

    python3 << 'PYIMPORT'
import json
import os

ppid = os.getppid()

def read_file(name):
    try:
        with open(f"/tmp/mrm_{name}_{ppid}", "r") as f:
            return f.read().strip()
    except:
        return ""

json_file = read_file("jsonfile")
sql_file = read_file("sqlfile")
nodes_cols = set(read_file("nodescols").split(',')) if read_file("nodescols") else set()
hosts_cols = set(read_file("hostscols").split(',')) if read_file("hostscols") else set()
users_cols = set(read_file("userscols").split(',')) if read_file("userscols") else set()
available_tables = set(read_file("tables").split('\n'))

def esc(v, col_name=None):
    if v is None or str(v).lower() == 'none':
        # FIXED: Ensure required columns in Rebecca have a default value
        if col_name in ('alpn', 'sni', 'host', 'address', 'path', 'fingerprint', 'security'):
            if col_name == 'security': return "'none'"
            return "''"
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dict, list)):
        v = json.dumps(v, ensure_ascii=False)
    v = str(v)
    v = v.replace('\\', '\\\\')
    v = v.replace("'", "''") # SQL standard escape
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

def ts(v):
    """FIX: Ensures string dates are valid MySQL DATETIME format."""
    if v is None or v == '' or str(v).lower() == 'none':
        return "NOW()"
    v_str = str(v).replace('T', ' ').replace('Z', '')
    if '+' in v_str:
        v_str = v_str.split('+')[0]
    clean_v = v_str.split('.')[0].strip()
    return f"'{clean_v}'"

def get_expire(u):
    exp = u.get('expire')
    if exp is None or exp == '' or str(exp) == 'None':
        return "NULL"
    if isinstance(exp, (int, float)):
        return str(int(exp))
    if isinstance(exp, str):
        try:
            from datetime import datetime
            if 'T' in exp or '-' in exp:
                for fmt in ['%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M:%S.%f', '%Y-%m-%d %H:%M:%S', '%Y-%m-%d']:
                    try:
                        dt = datetime.strptime(exp.split('+')[0].split('Z')[0], fmt)
                        return str(int(dt.timestamp()))
                    except:
                        continue
            return str(int(float(exp)))
        except:
            return "NULL"
    return "NULL"

with open(json_file, 'r') as f:
    data = json.load(f)

sql = []
sql.append("SET NAMES utf8mb4;")
sql.append("SET FOREIGN_KEY_CHECKS=0;")
sql.append("SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';")

# Cleanup existing only if tables exist
for t in ['proxies', 'users', 'hosts', 'inbounds', 'services', 'nodes', 'service_hosts', 'service_inbounds', 'user_inbounds', 'node_inbounds', 'core_configs']:
    if t in available_tables:
        sql.append(f"DELETE FROM {t};")
sql.append("DELETE FROM admins WHERE id > 0;")

# Admins
for a in data.get('admins') or []:
    if not a.get('id'): continue
    role = 'sudo' if a.get('is_sudo') or a.get('is_admin') else 'standard'
    sql.append(f"INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) VALUES ({a['id']}, {esc(a.get('username',''))}, {esc(a.get('hashed_password',''))}, '{role}', 'active', {esc(a.get('telegram_id'))}, {ts(a.get('created_at'))}) ON DUPLICATE KEY UPDATE hashed_password=VALUES(hashed_password);")

# Inbounds
for i in data.get('inbounds') or []:
    if not i.get('id'): continue
    sql.append(f"INSERT INTO inbounds (id, tag) VALUES ({i['id']}, {esc(i.get('tag',''))}) ON DUPLICATE KEY UPDATE tag=VALUES(tag);")

# Services
sql.append("INSERT IGNORE INTO services (id, name, created_at) VALUES (1, 'Default', NOW());")

# Nodes
for n in data.get('nodes') or []:
    if not n.get('id'): continue
    cols, vals = ['id', 'name', 'address', 'port', 'status', 'created_at'], [str(n['id']), esc(n.get('name','')), esc(n.get('address', '')), str(n.get('port') or 0), esc(n.get('status', 'connected')), ts(n.get('created_at'))]
    if 'uplink' in nodes_cols: cols.append('uplink'); vals.append(str(int(n.get('uplink') or 0)))
    if 'downlink' in nodes_cols: cols.append('downlink'); vals.append(str(int(n.get('downlink') or 0)))
    sql.append(f"INSERT INTO nodes ({','.join(cols)}) VALUES ({','.join(vals)}) ON DUPLICATE KEY UPDATE address=VALUES(address);")

# Hosts
for h in data.get('hosts') or []:
    if not h.get('id'): continue
    cols, vals = ['id', 'remark', 'address', 'port', 'inbound_tag', 'sni', 'host', 'security', 'is_disabled'], [str(h['id']), esc(h.get('remark', '')), esc(fix_path(h.get('address', '')), 'address'), str(h.get('port') or 0), esc(h.get('inbound_tag') or h.get('tag', '')), esc(h.get('sni', ''), 'sni'), esc(h.get('host', ''), 'host'), esc(h.get('security', 'none'), 'security'), str(1 if h.get('is_disabled') else 0)]
    if 'alpn' in hosts_cols: cols.append('alpn'); vals.append(esc(h.get('alpn', ''), 'alpn'))
    sql.append(f"INSERT INTO hosts ({','.join(cols)}) VALUES ({','.join(vals)}) ON DUPLICATE KEY UPDATE address=VALUES(address);")

# Detect Key/Token column in target
target_user_key_col = None
if 'key' in users_cols: target_user_key_col = '`key`'
elif 'token' in users_cols: target_user_key_col = 'token'

# Users
for u in data.get('users') or []:
    if not u.get('id'): continue
    uname = str(u.get('username', '')).replace('@', '_at_').replace('.', '_dot_')
    key = u.get('key') or u.get('uuid') or u.get('subscription_key') or ''
    cols = ['id', 'username', 'status', 'used_traffic', 'admin_id', 'service_id', 'created_at']
    vals = [str(u['id']), esc(uname), "'active'", str(int(u.get('used_traffic') or 0)), "1", "1", ts(u.get('created_at'))]
    if target_user_key_col: cols.append(target_user_key_col); vals.append(esc(key))
    if 'expire' in users_cols: cols.append('expire'); vals.append(get_expire(u))
    sql.append(f"INSERT INTO users ({','.join(cols)}) VALUES ({','.join(vals)}) ON DUPLICATE KEY UPDATE status=VALUES(status);")

# Proxies
for p in data.get('proxies') or []:
    if not p.get('id'): continue
    sql.append(f"INSERT INTO proxies (id, user_id, type, settings) VALUES ({p['id']}, {p.get('user_id',0)}, {esc(p.get('type',''))}, {esc(fix_path(p.get('settings', {})))}) ON DUPLICATE KEY UPDATE settings=VALUES(settings);")

# Auto-Fix Missing Relations & Proxies
if 'proxies' in available_tables and target_user_key_col:
    sql.append(f"INSERT IGNORE INTO proxies (user_id, type, settings) SELECT id, 'vless', CONCAT('{{\"id\": \"', {target_user_key_col}, '\", \"flow\": \"\"}}') FROM users WHERE {target_user_key_col} != '';")
if 'user_inbounds' in available_tables:
    sql.append("INSERT IGNORE INTO user_inbounds (user_id, inbound_tag) SELECT u.id, i.tag FROM users u CROSS JOIN inbounds i;")
if 'service_inbounds' in available_tables:
    sql.append("INSERT IGNORE INTO service_inbounds (service_id, inbound_id) SELECT 1, id FROM inbounds;")
if 'service_hosts' in available_tables:
    sql.append("INSERT IGNORE INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts;")

sql.append("SET FOREIGN_KEY_CHECKS=1;")
with open(sql_file, 'w') as f: f.write('\n'.join(sql))
PYIMPORT

    rm -f "/tmp/mrm_jsonfile_$$" "/tmp/mrm_sqlfile_$$" "/tmp/mrm_nodescols_$$" "/tmp/mrm_hostscols_$$" "/tmp/mrm_userscols_$$" "/tmp/mrm_tables_$$"

    if [ ! -s "$sql_file" ]; then
        merr "SQL generation failed"
        return 1
    fi

    minfo "Importing..."
    local result; result=$(run_mysql_file "$sql_file" 2>&1)
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

    local admins users ukeys proxies hosts nodes svcs
    local key_col; key_col=$(run_mysql_query "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='rebecca' AND TABLE_NAME='users' AND COLUMN_NAME IN ('key', 'token') LIMIT 1;" | tr -d ' \n\r')
    [ -z "$key_col" ] && key_col="key"

    admins=$(run_mysql_query "SELECT COUNT(*) FROM admins;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    users=$(run_mysql_query "SELECT COUNT(*) FROM users;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    ukeys=$(run_mysql_query "SELECT COUNT(*) FROM users WHERE \`$key_col\` IS NOT NULL AND \`$key_col\` != '';" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    proxies=$(run_mysql_query "SELECT COUNT(*) FROM proxies;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    hosts=$(run_mysql_query "SELECT COUNT(*) FROM hosts;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    nodes=$(run_mysql_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    svcs=$(run_mysql_query "SELECT COUNT(*) FROM services;" 2>/dev/null | grep -oE '^[0-9]+' | head -1)

    printf "  %-22s ${GREEN}%s${NC}\n" "Admins:" "${admins:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Users:" "${users:-0}"
    printf "  %-22s ${GREEN}%s${NC} ← subscriptions\n" "Users with Key:" "${ukeys:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Proxies:" "${proxies:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Hosts:" "${hosts:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Nodes:" "${nodes:-0}"
    printf "  %-22s ${GREEN}%s${NC}\n" "Services:" "${svcs:-0}"
    echo ""

    [ "${users:-0}" -gt 0 ] && mok "Migration successful" || merr "Migration failed"
    return 0
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
    command -v sqlite3 &>/dev/null || apt-get install -y sqlite3 >/dev/null 2>&1

    minfo "Exporting SQLite..."
    local export_file="/tmp/mrm_sqlite_$$.json"
    safe_write "$sqlite_db" > "/tmp/mrm_sqlitedb_$$"
    python3 << 'EOF'
import sqlite3, json, os
ppid = os.getppid()
with open(f"/tmp/mrm_sqlitedb_{ppid}", "r") as f: db_path = f.read().strip()
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()
data = {}
for t in ['admins', 'inbounds', 'users', 'proxies', 'hosts', 'services', 'nodes']:
    try:
        cur.execute(f"SELECT * FROM {t}")
        data[t] = [dict(r) for r in cur.fetchall()]
    except: data[t] = []
with open(f"/tmp/mrm_sqlite_{ppid}.json", "w") as f: json.dump(data, f, default=str)
EOF
    wait_mysql || return 1
    wait_rebecca_tables || return 1
    setup_jwt
    import_to_mysql "$export_file"
    rm -f "$export_file"
    verify_migration
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
    wait_mysql || return 1
    wait_rebecca_tables || return 1
    
    parse_pg_connection "$SRC"

    local export_file="/tmp/mrm_export_$$.json"
    export_postgresql "$export_file" || return 1
    setup_jwt
    import_to_mysql "$export_file" || { rm -f "$export_file"; return 1; }
    rm -f "$export_file"
    verify_migration
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
    ui_header "MRM MIGRATION V12.10"

    SRC=$(detect_source_panel)
    [ -z "$SRC" ] && { merr "No source panel"; mpause; return 1; }

    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    parse_pg_connection "$SRC"
    local sdata; sdata=$(get_data_dir "$SRC")

    echo -e "  Source: ${YELLOW}$SOURCE_PANEL_TYPE${NC} ($SRC)"
    echo -e "  DB:     ${YELLOW}$SOURCE_DB_TYPE${NC}"
    echo -e "  Target: ${GREEN}Rebecca${NC}"
    echo ""

    [ "$SOURCE_DB_TYPE" = "unknown" ] && { merr "Unknown DB"; mpause; return 1; }
    [ -d "/opt/rebecca" ] && TGT="/opt/rebecca" || { install_rebecca; return 1; }

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
    minfo "Initializing Rebecca (60s)..."
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

    ui_header "COMPLETE"
    [ $rc -eq 0 ] && echo -e "  ${GREEN}✓ Ready! Login with $SOURCE_PANEL_TYPE credentials${NC}" || mwarn "Check logs"

    migration_cleanup
    mpause
}

do_fix() {
    clear
    ui_header "FIX"
    TGT="/opt/rebecca"
    SRC=$(detect_source_panel)
    [ -z "$SRC" ] && { merr "Source not found"; mpause; return 1; }
    MYSQL_PASS=$(read_env_var "MYSQL_ROOT_PASSWORD" "$TGT/.env")
    start_source_panel "$SRC"
    (cd "$TGT" && docker compose up -d) &>/dev/null
    sleep 60
    migrate_pg_to_mysql
    (cd "$TGT" && docker compose restart) &>/dev/null
    stop_old
    mok "Done"
    mpause
}

do_rollback() {
    clear
    ui_header "ROLLBACK"
    local sp; sp=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    [ -z "$sp" ] && { merr "No source"; mpause; return 1; }
    ui_confirm "Rollback?" "n" || return 0
    (cd /opt/rebecca && docker compose down) &>/dev/null
    (cd "$sp" && docker compose up -d)
    mpause
}

do_status() {
    clear
    ui_header "STATUS"
    docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | head -12
    MYSQL_CONTAINER=$(find_mysql_container)
    MYSQL_PASS=$(read_env_var "MYSQL_ROOT_PASSWORD" "/opt/rebecca/.env")
    [ -n "$MYSQL_CONTAINER" ] && { echo -e "${CYAN}DB Stats:${NC}"; run_mysql_query "SELECT 'Users' t, COUNT(*) c FROM users UNION SELECT 'Proxies', COUNT(*) FROM proxies;"; }
    mpause
}

do_logs() { clear; ui_header "LOGS"; [ -f "$MIGRATION_LOG" ] && tail -50 "$MIGRATION_LOG"; mpause; }

migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION V12.10"
        echo -e "  1) Full Migration\n  2) Fix Current\n  3) Rollback\n  4) Status\n  5) Logs\n  0) Back\n"
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