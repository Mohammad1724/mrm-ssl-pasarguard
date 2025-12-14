#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 6.1 (Final, host pg_dump for Timescale/PostgreSQL)
#
# Pasarguard:
#   - Install dir : /opt/pasarguard
#   - Data dir    : /var/lib/pasarguard
#   - DB URL      : SQLALCHEMY_DATABASE_URL (async drivers)
#
# Rebecca:
#   - Install dir : /opt/rebecca
#   - Data dir    : /var/lib/rebecca
#   - DB:         : MySQL/MariaDB (required for migration)
#==============================================================================

# فقط وقتی مستقیم اجرا می‌شود، pipefail فعال شود
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -o pipefail
fi

#==============================================================================
# مسیرها و تنظیمات
#==============================================================================

PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"

REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"

REBECCA_INSTALL_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
LOG_FILE="${LOG_FILE:-/var/log/mrm_migration.log}"

TEMP_DIR=""   # در init_migration ست می‌شود

CONTAINER_TIMEOUT=120
MYSQL_WAIT=60

# رنگ‌ها
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

#==============================================================================
# توابع کمکی
#==============================================================================

create_temp_dir() {
    TEMP_DIR=$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null)
    if [ ! -d "$TEMP_DIR" ]; then
        TEMP_DIR="/tmp/mrm-migration-$$-$(date +%s)"
        mkdir -p "$TEMP_DIR"
    fi
}

