#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V12.11 (FINAL AUTOMATED REPAIR) - FIXED BUILD (STABLE)
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

safe_write() { printf '%s' "$1"; }
safe_writeln() { printf '%s\n' "$1"; }

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
    command -v wget &>/dev/null || missing="$missing wget"

    if [ -n "$missing" ]; then
        echo -e "${YELLOW}Installing:$missing${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y python3 docker.io openssl curl unzip wget &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y python3 docker openssl curl unzip wget &>/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y python3 docker openssl curl unzip wget &>/dev/null
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
# LOAD MYSQL PASSWORD SAFELY
#==============================================================================

load_mysql_pass() {
    if [ -z "$MYSQL_PASS" ] && [ -f "/opt/rebecca/.env" ]; then
        MYSQL_PASS=$(read_env_var "MYSQL_ROOT_PASSWORD" "/opt/rebecca/.env")
    fi
    if [ -z "$MYSQL_PASS" ] && [ -n "$TGT" ] && [ -f "$TGT/.env" ]; then
        MYSQL_PASS=$(read_env_var "MYSQL_ROOT_PASSWORD" "$TGT/.env")
    fi
    return 0
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
# SAFE MYSQL EXECUTION (EXIT CODE + OUTPUT VISIBLE)
#==============================================================================

run_mysql_query() {
    local query="$1"
    load_mysql_pass

    if [ -z "$MYSQL_CONTAINER" ]; then
        merr "MySQL container not found"
        return 1
    fi

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

    docker exec "$MYSQL_CONTAINER" bash -c 'mysql --defaults-file=/tmp/.my.cnf rebecca -N < /tmp/.q.sql 2>&1; rc=$?; rm -f /tmp/.my.cnf /tmp/.q.sql; exit $rc'
}

run_mysql_file() {
    local sql_file="$1"
    load_mysql_pass

    if [ -z "$MYSQL_CONTAINER" ]; then
        merr "MySQL container not found"
        return 1
    fi

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

    docker exec "$MYSQL_CONTAINER" bash -c 'mysql --defaults-file=/tmp/.my.cnf rebecca < /tmp/import.sql 2>&1; rc=$?; rm -f /tmp/.my.cnf /tmp/import.sql; exit $rc'
}

wait_mysql() {
    minfo "Waiting for MySQL..."
    local waited=0
    load_mysql_pass

    if [ -z "$MYSQL_CONTAINER" ]; then
        merr "MySQL container not found"
        return 1
    fi

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
        local out rc
        out=$(run_mysql_query "SHOW TABLES LIKE 'users';" 2>&1)
        rc=$?
        if [ $rc -ne 0 ]; then
            mwarn "MySQL query failed while waiting for tables:"
            echo "$out" | head -20
            mlog "MYSQL WAIT ERROR: $(echo "$out" | tr '\n' ' ' | cut -c1-500)"
            return 1
        fi

        local tables
        tables=$(echo "$out" | grep -c "users" 2>/dev/null)

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
            while ! docker exec "$PG_CONTAINER" pg_isready -U "$PG_DB_USER" -d "$PG_DB_NAME" &>/dev/null && [ $waited -lt 60 ]; do
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
    PORT=$(read_env_var "UVICORN_PORT" "$se"); [ -z "$PORT" ] && PORT="8000"
    SUSER=$(read_env_var "SUDO_USERNAME" "$se"); [ -z "$SUSER" ] && SUSER="admin"
    SPASS=$(read_env_var "SUDO_PASSWORD" "$se"); [ -z "$SPASS" ] && SPASS="admin"

    TG_TOKEN=$(read_env_var "TELEGRAM_API_TOKEN" "$se")
    TG_ADMIN=$(read_env_var "TELEGRAM_ADMIN_ID" "$se")
    CERT=$(read_env_var "UVICORN_SSL_CERTFILE" "$se")
    KEY=$(read_env_var "UVICORN_SSL_KEYFILE" "$se")
    XJSON=$(read_env_var "XRAY_JSON" "$se")
    SUBURL=$(read_env_var "XRAY_SUBSCRIPTION_URL_PREFIX" "$se")

    CERT="${CERT//pasarguard/rebecca}"; CERT="${CERT//marzban/rebecca}"
    KEY="${KEY//pasarguard/rebecca}";   KEY="${KEY//marzban/rebecca}"
    XJSON="${XJSON//pasarguard/rebecca}"; XJSON="${XJSON//marzban/rebecca}"
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
import urllib.parse, secrets, os

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

    local out rc
    out=$(run_mysql_query "SELECT COUNT(*) FROM jwt;" 2>&1); rc=$?
    if [ $rc -ne 0 ]; then
        merr "JWT check failed:"
        echo "$out" | head -20
        return 1
    fi

    local result
    result=$(echo "$out" | grep -oE '^[0-9]+' | head -1)

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

    out=$(run_mysql_file "$jwt_sql" 2>&1); rc=$?
    rm -f "$jwt_sql"
    if [ $rc -ne 0 ]; then
        merr "JWT table create failed:"
        echo "$out" | head -30
        return 1
    fi

    local SK SSK ASK VM VL
    SK=$(openssl rand -hex 64)
    SSK=$(openssl rand -hex 64)
    ASK=$(openssl rand -hex 64)
    VM=$(openssl rand -hex 16)
    VL=$(openssl rand -hex 16)

    out=$(run_mysql_query "INSERT INTO jwt (secret_key,subscription_secret_key,admin_secret_key,vmess_mask,vless_mask) VALUES ('$SK','$SSK','$ASK','$VM','$VL');" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        merr "JWT insert failed:"
        echo "$out" | head -30
        return 1
    fi

    mok "JWT configured"
}

#==============================================================================
# POSTGRESQL EXPORT (AUTO TABLE RESOLVE ACROSS SCHEMAS)
#==============================================================================

pg_list_tables() {
    docker exec "$PG_CONTAINER" psql -U "$PG_DB_USER" -d "$PG_DB_NAME" -tAc "
        SELECT table_schema||'.'||table_name
        FROM information_schema.tables
        WHERE table_type='BASE TABLE'
          AND table_schema NOT IN ('pg_catalog','information_schema')
        ORDER BY table_schema, table_name;
    " 2>/dev/null | tr -d '\r'
}

pg_find_table() {
    local canonical="$1"
    local candidates=()

    case "$canonical" in
        admins)           candidates=(admins admin) ;;
        inbounds)         candidates=(inbounds inbound) ;;
        users)            candidates=(users user) ;;
        proxies)          candidates=(proxies proxy) ;;
        hosts)            candidates=(hosts host) ;;
        services)         candidates=(services service) ;;
        nodes)            candidates=(nodes node) ;;
        service_hosts)    candidates=(service_hosts service_host servicehosts servicehost) ;;
        service_inbounds) candidates=(service_inbounds service_inbound serviceinbounds serviceinbound) ;;
        user_inbounds)    candidates=(user_inbounds user_inbound userinbounds userinbound) ;;
        node_inbounds)    candidates=(node_inbounds node_inbound nodeinbounds nodeinbound) ;;
        core_configs)     candidates=(core_configs core_config coreconfigs coreconfig configs config) ;;
        *)                candidates=("$canonical") ;;
    esac

    local c out
    for c in "${candidates[@]}"; do
        out=$(docker exec "$PG_CONTAINER" psql -U "$PG_DB_USER" -d "$PG_DB_NAME" -tAc "
            SELECT table_schema||'.'||table_name
            FROM information_schema.tables
            WHERE table_type='BASE TABLE'
              AND table_schema NOT IN ('pg_catalog','information_schema')
              AND lower(table_name)=lower('${c}')
            ORDER BY (CASE WHEN lower(table_name)=lower('${canonical}') THEN 0 ELSE 1 END), table_schema
            LIMIT 1;
        " 2>/dev/null | tr -d ' \r\n')
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    done
    return 1
}