cleanup_temp() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && [[ "$TEMP_DIR" == /tmp/* ]]; then
        rm -rf "$TEMP_DIR" 2>/dev/null
    fi
}

init_migration() {
    create_temp_dir
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/mrm_migration.log"
    mkdir -p "$BACKUP_ROOT" 2>/dev/null
    {
        echo ""
        echo "=== Migration: $(date) ==="
        echo "Temp dir: $TEMP_DIR"
    } >> "$LOG_FILE"
}

log()   { echo "[$(date +'%F %T')] $*" >> "$LOG_FILE"; }
info()  { echo -e "${BLUE}→${NC} $*"; log "INFO: $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; log "OK: $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; log "WARN: $*"; }
err()   { echo -e "${RED}✗${NC} $*"; log "ERROR: $*"; }

safe_pause() {
    echo ""
    echo -e "${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s -r
    echo ""
}

#==============================================================================
# وابستگی‌ها
#==============================================================================

check_dependencies() {
    info "Checking dependencies..."
    local missing=()

    for cmd in docker curl tar gzip python3 sqlite3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing: ${missing[*]}"
        echo "Install: apt update && apt install -y ${missing[*]}"
        return 1
    fi

    if ! docker info &>/dev/null; then
        err "Docker is not running"
        return 1
    fi

    ok "Dependencies OK"
    return 0
}

#==============================================================================
# تشخیص نوع دیتابیس و استخراج اطلاعات اتصال
#==============================================================================

detect_db_type() {
    local panel_dir="$1" data_dir="$2"
    [ ! -d "$panel_dir" ] && { echo "not_found"; return 1; }

    local env_file="$panel_dir/.env"
    if [ -f "$env_file" ]; then
        local db_url
        db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null \
                 | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')

        case "$db_url" in
            *timescale*|*postgresql+asyncpg*) echo "timescaledb"; return 0 ;;
            *postgresql*)                     echo "postgresql"; return 0 ;;
            *mysql+asyncmy*|*mysql*)          echo "mysql";      return 0 ;;
            *mariadb*)                        echo "mariadb";    return 0 ;;
            *sqlite+aiosqlite*|*sqlite*)      echo "sqlite";     return 0 ;;
        esac
    fi

    [ -f "$data_dir/db.sqlite3" ] && { echo "sqlite"; return 0; }

    echo "unknown"
    return 1
}

# خروجی: DB_USER, DB_PASS, DB_HOST, DB_PORT, DB_NAME
get_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"

    DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT=""; DB_NAME=""

    [ ! -f "$env_file" ] && return 1

    local db_url
    db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null \
             | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d ' ')

    # پارس URL با Python + urllib.parse
    eval "$(python3 << PYEOF
import re
from urllib.parse import urlparse, unquote

url = "$db_url"
# تبدیل به فرم قابل پارس
if '://' in url:
    scheme, rest = url.split('://', 1)
    # حذف +asyncpg, +asyncmy و ...
    if '+' in scheme:
        scheme = scheme.split('+', 1)[0]
    url = scheme + '://' + rest
else:
    print('DB_USER=""'); print('DB_PASS=""'); print('DB_HOST="localhost"'); print('DB_PORT=""'); print('DB_NAME="pasarguard"'); exit(0)

p = urlparse(url)

user = p.username or ''
password = unquote(p.password or '')
host = p.hostname or 'localhost'
port = str(p.port or '')
dbname = (p.path or '').lstrip('/') or 'pasarguard'

print(f'DB_USER="{user}"')
print(f'DB_PASS="{password}"')
print(f'DB_HOST="{host}"')
print(f'DB_PORT="{port}"')
print(f'DB_NAME="{dbname}"')
PYEOF
)"
    export DB_USER DB_PASS DB_HOST DB_PORT DB_NAME
    return 0
}

#==============================================================================
# مدیریت کانتینر
#==============================================================================

find_db_container() {
    local project_dir="$1" db_type="$2"
    [ ! -d "$project_dir" ] && return 1

    local containers
    containers=$(cd "$project_dir" && docker compose ps -q 2>/dev/null)
    [ -z "$containers" ] && return 1

    local cid
    for cid in $containers; do
        case "$db_type" in
            mysql|mariadb)
                docker exec "$cid" mysql --version &>/dev/null && { echo "$cid"; return 0; } ;;
            postgresql|timescaledb)
                docker exec "$cid" psql --version &>/dev/null && { echo "$cid"; return 0; } ;;
        esac
    done

    return 1
}

is_running() {
    local dir="$1"
    [ -d "$dir" ] && (cd "$dir" && docker compose ps 2>/dev/null | grep -qE "Up|running")
}

start_panel() {
    local dir="$1" name="$2"
    info "Starting $name..."

    [ ! -d "$dir" ] && { err "$dir not found"; return 1; }

    (cd "$dir" && docker compose up -d 2>&1) | tee -a "$LOG_FILE"

    local i=0
    while [ $i -lt $CONTAINER_TIMEOUT ]; do
        if is_running "$dir"; then
            ok "$name started"
            sleep 5
            return 0
        fi
        sleep 3; i=$((i+3))
        echo -ne "  Waiting... ${i}s\r"
    done
    echo ""
    err "$name failed to start"
    return 1
}

stop_panel() {
    local dir="$1" name="$2"
    [ ! -d "$dir" ] && return 0

    info "Stopping $name..."
    (cd "$dir" && docker compose down 2>&null) | tee -a "$LOG_FILE"
    sleep 3
    ok "$name stopped"
}

#==============================================================================
# بکاپ
#==============================================================================

create_backup() {
    info "Creating backup..."

    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$backup_dir"

    echo "$backup_dir" > "$BACKUP_ROOT/.last_backup"

    # Config
    if [ -d "$PASARGUARD_DIR" ]; then
        info "  Config..."
        tar --exclude='*/node_modules' -C "$(dirname "$PASARGUARD_DIR")" \
            -czf "$backup_dir/pasarguard_config.tar.gz" "$(basename "$PASARGUARD_DIR")" 2>/dev/null
        ok "  Config saved"
    fi

    # Data
    if [ -d "$PASARGUARD_DATA" ]; then
        info "  Data (may take time)..."
        tar -C "$(dirname "$PASARGUARD_DATA")" \
            -czf "$backup_dir/pasarguard_data.tar.gz" "$(basename "$PASARGUARD_DATA")" 2>/dev/null
        ok "  Data saved"
    fi

    # DB
    local db_type
    db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$backup_dir/db_type.txt"
    info "  Database ($db_type)..."
    export_database "$db_type" "$backup_dir"

    # Metadata
    cat > "$backup_dir/info.txt" <<EOF
Date: $(date)
Host: $(hostname)
Panel: Pasarguard
Config: $PASARGUARD_DIR
Data: $PASARGUARD_DATA
Database: $db_type
EOF

    ok "Backup: $backup_dir"
    echo "$backup_dir"
}

export_database() {
    local db_type="$1" backup_dir="$2"

    is_running "$PASARGUARD_DIR" || { start_panel "$PASARGUARD_DIR" "Pasarguard" || return 1; sleep 10; }

    case "$db_type" in
        sqlite)
            if [ -f "$PASARGUARD_DATA/db.sqlite3" ]; then
                # integrity check
                if sqlite3 "$PASARGUARD_DATA/db.sqlite3" "PRAGMA integrity_check;" 2>/dev/null \
                    | grep -q "ok"; then
                    cp "$PASARGUARD_DATA/db.sqlite3" "$backup_dir/database.sqlite3"
                    ok "  SQLite exported"
                else
                    warn "  SQLite integrity check failed, copying anyway..."
                    cp "$PASARGUARD_DATA/db.sqlite3" "$backup_dir/database.sqlite3"
                fi
            else
                warn "  SQLite file not found"
            fi
            ;;
        timescaledb|postgresql)
            export_postgresql_host "$backup_dir/database.sql" "$db_type"
            ;;
        mysql|mariadb)
            export_mysql_host "$backup_dir/database.sql"
            ;;
        *)
            warn "  Unknown db type, only config+data saved"
            ;;
    esac
}

#==============================================================================
# Export PostgreSQL/Timescale با pg_dump روی خود سرور
#==============================================================================

export_postgresql_host() {
    local output_file="$1" db_type="$2"

    info "  Exporting $db_type via host pg_dump..."

    # نصب pg_dump در صورت نبودن
    if ! command -v pg_dump &>/dev/null; then
        info "  Installing postgresql-client (pg_dump)..."
        apt-get update -qq && apt-get install -y postgresql-client -qq
    fi

    # گرفتن credential از .env
    get_db_credentials "$PASARGUARD_DIR"

    local host="${DB_HOST:-127.0.0.1}"
    local port_opt=""
    [ -n "$DB_PORT" ] && port_opt="-p $DB_PORT"
    local user="${DB_USER:-pasarguard}"
    local db="${DB_NAME:-pasarguard}"
    local pass="$DB_PASS"

    local err_log="$TEMP_DIR/pg_dump_error.log"

    info "    host=$host user=$user db=$db port=${DB_PORT:-default}"

    if [ -n "$pass" ]; then
        PGPASSWORD="$pass" pg_dump -h "$host" $port_opt -U "$user" -d "$db" \
            --no-owner --no-acl > "$output_file" 2> "$err_log"
    else
        pg_dump -h "$host" $port_opt -U "$user" -d "$db" \
            --no-owner --no-acl > "$output_file" 2> "$err_log"
    fi

    if [ -s "$output_file" ]; then
        ok "  $db_type exported"
        return 0
    fi

    err "  pg_dump failed"
    echo "  --- pg_dump last lines ---" >> "$LOG_FILE"
    [ -f "$err_log" ] && tail -n 10 "$err_log" >> "$LOG_FILE"
    echo "  --------------------------" >> "$LOG_FILE"
    return 1
}

#==============================================================================
# Export MySQL/MariaDB روی خود سرور (در صورت نیاز)
#==============================================================================

export_mysql_host() {
    local output_file="$1"

    info "  Exporting MySQL/MariaDB via mysqldump (host)..."

    # نصب mysql-client در صورت نبودن (اختیاری)
    if ! command -v mysqldump &>/dev/null; then
        info "  Installing default-mysql-client..."
        apt-get update -qq && apt-get install -y default-mysql-client -qq
    fi

    get_db_credentials "$PASARGUARD_DIR"

    local host="${DB_HOST:-127.0.0.1}"
    local port_opt=""
    [ -n "$DB_PORT" ] && port_opt="--port=$DB_PORT"
    local user="${DB_USER:-root}"
    local db="${DB_NAME:-pasarguard}"
    local pass="$DB_PASS"
    local err_log="$TEMP_DIR/mysqldump_error.log"

    info "    host=$host user=$user db=$db port=${DB_PORT:-default}"

    if [ -n "$pass" ]; then
        mysqldump -h "$host" $port_opt -u"$user" -p"$pass" "$db" \
            > "$output_file" 2> "$err_log"
    else
        mysqldump -h "$host" $port_opt -u"$user" "$db" \
            > "$output_file" 2> "$err_log"
    fi

    if [ -s "$output_file" ]; then
        ok "  MySQL/MariaDB exported"
        return 0
    fi

    err "  mysqldump failed"
    echo "  --- mysqldump last lines ---" >> "$LOG_FILE"
    [ -f "$err_log" ] && tail -n 10 "$err_log" >> "$LOG_FILE"
    echo "  ----------------------------" >> "$LOG_FILE"
    return 1
}