export_postgresql() {
    local output_file="$1"
    local db_name="$PG_DB_NAME"
    local db_user="$PG_DB_USER"

    minfo "Exporting from PostgreSQL..."

    local all_tbls
    all_tbls=$(pg_list_tables)
    if [ -n "$all_tbls" ]; then
        mlog "PG TABLES (first): $(echo "$all_tbls" | head -200 | tr '\n' ' ' | cut -c1-1500)"
    else
        mwarn "Could not list PostgreSQL tables (permission or connection issue?)"
    fi

    local tmp_dir="/tmp/mrm_exp_$$"
    mkdir -p "$tmp_dir"

    local tables=(admins inbounds users proxies hosts services nodes service_hosts service_inbounds user_inbounds node_inbounds core_configs)

    for tbl in "${tables[@]}"; do
        local real
        real=$(pg_find_table "$tbl" 2>/dev/null)

        if [ -z "$real" ]; then
            mwarn "PG table not found (any schema), skipping: $tbl"
            continue
        fi

        minfo "  Export $tbl <= $real"

        local out rc
        out=$(docker exec "$PG_CONTAINER" psql -U "$db_user" -d "$db_name" -c \
            "COPY (SELECT * FROM ${real}) TO '/tmp/${tbl}.csv' WITH (FORMAT csv, HEADER true);" 2>&1)
        rc=$?

        if [ $rc -ne 0 ]; then
            mwarn "PG export failed for $real (as $tbl):"
            echo "$out" | head -10
            mlog "PG EXPORT ERROR ($real): $(echo "$out" | tr '\n' ' ' | cut -c1-1500)"
            continue
        fi

        docker cp "$PG_CONTAINER:/tmp/${tbl}.csv" "$tmp_dir/${tbl}.csv" 2>/dev/null
        docker exec "$PG_CONTAINER" rm -f "/tmp/${tbl}.csv" 2>/dev/null
    done

    safe_write "$tmp_dir" > "/tmp/mrm_tmpdir_$$"
    safe_write "$output_file" > "/tmp/mrm_outfile_$$"

    python3 << 'PYCONVERT'
import csv, json, os
ppid = os.getppid()
with open(f"/tmp/mrm_tmpdir_{ppid}", "r") as f: tmp_dir = f.read().strip()
with open(f"/tmp/mrm_outfile_{ppid}", "r") as f: output_file = f.read().strip()

data = {}
def parse_v(val, col):
    if val == '' or val is None: return None
    if isinstance(val, str) and val.lower() in ('t', 'true'): return True
    if isinstance(val, str) and val.lower() in ('f', 'false'): return False
    if col in ('settings', 'config', 'fragment_setting'):
        try: return json.loads(val)
        except: pass
    return val

tables = ['admins', 'inbounds', 'users', 'proxies', 'hosts', 'services', 'nodes',
          'service_hosts', 'service_inbounds', 'user_inbounds', 'node_inbounds', 'core_configs']

for table in tables:
    p = os.path.join(tmp_dir, f"{table}.csv")
    if os.path.exists(p) and os.path.getsize(p) > 0:
        with open(p, 'r', encoding='utf-8', errors='replace') as f:
            reader = csv.DictReader(f)
            data[table] = [{k: parse_v(v, k) for k, v in row.items()} for row in reader]
    else:
        data[table] = []

with open(output_file, 'w') as f:
    json.dump(data, f, default=str)
PYCONVERT

    local py_rc=$?
    rm -rf "$tmp_dir" "/tmp/mrm_tmpdir_$$" "/tmp/mrm_outfile_$$"

    if [ $py_rc -ne 0 ]; then
        merr "PostgreSQL export conversion failed"
        return 1
    fi

    if [ ! -s "$output_file" ]; then
        merr "PostgreSQL export output JSON is empty"
        return 1
    fi

    mok "PostgreSQL export ready: $output_file"
    return 0
}