#==============================================================================
# تبدیل دیتابیس به MySQL
#==============================================================================

convert_to_mysql() {
    local src="$1" dst="$2" type="$3"

    case "$type" in
        sqlite)      convert_sqlite_to_mysql "$src" "$dst" ;;
        postgresql|timescaledb) convert_postgresql_to_mysql "$src" "$dst" ;;
        mysql|mariadb)
            cp "$src" "$dst"
            ok "No conversion required (already MySQL/MariaDB)"
            ;;
        *)
            err "Unknown db type: $type"
            return 1
            ;;
    esac
}

convert_sqlite_to_mysql() {
    local sqlite_file="$1" output_file="$2"

    info "Converting SQLite → MySQL..."

    [ ! -f "$sqlite_file" ] && { err "SQLite file not found"; return 1; }

    local dump="$TEMP_DIR/sqlite_dump.sql"
    sqlite3 "$sqlite_file" .dump > "$dump" 2>/dev/null

    [ ! -s "$dump" ] && { err "SQLite dump failed or empty"; return 1; }

    python3 << PYEOF
import re

with open("$dump", 'r', encoding='utf-8', errors='replace') as f:
    c = f.read()

c = re.sub(r'BEGIN TRANSACTION;', 'START TRANSACTION;', c)
c = re.sub(r'PRAGMA.*?;\n?', '', c)
c = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
c = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
c = re.sub(r'\bINTEGER\b', 'INT', c, flags=re.I)
c = re.sub(r'\bREAL\b', 'DOUBLE', c, flags=re.I)
c = re.sub(r'\bBLOB\b', 'LONGBLOB', c, flags=re.I)
c = re.sub(r'\bAUTOINCREMENT\b', 'AUTO_INCREMENT', c, flags=re.I)
c = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'`\1`', c)

def fix_bool(m):
    s = m.group(0)
    s = s.replace("'t'", "'1'").replace("'f'", "'0'")
    s = s.replace("'T'", "'1'").replace("'F'", "'0'")
    return s

c = re.sub(r'INSERT INTO.*?;', fix_bool, c, flags=re.I | re.S)

header = """-- SQLite to MySQL
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""
footer = "\n\nSET FOREIGN_KEY_CHECKS=1;\n"

with open("$output_file", 'w', encoding='utf-8') as f:
    f.write(header + c + footer)

print("OK")
PYEOF

    [ $? -eq 0 ] && [ -s "$output_file" ] && { ok "SQLite → MySQL conversion done"; return 0; }
    err "SQLite conversion failed"
    return 1
}

convert_postgresql_to_mysql() {
    local pg_file="$1" output_file="$2"

    info "Converting PostgreSQL/TimescaleDB → MySQL..."

    [ ! -f "$pg_file" ] && { err "PostgreSQL dump not found"; return 1; }

    python3 << PYEOF
import re

with open("$pg_file", 'r', encoding='utf-8', errors='replace') as f:
    c = f.read()

remove_patterns = [
    r'^SET\s+\w+.*?;$',
    r'^SELECT\s+pg_catalog\..*?;$',
    r'^\\\\connect.*$',
    r'^CREATE\s+EXTENSION.*?;$',
    r'^COMMENT\s+ON.*?;$',
    r'^ALTER\s+TABLE.*?OWNER\s+TO.*?;$',
    r'^GRANT\s+.*?;$',
    r'^REVOKE\s+.*?;$',
    r'^CREATE\s+SCHEMA.*?;$',
    r'^CREATE\s+SEQUENCE.*?;$',
    r'^ALTER\s+SEQUENCE.*?;$',
    r'^SELECT\s+.*?setval.*?;$',
    r'^SELECT\s+create_hypertable.*?;$',
    r'^SELECT\s+set_chunk.*?;$',
]

for p in remove_patterns:
    c = re.sub(p, '', c, flags=re.M|re.I)

type_conv = [
    (r'\bSERIAL\b', 'INT AUTO_INCREMENT'),
    (r'\bBIGSERIAL\b', 'BIGINT AUTO_INCREMENT'),
    (r'\bSMALLSERIAL\b', 'SMALLINT AUTO_INCREMENT'),
    (r'\bBOOLEAN\b', 'TINYINT(1)'),
    (r'\bTIMESTAMP\s+WITH\s+TIME\s+ZONE\b', 'DATETIME'),
    (r'\bTIMESTAMP\s+WITHOUT\s+TIME\s+ZONE\b', 'DATETIME'),
    (r'\bTIMESTAMPTZ\b', 'DATETIME'),
    (r'\bBYTEA\b', 'LONGBLOB'),
    (r'\bUUID\b', 'VARCHAR(36)'),
    (r'\bJSONB?\b', 'JSON'),
    (r'\bINET\b', 'VARCHAR(45)'),
    (r'\bDOUBLE\s+PRECISION\b', 'DOUBLE'),
]

for p, r in type_conv:
    c = re.sub(p, r, c, flags=re.I)

c = re.sub(r"'t'::boolean", "'1'", c, flags=re.I)
c = re.sub(r"'f'::boolean", "'0'", c, flags=re.I)
c = re.sub(r'\btrue\b', "'1'", c, flags=re.I)
c = re.sub(r'\bfalse\b', "'0'", c, flags=re.I)

c = re.sub(r'::\w+(\[\])?', '', c)
c = re.sub(r"nextval\('[^']*'[^)]*\)", 'NULL', c, flags=re.I)
c = re.sub(r'\bCURRENT_TIMESTAMP\b', 'NOW()', c, flags=re.I)
c = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'`\1`', c)
c = re.sub(r'\n\s*\n\s*\n+', '\n\n', c)

header = """-- PostgreSQL/TimescaleDB to MySQL
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""
footer = "\n\nSET FOREIGN_KEY_CHECKS=1;\n"

with open("$output_file", 'w', encoding='utf-8') as f:
    f.write(header + c + footer)

print("OK")
PYEOF

    [ $? -eq 0 ] && [ -s "$output_file" ] && { ok "PostgreSQL/Timescale → MySQL conversion done"; return 0; }
    err "PostgreSQL conversion failed"
    return 1
}

#==============================================================================
# Rebecca check & نصب
#==============================================================================

check_rebecca_installed() {
    [ -d "$REBECCA_DIR" ] && [ -f "$REBECCA_DIR/.env" ]
}

check_rebecca_mysql() {
    [ -f "$REBECCA_DIR/.env" ] && grep -qiE "mysql|mariadb" "$REBECCA_DIR/.env"
}

install_rebecca() {
    echo ""
    echo -e "${YELLOW}Rebecca is not installed.${NC}"
    echo ""
    echo "Install with MySQL:"
    echo -e "  ${CYAN}sudo bash -c \"\$(curl -sL $REBECCA_INSTALL_URL)\" @ install --database mysql${NC}"
    echo ""
    read -p "Run installer now? (y/n): " a
    [ "$a" != "y" ] && return 1

    info "Installing Rebecca..."
    curl -sL "$REBECCA_INSTALL_URL" -o /tmp/rebecca.sh
    bash /tmp/rebecca.sh install --database mysql
    rm -f /tmp/rebecca.sh

    check_rebecca_installed && { ok "Rebecca installed"; return 0; }
    err "Rebecca installation failed"
    return 1
}

#==============================================================================
# Import to Rebecca MySQL
#==============================================================================

wait_for_mysql() {
    local timeout="$1"
    info "Waiting for MySQL in Rebecca..."

    local i=0
    while [ $i -lt $timeout ]; do
        local cid
        cid=$(find_db_container "$REBECCA_DIR" "mysql")
        if [ -n "$cid" ]; then
            local pass
            pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null \
                   | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
            docker exec "$cid" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null \
                && { ok "MySQL is ready"; return 0; }
        fi
        sleep 3; i=$((i+3))
        echo -ne "  ${i}s...\r"
    done
    echo ""
    warn "MySQL may not be fully ready"
    return 1
}