#==============================================================================
# SQLITE EXPORT
#==============================================================================

export_sqlite() {
    local sqlite_db="$1"
    local output_file="$2"

    [ -f "$sqlite_db" ] || { merr "SQLite DB not found: $sqlite_db"; return 1; }

    safe_write "$sqlite_db" > "/tmp/mrm_sqlitedb_$$"
    safe_write "$output_file" > "/tmp/mrm_sqliteout_$$"

    python3 << 'PYSQLITE'
import os, json, sqlite3

ppid = os.getppid()
with open(f"/tmp/mrm_sqlitedb_{ppid}", "r") as f: db = f.read().strip()
with open(f"/tmp/mrm_sqliteout_{ppid}", "r") as f: out = f.read().strip()

tables = ['admins', 'inbounds', 'users', 'proxies', 'hosts', 'services', 'nodes',
          'service_hosts', 'service_inbounds', 'user_inbounds', 'node_inbounds', 'core_configs']

def maybe_json(col, val):
    if val is None:
        return None
    if col in ('settings','config','fragment_setting'):
        if isinstance(val, (bytes, bytearray)):
            try:
                val = val.decode('utf-8', 'replace')
            except Exception:
                return str(val)
        if isinstance(val, str):
            try:
                return json.loads(val)
            except Exception:
                return val
    if isinstance(val, (bytes, bytearray)):
        try:
            return val.decode('utf-8', 'replace')
        except Exception:
            return str(val)
    return val

con = sqlite3.connect(db)
con.row_factory = sqlite3.Row
data = {}
for t in tables:
    try:
        cur = con.execute(f"SELECT * FROM {t}")
        rows = cur.fetchall()
        data[t] = [{k: maybe_json(k, r[k]) for k in r.keys()} for r in rows]
    except Exception:
        data[t] = []

with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, default=str)
con.close()
PYSQLITE

    local py_rc=$?
    rm -f "/tmp/mrm_sqlitedb_$$" "/tmp/mrm_sqliteout_$$"
    if [ $py_rc -ne 0 ]; then
        merr "SQLite export failed"
        return 1
    fi
    mok "SQLite exported: $output_file"
    return 0
}