import_to_rebecca() {
    local sql_file="$1"

    info "Importing data into Rebecca..."

    [ ! -f "$sql_file" ] && { err "SQL file not found: $sql_file"; return 1; }

    local db pass
    db=$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null \
         | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null \
           | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    db="${db:-marzban}"

    local cid
    cid=$(find_db_container "$REBECCA_DIR" "mysql")
    [ -z "$cid" ] && { err "Rebecca MySQL container not found"; return 1; }

    info "  Database: $db"

    docker cp "$sql_file" "$cid:/tmp/import.sql" 2>/dev/null

    if docker exec "$cid" mysql -uroot -p"$pass" "$db" \
        -e "source /tmp/import.sql" 2>/dev/null; then
        docker exec "$cid" rm -f /tmp/import.sql 2>/dev/null
        ok "Import successful"
        return 0
    fi

    warn "Standard import failed, trying alternative..."
    if docker exec -i "$cid" mysql -uroot -p"$pass" "$db" < "$sql_file" 2>/dev/null; then
        ok "Import successful (alternative)"
        return 0
    fi

    err "Import failed"
    return 1
}

#==============================================================================
# Config Migration
#==============================================================================

migrate_configs() {
    info "Migrating configuration and certs..."

    [ ! -f "$PASARGUARD_DIR/.env" ] || [ ! -f "$REBECCA_DIR/.env" ] && {
        warn "Config files not found, skipping config migration"
        return 0
    }

    local vars=(
        "SUDO_USERNAME"
        "SUDO_PASSWORD"
        "UVICORN_HOST"
        "UVICORN_PORT"
        "UVICORN_SSL_CERTFILE"
        "UVICORN_SSL_KEYFILE"
        "JWT_ACCESS_TOKEN_EXPIRE_MINUTES"
        "TELEGRAM_API_TOKEN"
        "TELEGRAM_ADMIN_ID"
        "TELEGRAM_PROXY_URL"
        "WEBHOOK_ADDRESS"
        "WEBHOOK_SECRET"
        "XRAY_JSON"
        "XRAY_EXECUTABLE_PATH"
        "XRAY_ASSETS_PATH"
        "XRAY_SUBSCRIPTION_URL_PREFIX"
        "XRAY_SUBSCRIPTION_TEMPLATE"
        "XRAY_FALLBACKS_INBOUND_TAG"
        "XRAY_EXCLUDE_INBOUND_TAGS"
        "CUSTOM_TEMPLATES_DIRECTORY"
        "SUBSCRIPTION_PAGE_TEMPLATE"
        "HOME_PAGE_TEMPLATE"
        "CLASH_SUBSCRIPTION_TEMPLATE"
        "DOCS"
        "DEBUG"
    )

    local count=0
    for v in "${vars[@]}"; do
        local val
        val=$(grep "^${v}=" "$PASARGUARD_DIR/.env" 2>/dev/null | sed 's/[^=]*=//')
        if [ -n "$val" ]; then
            sed -i "/^${v}=/d" "$REBECCA_DIR/.env" 2>/dev/null
            echo "${v}=${val}" >> "$REBECCA_DIR/.env"
            count=$((count+1))
        fi
    done

    ok "Migrated $count config variables"

    # Certificates
    if [ -d "$PASARGUARD_DATA/certs" ]; then
        info "  Copying certificates..."
        mkdir -p "$REBECCA_DATA/certs"
        cp -r "$PASARGUARD_DATA/certs/"* "$REBECCA_DATA/certs/" 2>/dev/null
        ok "  Certificates copied"
    fi

    # Xray config
    if [ -f "$PASARGUARD_DATA/xray_config.json" ]; then
        info "  Copying xray_config.json..."
        mkdir -p "$REBECCA_DATA"
        cp "$PASARGUARD_DATA/xray_config.json" "$REBECCA_DATA/" 2>/dev/null
        ok "  Xray config copied"
    fi

    # Templates
    if [ -d "$PASARGUARD_DATA/templates" ]; then
        info "  Copying templates..."
        mkdir -p "$REBECCA_DATA/templates"
        cp -r "$PASARGUARD_DATA/templates/"* "$REBECCA_DATA/templates/" 2>/dev/null
        ok "  Templates copied"
    fi
}

#==============================================================================
# Rollback
#==============================================================================

do_rollback() {
    clear
    echo -e "${CYAN}========== ROLLBACK TO PASARGUARD ==========${NC}"
    echo ""

    [ ! -f "$BACKUP_ROOT/.last_backup" ] && {
        err "No backup info found"
        ls -lh "$BACKUP_ROOT" 2>/dev/null || echo "(empty)"
        safe_pause
        return 1
    }

    local backup
    backup=$(cat "$BACKUP_ROOT/.last_backup")

    [ ! -d "$backup" ] && { err "Backup not found: $backup"; safe_pause; return 1; }

    echo -e "Using backup: ${GREEN}$backup${NC}"
    [ -f "$backup/info.txt" ] && cat "$backup/info.txt"
    echo ""

    echo -e "${RED}This will stop Rebecca and restore Pasarguard from backup.${NC}"
    read -p "Type 'rollback' to confirm: " ans
    [ "$ans" != "rollback" ] && { info "Cancelled"; safe_pause; return 0; }

    init_migration

    # Stop Rebecca
    is_running "$REBECCA_DIR" && stop_panel "$REBECCA_DIR" "Rebecca"

    # Restore config
    if [ -f "$backup/pasarguard_config.tar.gz" ] || [ -f "$backup/config.tar.gz" ]; then
        local cfg="$backup/pasarguard_config.tar.gz"
        [ ! -f "$cfg" ] && cfg="$backup/config.tar.gz"
        info "Restoring config..."
        rm -rf "$PASARGUARD_DIR"
        mkdir -p "$(dirname "$PASARGUARD_DIR")"
        tar -xzf "$cfg" -C "$(dirname "$PASARGUARD_DIR")" 2>/dev/null
        ok "Config restored"
    else
        err "Config archive not found in backup"
    fi

    # Restore data
    if [ -f "$backup/pasarguard_data.tar.gz" ] || [ -f "$backup/data.tar.gz" ]; then
        local dat="$backup/pasarguard_data.tar.gz"
        [ ! -f "$dat" ] && dat="$backup/data.tar.gz"
        info "Restoring data..."
        rm -rf "$PASARGUARD_DATA"
        mkdir -p "$(dirname "$PASARGUARD_DATA")"
        tar -xzf "$dat" -C "$(dirname "$PASARGUARD_DATA")" 2>/dev/null
        ok "Data restored"
    fi

    info "Starting Pasarguard..."
    if start_panel("$PASARGUARD_DIR" "Pasarguard"); then
        echo -e "${GREEN}Rollback complete.${NC}"
    else
        err "Failed to start Pasarguard; try manually: cd $PASARGUARD_DIR && docker compose up -d"
    fi

    cleanup_temp
    safe_pause
}

#==============================================================================
# Migration Flow
#==============================================================================