#==============================================================================
# GET MYSQL TABLE COLUMNS
#==============================================================================

get_mysql_columns() {
    local table="$1"
    local out rc
    out=$(run_mysql_query "SELECT GROUP_CONCAT(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='rebecca' AND TABLE_NAME='$table';" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        mwarn "Failed to read columns for $table:"
        echo "$out" | head -5
        return 0
    fi
    echo "$out" | tr -d ' \n\r'
}

#==============================================================================
# MYSQL IMPORT (WITH SMART RELATIONSHIP REPAIR)
#==============================================================================

import_to_mysql() {
    local json_file="$1"

    if [ ! -f "$json_file" ] || [ ! -s "$json_file" ]; then
        merr "JSON import file missing/empty: $json_file"
        return 1
    fi

    local target_tables
    target_tables=$(run_mysql_query "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='rebecca';" 2>/dev/null | tr -d '\r')

    # Read columns for schema-aware inserts
    local admins_cols; admins_cols=$(get_mysql_columns "admins")
    local inbounds_cols; inbounds_cols=$(get_mysql_columns "inbounds")
    local services_cols; services_cols=$(get_mysql_columns "services")
    local proxies_cols; proxies_cols=$(get_mysql_columns "proxies")
    local nodes_cols; nodes_cols=$(get_mysql_columns "nodes")
    local hosts_cols; hosts_cols=$(get_mysql_columns "hosts")
    local users_cols; users_cols=$(get_mysql_columns "users")
    local user_inbounds_cols; user_inbounds_cols=$(get_mysql_columns "user_inbounds")
    local service_inbounds_cols; service_inbounds_cols=$(get_mysql_columns "service_inbounds")
    local service_hosts_cols; service_hosts_cols=$(get_mysql_columns "service_hosts")

    local sql_file="/tmp/mrm_import_$$.sql"
    safe_write "$json_file" > "/tmp/mrm_jsonfile_$$"
    safe_write "$sql_file" > "/tmp/mrm_sqlfile_$$"
    safe_write "$admins_cols" > "/tmp/mrm_adminscols_$$"
    safe_write "$inbounds_cols" > "/tmp/mrm_inboundscols_$$"
    safe_write "$services_cols" > "/tmp/mrm_servicescols_$$"
    safe_write "$proxies_cols" > "/tmp/mrm_proxiescols_$$"
    safe_write "$nodes_cols" > "/tmp/mrm_nodescols_$$"
    safe_write "$hosts_cols" > "/tmp/mrm_hostscols_$$"
    safe_write "$users_cols" > "/tmp/mrm_userscols_$$"
    safe_write "$user_inbounds_cols" > "/tmp/mrm_userinboundscols_$$"
    safe_write "$service_inbounds_cols" > "/tmp/mrm_serviceinboundscols_$$"
    safe_write "$service_hosts_cols" > "/tmp/mrm_servicehostscols_$$"
    safe_write "$target_tables" > "/tmp/mrm_tables_$$"

    python3 << 'PYIMPORT'
import json, os
ppid = os.getppid()

def r_f(n):
    try:
        with open(f"/tmp/mrm_{n}_{ppid}", "r") as f:
            return f.read().strip()
    except:
        return ""

def colset(s: str):
    return set([x for x in (s or "").split(",") if x])

json_f, sql_f = r_f("jsonfile"), r_f("sqlfile")

a_cols  = colset(r_f("adminscols"))
i_cols  = colset(r_f("inboundscols"))
sv_cols = colset(r_f("servicescols"))
p_cols  = colset(r_f("proxiescols"))
n_cols  = colset(r_f("nodescols"))
h_cols  = colset(r_f("hostscols"))
u_cols  = colset(r_f("userscols"))
ui_cols = colset(r_f("userinboundscols"))
si_cols = colset(r_f("serviceinboundscols"))
sh_cols = colset(r_f("servicehostscols"))

available_tables = set([x for x in (r_f("tables") or "").split("\n") if x])

def esc(v, col=None):
    if v is None or str(v).lower() == 'none':
        if col in ('alpn', 'sni', 'host', 'address', 'path', 'fingerprint', 'security'):
            if col == 'security': return "'none'"
            return "''"
        return "NULL"
    s = str(v)
    s = s.replace("\\", "\\\\").replace("'", "''")
    return f"'{s}'"

def ts(v):
    if v is None or v == '' or str(v).lower() == 'none':
        return "NOW()"
    clean = str(v).replace('T', ' ').replace('Z', '').split('+')[0].split('.')[0].strip()
    return f"'{clean}'"

def bt(col):
    # always safe to backtick
    return f"`{col}`"

def add(cols_list, vals_list, cols_set, colname, value_sql):
    if colname in cols_set:
        cols_list.append(bt(colname))
        vals_list.append(value_sql)
        return True
    return False

# Load JSON
with open(json_f, 'r') as f:
    data = json.load(f)

sql = ["SET NAMES utf8mb4;", "SET FOREIGN_KEY_CHECKS=0;"]

# Cleanup (only if table exists)
for t in ['proxies', 'users', 'hosts', 'inbounds', 'services', 'nodes',
          'service_hosts', 'service_inbounds', 'user_inbounds', 'core_configs']:
    if t in available_tables:
        sql.append(f"DELETE FROM {t};")
if 'admins' in available_tables:
    sql.append("DELETE FROM admins WHERE id > 0;")

# Detect key column on users
k_col = None
for p in ['key', 'token', 'uuid']:
    if p in u_cols:
        k_col = bt(p)
        break

# -------------------------
# Admins (schema-aware)
# -------------------------
if 'admins' in available_tables:
    for a in data.get('admins', []):
        cols, vals = [], []
        add(cols, vals, a_cols, 'id', str(a.get('id', 0)))
        # username
        if 'username' in a_cols:
            add(cols, vals, a_cols, 'username', esc(a.get('username')))
        elif 'user_name' in a_cols:
            add(cols, vals, a_cols, 'user_name', esc(a.get('username')))
        # password
        if 'hashed_password' in a_cols:
            add(cols, vals, a_cols, 'hashed_password', esc(a.get('hashed_password')))
        elif 'password' in a_cols:
            add(cols, vals, a_cols, 'password', esc(a.get('hashed_password') or a.get('password')))
        # role/status/created_at if exist
        add(cols, vals, a_cols, 'role', "'sudo'")
        add(cols, vals, a_cols, 'status', "'active'")
        add(cols, vals, a_cols, 'created_at', ts(a.get('created_at')))

        if cols:
            sql.append(f"INSERT INTO admins ({','.join(cols)}) VALUES ({','.join(vals)});")

# -------------------------
# Inbounds (schema-aware)  ✅ FIX HERE
# -------------------------
inb_tag_col = None
for c in ['tag', 'inbound_tag', 'name']:
    if c in i_cols:
        inb_tag_col = c
        break

inb_proto_col = None
for c in ['protocol', 'type', 'proto']:
    if c in i_cols:
        inb_proto_col = c
        break

if 'inbounds' in available_tables:
    for i in data.get('inbounds', []):
        cols, vals = [], []
        add(cols, vals, i_cols, 'id', str(i.get('id', 0)))

        if inb_tag_col:
            add(cols, vals, i_cols, inb_tag_col, esc(i.get('tag') or i.get(inb_tag_col)))
        if inb_proto_col:
            # source might have protocol; map it into whatever exists
            add(cols, vals, i_cols, inb_proto_col, esc(i.get('protocol') or i.get('type') or i.get(inb_proto_col)))

        if cols:
            sql.append(f"INSERT IGNORE INTO inbounds ({','.join(cols)}) VALUES ({','.join(vals)});")

# -------------------------
# Services (schema-aware default)
# -------------------------
if 'services' in available_tables:
    cols, vals = [], []
    add(cols, vals, sv_cols, 'id', "1")
    if 'name' in sv_cols:
        add(cols, vals, sv_cols, 'name', esc("Default"))
    elif 'title' in sv_cols:
        add(cols, vals, sv_cols, 'title', esc("Default"))
    add(cols, vals, sv_cols, 'created_at', "NOW()")
    if cols:
        sql.append(f"INSERT IGNORE INTO services ({','.join(cols)}) VALUES ({','.join(vals)});")

# -------------------------
# Nodes (schema-aware)
# -------------------------
if 'nodes' in available_tables:
    for n in data.get('nodes', []):
        cols, vals = [], []
        add(cols, vals, n_cols, 'id', str(n.get('id', 0)))
        add(cols, vals, n_cols, 'name', esc(n.get('name')))
        add(cols, vals, n_cols, 'address', esc(n.get('address'), 'address'))
        add(cols, vals, n_cols, 'port', str(n.get('port') or 0))
        add(cols, vals, n_cols, 'status', esc('connected'))
        add(cols, vals, n_cols, 'created_at', ts(n.get('created_at')))
        if 'uplink' in n_cols:
            add(cols, vals, n_cols, 'uplink', str(int(n.get('uplink') or 0)))
        if 'downlink' in n_cols:
            add(cols, vals, n_cols, 'downlink', str(int(n.get('downlink') or 0)))

        if cols:
            sql.append(f"INSERT INTO nodes ({','.join(cols)}) VALUES ({','.join(vals)});")

# -------------------------
# Hosts (schema-aware)
# -------------------------
if 'hosts' in available_tables:
    for h in data.get('hosts', []):
        cols, vals = [], []
        add(cols, vals, h_cols, 'id', str(h.get('id', 0)))
        add(cols, vals, h_cols, 'remark', esc(h.get('remark')))
        add(cols, vals, h_cols, 'address', esc(h.get('address'), 'address'))
        add(cols, vals, h_cols, 'port', str(h.get('port') or 0))
        add(cols, vals, h_cols, 'inbound_tag', esc(h.get('inbound_tag') or h.get('tag')))
        add(cols, vals, h_cols, 'sni', esc(h.get('sni'),'sni'))
        add(cols, vals, h_cols, 'host', esc(h.get('host'),'host'))
        add(cols, vals, h_cols, 'security', esc(h.get('security', 'none'), 'security'))
        add(cols, vals, h_cols, 'alpn', esc(h.get('alpn'),'alpn'))

        if cols:
            sql.append(f"INSERT INTO hosts ({','.join(cols)}) VALUES ({','.join(vals)});")

# -------------------------
# Users (schema-aware)
# -------------------------
if 'users' in available_tables:
    for u in data.get('users', []):
        ukey = u.get('key') or u.get('uuid') or u.get('subscription_key') or ''
        cols, vals = [], []
        add(cols, vals, u_cols, 'id', str(u.get('id', 0)))
        add(cols, vals, u_cols, 'username', esc(u.get('username')))
        add(cols, vals, u_cols, 'status', esc('active'))
        # traffic
        if 'used_traffic' in u_cols:
            add(cols, vals, u_cols, 'used_traffic', str(int(u.get('used_traffic') or 0)))
        elif 'traffic' in u_cols:
            add(cols, vals, u_cols, 'traffic', str(int(u.get('used_traffic') or u.get('traffic') or 0)))
        # relations
        add(cols, vals, u_cols, 'admin_id', "1")
        add(cols, vals, u_cols, 'service_id', "1")
        add(cols, vals, u_cols, 'created_at', ts(u.get('created_at')))
        # key/token/uuid column
        if k_col:
            # k_col is already backticked string like `key`
            raw = k_col.strip('`')
            if raw in u_cols:
                cols.append(k_col)
                vals.append(esc(ukey))
        if cols:
            sql.append(f"INSERT INTO users ({','.join(cols)}) VALUES ({','.join(vals)});")

# -------------------------
# RELATIONS & PROXIES REPAIR (schema-aware)
# -------------------------
# Proxies: need user_id + type/protocol + settings/config
if 'proxies' in available_tables and k_col:
    type_col = None
    for c in ['type', 'protocol']:
        if c in p_cols:
            type_col = bt(c); break
    settings_col = None
    for c in ['settings', 'config']:
        if c in p_cols:
            settings_col = bt(c); break

    if ('user_id' in p_cols) and type_col and settings_col:
        sql.append(
            f"INSERT IGNORE INTO proxies (`user_id`, {type_col}, {settings_col}) "
            f"SELECT id, 'vless', CONCAT('{{\"id\": \"', {k_col}, '\", \"flow\": \"\"}}') "
            f"FROM users WHERE {k_col} != '';"
        )

# user_inbounds: prefer inbound_tag else inbound_id
if 'user_inbounds' in available_tables:
    if ('user_id' in ui_cols) and ('inbound_tag' in ui_cols) and inb_tag_col:
        sql.append(
            f"INSERT IGNORE INTO user_inbounds (`user_id`, `inbound_tag`) "
            f"SELECT u.id, i.{bt(inb_tag_col)} FROM users u CROSS JOIN inbounds i;"
        )
    elif ('user_id' in ui_cols) and ('inbound_id' in ui_cols):
        sql.append(
            "INSERT IGNORE INTO user_inbounds (`user_id`, `inbound_id`) "
            "SELECT u.id, i.id FROM users u CROSS JOIN inbounds i;"
        )

# service_inbounds
if 'service_inbounds' in available_tables:
    if ('service_id' in si_cols) and ('inbound_id' in si_cols):
        sql.append("INSERT IGNORE INTO service_inbounds (`service_id`, `inbound_id`) SELECT 1, id FROM inbounds;")

# service_hosts
if 'service_hosts' in available_tables:
    if ('service_id' in sh_cols) and ('host_id' in sh_cols):
        sql.append("INSERT IGNORE INTO service_hosts (`service_id`, `host_id`) SELECT 1, id FROM hosts;")

sql.append("SET FOREIGN_KEY_CHECKS=1;")
with open(sql_f, 'w') as f:
    f.write('\n'.join(sql))
PYIMPORT

    local py_rc=$?
    if [ $py_rc -ne 0 ]; then
        merr "Python import generator failed"
        rm -f "$sql_file" \
            "/tmp/mrm_jsonfile_$$" "/tmp/mrm_sqlfile_$$" "/tmp/mrm_tables_$$" \
            "/tmp/mrm_adminscols_$$" "/tmp/mrm_inboundscols_$$" "/tmp/mrm_servicescols_$$" \
            "/tmp/mrm_proxiescols_$$" "/tmp/mrm_nodescols_$$" "/tmp/mrm_hostscols_$$" "/tmp/mrm_userscols_$$" \
            "/tmp/mrm_userinboundscols_$$" "/tmp/mrm_serviceinboundscols_$$" "/tmp/mrm_servicehostscols_$$"
        return 1
    fi

    if [ ! -s "$sql_file" ]; then
        merr "Generated SQL file is empty"
        rm -f "$sql_file" \
            "/tmp/mrm_jsonfile_$$" "/tmp/mrm_sqlfile_$$" "/tmp/mrm_tables_$$" \
            "/tmp/mrm_adminscols_$$" "/tmp/mrm_inboundscols_$$" "/tmp/mrm_servicescols_$$" \
            "/tmp/mrm_proxiescols_$$" "/tmp/mrm_nodescols_$$" "/tmp/mrm_hostscols_$$" "/tmp/mrm_userscols_$$" \
            "/tmp/mrm_userinboundscols_$$" "/tmp/mrm_serviceinboundscols_$$" "/tmp/mrm_servicehostscols_$$"
        return 1
    fi

    minfo "Importing into MySQL..."
    local out rc
    out=$(run_mysql_file "$sql_file" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        merr "MySQL import failed (see below):"
        echo "$out" | head -120
        mlog "MYSQL IMPORT ERROR: $(echo "$out" | tr '\n' ' ' | cut -c1-2000)"
        rm -f "$sql_file" \
            "/tmp/mrm_jsonfile_$$" "/tmp/mrm_sqlfile_$$" "/tmp/mrm_tables_$$" \
            "/tmp/mrm_adminscols_$$" "/tmp/mrm_inboundscols_$$" "/tmp/mrm_servicescols_$$" \
            "/tmp/mrm_proxiescols_$$" "/tmp/mrm_nodescols_$$" "/tmp/mrm_hostscols_$$" "/tmp/mrm_userscols_$$" \
            "/tmp/mrm_userinboundscols_$$" "/tmp/mrm_serviceinboundscols_$$" "/tmp/mrm_servicehostscols_$$"
        return 1
    fi

    rm -f "$sql_file" \
        "/tmp/mrm_jsonfile_$$" "/tmp/mrm_sqlfile_$$" "/tmp/mrm_tables_$$" \
        "/tmp/mrm_adminscols_$$" "/tmp/mrm_inboundscols_$$" "/tmp/mrm_servicescols_$$" \
        "/tmp/mrm_proxiescols_$$" "/tmp/mrm_nodescols_$$" "/tmp/mrm_hostscols_$$" "/tmp/mrm_userscols_$$" \
        "/tmp/mrm_userinboundscols_$$" "/tmp/mrm_serviceinboundscols_$$" "/tmp/mrm_servicehostscols_$$"

    mok "MySQL import done"
}
#==============================================================================
# VERIFICATION
#==============================================================================

verify_migration() {
    ui_header "VERIFICATION"
    local admins users ukeys proxies hosts nodes svcs
    local key_col
    key_col=$(run_mysql_query "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='rebecca' AND TABLE_NAME='users' AND COLUMN_NAME IN ('key', 'token') LIMIT 1;" 2>/dev/null | tr -d ' \n\r')
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
    printf "  %-22s ${GREEN}%s${NC} ← subscriptions (col: $key_col)\n" "Users with Key:" "${ukeys:-0}"
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
    MYSQL_CONTAINER=$(find_mysql_container); local sdata=$(get_data_dir "$SRC"); local export_file="/tmp/mrm_sqlite_$$.json"
    local sqlite_db="$sdata/db.sqlite3"
    wait_mysql || return 1
    wait_rebecca_tables || return 1
    export_sqlite "$sqlite_db" "$export_file" || return 1
    setup_jwt || return 1
    import_to_mysql "$export_file" || return 1
    verify_migration
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

migrate_pg_to_mysql() {
    PG_CONTAINER=$(find_pg_container "$SRC")
    MYSQL_CONTAINER=$(find_mysql_container)

    [ -z "$PG_CONTAINER" ] && { merr "PostgreSQL container not found"; return 1; }

    # Fix mode doesn't call start_source_panel; ensure these are set.
    if [ -z "$PG_DB_USER" ] || [ -z "$PG_DB_NAME" ]; then
        parse_pg_connection "$SRC" || true
    fi
    [ -z "$PG_DB_USER" ] && PG_DB_USER="${SOURCE_PANEL_TYPE:-postgres}"
    [ -z "$PG_DB_NAME" ] && PG_DB_NAME="${SOURCE_PANEL_TYPE:-postgres}"
    minfo "  DB User: $PG_DB_USER, DB Name: $PG_DB_NAME"

    local waited=0
    while ! docker exec "$PG_CONTAINER" pg_isready -U "$PG_DB_USER" -d "$PG_DB_NAME" &>/dev/null && [ $waited -lt 60 ]; do
        sleep 2
        waited=$((waited + 2))
    done

    wait_mysql || return 1
    wait_rebecca_tables || return 1

    local export_file="/tmp/mrm_export_$$.json"
    export_postgresql "$export_file" || return 1
    setup_jwt || return 1
    import_to_mysql "$export_file" || return 1
    verify_migration
}

#==============================================================================
# ORCHESTRATION
#==============================================================================

stop_old() {
    docker ps --format '{{.Names}}' | grep -iE "pasarguard|marzban" | grep -v rebecca | xargs -I {} docker stop {} 2>/dev/null
}

do_full() {
    migration_init; clear; ui_header "MRM MIGRATION V12.11"
    SRC=$(detect_source_panel) || true
    if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
        merr "Source panel not found in /opt/pasarguard or /opt/marzban"
        mpause
        return 1
    fi
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")
    [ -d "/opt/rebecca" ] && TGT="/opt/rebecca" || { install_rebecca; return 1; }
    ui_confirm "Start?" "y" || return 0
    safe_writeln "$SRC" > "$BACKUP_ROOT/.last_source"
    start_source_panel "$SRC" && (cd "$TGT" && docker compose down) &>/dev/null
    copy_data "$(get_data_dir "$SRC")" "/var/lib/rebecca" && install_xray "/var/lib/rebecca" "$(get_data_dir "$SRC")" && generate_env "$SRC" "$TGT"
    (cd "$TGT" && docker compose up -d --force-recreate) &>/dev/null
    minfo "Initializing Rebecca (60s)..."; sleep 60
    [ "$SOURCE_DB_TYPE" = "postgresql" ] && migrate_pg_to_mysql || migrate_sqlite_to_mysql
    (cd "$TGT" && docker compose restart) &>/dev/null; sleep 10; stop_old
    ui_header "COMPLETE"
    echo -e "  ${GREEN}✓ Ready! Login with $SOURCE_PANEL_TYPE credentials${NC}"
    migration_cleanup; mpause
}

do_fix() {
    clear; ui_header "FIX"
    TGT="/opt/rebecca"
    SRC=$(detect_source_panel) || true
    if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
        merr "Source panel not found in /opt/pasarguard or /opt/marzban"
        mpause
        return 1
    fi
    SOURCE_DB_TYPE=$(detect_db_type "$SRC")

    # Ensure source stack is running and PG_DB_* is set
    start_source_panel "$SRC" || { mpause; return 1; }

    # Ensure rebecca is up
    if [ -d "$TGT" ]; then
        (cd "$TGT" && docker compose up -d) &>/dev/null
        minfo "Initializing Rebecca (30s)..."; sleep 30
    fi

    migrate_pg_to_mysql
    mpause
}

do_rollback() {
    clear; ui_header "ROLLBACK"
    sp=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    (cd /opt/rebecca && docker compose down)
    (cd "$sp" && docker compose up -d)
    mpause
}

do_status() {
    clear; ui_header "STATUS"
    MYSQL_CONTAINER=$(find_mysql_container)
    load_mysql_pass
    run_mysql_query "SELECT 'Users', COUNT(*) FROM users UNION SELECT 'Proxies', COUNT(*) FROM proxies;"
    mpause
}

do_logs() { clear; ui_header "LOGS"; [ -f "$MIGRATION_LOG" ] && tail -50 "$MIGRATION_LOG"; mpause; }

migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION V12.11"
        echo -e "  1) Full Migration\n  2) Fix Current\n  3) Rollback\n  4) Status\n  5) Logs\n  0) Back\n"
        read -p "Select: " opt
        case "$opt" in 1) do_full ;; 2) do_fix ;; 3) do_rollback ;; 4) do_status ;; 5) do_logs ;; 0) migration_cleanup; exit 0 ;; esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }
    migrator_menu
fi