do_migration() {
    init_migration

    clear
    echo -e "${CYAN}====== PASARGUARD → REBECCA MIGRATION ======${NC}"
    echo ""

    check_dependencies || { safe_pause; cleanup_temp; return 1; }

    [ ! -d "$PASARGUARD_DIR" ] && {
        err "Pasarguard not found at $PASARGUARD_DIR"
        safe_pause; cleanup_temp; return 1;
    }
    ok "Pasarguard found: $PASARGUARD_DIR"

    local db_type
    db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database type: ${CYAN}$db_type${NC}"
    [ "$db_type" = "unknown" ] && { err "Unknown DB type"; safe_pause; cleanup_temp; return 1; }

    if ! check_rebecca_installed; then
        install_rebecca || { safe_pause; cleanup_temp; return 1; }
    else
        ok "Rebecca found: $REBECCA_DIR"
    fi

    if ! check_rebecca_mysql; then
        err "Rebecca is not configured with MySQL. Reinstall with --database mysql"
        safe_pause; cleanup_temp; return 1;
    fi
    ok "Rebecca MySQL verified"

    echo ""
    echo -e "${BOLD}Summary:${NC}"
    echo -e "  Source Panel : ${CYAN}Pasarguard${NC}"
    echo -e "  Database     : ${CYAN}$db_type${NC}"
    echo -e "  Target Panel : ${CYAN}Rebecca (MySQL)${NC}"
    echo ""
    echo -e "${RED}⚠ This will stop Pasarguard and migrate all data to Rebecca.${NC}"
    echo ""
    read -p "Type 'migrate' to confirm: " ans
    [ "$ans" != "migrate" ] && { info "Cancelled"; safe_pause; cleanup_temp; return 0; }

    echo ""
    echo -e "${CYAN}========== STEP 1/6: BACKUP ==========${NC}"
    local backup_dir
    backup_dir=$(create_backup)
    [ -z "$backup_dir" ] && { err "Backup failed"; safe_pause; cleanup_temp; return 1; }
    echo ""

    echo -e "${CYAN}========== STEP 2/6: PREPARE DB ==========${NC}"
    local src=""
    case "$db_type" in
        sqlite)
            src="$backup_dir/database.sqlite3"
            [ ! -f "$src" ] && src="$PASARGUARD_DATA/db.sqlite3"
            ;;
        *)
            src="$backup_dir/database.sql"
            ;;
    esac
    [ ! -f "$src" ] && { err "Source not found ($src)"; safe_pause; cleanup_temp; return 1; }
    ok "Source DB: $src"
    echo ""

    echo -e "${CYAN}========== STEP 3/6: CONVERT DB ==========${NC}"
    local mysql_sql="$TEMP_DIR/mysql_import.sql"
    convert_to_mysql "$src" "$mysql_sql" "$db_type" || { safe_pause; cleanup_temp; return 1; }
    cp "$mysql_sql" "$backup_dir/mysql_converted.sql" 2>/dev/null
    echo ""

    echo -e "${CYAN}========== STEP 4/6: STOP PASARGUARD ==========${NC}"
    stop_panel "$PASARGUARD_DIR" "Pasarguard"
    echo ""

    echo -e "${CYAN}========== STEP 5/6: MIGRATE CONFIGS ==========${NC}"
    migrate_configs
    echo ""

    echo -e "${CYAN}========== STEP 6/6: IMPORT TO REBECCA ==========${NC}"
    is_running "$REBECCA_DIR" || start_panel "$REBECCA_DIR" "Rebecca"
    wait_for_mysql "$MYSQL_WAIT"

    local import_ok=true
    import_to_rebecca "$mysql_sql" || import_ok=false

    info "Restarting Rebecca..."
    (cd "$REBECCA_DIR" && docker compose restart 2>/dev/null)
    sleep 5

    echo ""
    if [ "$import_ok" = true ]; then
        echo -e "${GREEN}Migration completed successfully!${NC}"
    else
        echo -e "${YELLOW}Migration completed with warnings; check SQL: $backup_dir/mysql_converted.sql${NC}"
    fi

    echo ""
    echo -e "Backup directory: ${CYAN}$backup_dir${NC}"
    echo -e "Rebecca dashboard (default): ${CYAN}https://YOUR_DOMAIN:8000/dashboard/${NC}"
    echo -e "Login with your existing credentials."
    echo ""

    cleanup_temp
    safe_pause
}

#==============================================================================
# View Backups & Log
#==============================================================================

view_backups() {
    clear
    echo -e "${CYAN}Backups in $BACKUP_ROOT${NC}"
    echo ""
    ls -lh "$BACKUP_ROOT" 2>/dev/null | grep -v "^total" || echo "(empty)"
    [ -f "$BACKUP_ROOT/.last_backup" ] && echo -e "\nLast: $(cat "$BACKUP_ROOT/.last_backup")"
    safe_pause
}

view_log() {
    clear
    echo -e "${CYAN}Log: $LOG_FILE${NC}"
    echo ""
    [ -f "$LOG_FILE" ] && tail -80 "$LOG_FILE" || echo "No log found."
    safe_pause
}

#==============================================================================
# Menu
#==============================================================================

migrator_menu() {
    while true; do
        clear
        echo -e "${BLUE}============= MIGRATION TOOLS =============${NC}"
        echo ""
        echo "  1) Migrate Pasarguard → Rebecca"
        echo "  2) Rollback to Pasarguard (using last backup)"
        echo ""
        echo "  3) View Backups"
        echo "  4) View Migration Log"
        echo ""
        echo "  0) Back"
        echo ""
        read -p "Select: " opt
        case "$opt" in
            1) do_migration ;;
            2) do_rollback ;;
            3) view_backups ;;
            4) view_log ;;
            0) return ;;
        esac
    done
}

#==============================================================================
# Entry Point
#==============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    migrator_menu
fi