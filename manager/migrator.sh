#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 9.5 (Final - All Fixes Applied)
#==============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -o pipefail
fi

#==============================================================================
# CONFIGURATION
#==============================================================================

PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"

REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"

REBECCA_INSTALL_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
LOG_FILE="${LOG_FILE:-/var/log/mrm_migration.log}"

TEMP_DIR=""
CONTAINER_TIMEOUT=120
MYSQL_WAIT=60

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

#==============================================================================
# HELPERS
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
# DEPENDENCIES
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
}

#==============================================================================
# DB DETECTION
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

get_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT=""; DB_NAME=""
    [ ! -f "$env_file" ] && return 1

    local db_url
    db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null \
             | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d ' ')

    eval "$(python3 << PYEOF
import re
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    scheme, rest = url.split('://', 1)
    if '+' in scheme: scheme = scheme.split('+', 1)[0]
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
}

#==============================================================================
# CONTAINER FINDER - FIXED
#==============================================================================

find_db_container() {
    local project_dir="$1" db_type="$2"
    [ ! -d "$project_dir" ] && return 1

    local cname=""

    # Method 1: Try docker compose service names (including timescaledb)
    for svc in timescaledb db postgres postgresql database mysql mariadb; do
        cname=$(cd "$project_dir" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        [ -n "$cname" ] && { echo "$cname"; return 0; }
    done

    # Method 2: Search by image name
    cname=$(docker ps --format '{{.Names}} {{.Image}}' | grep -iE "timescale|postgres|mysql|mariadb" | grep -i pasarguard | head -1 | awk '{print $1}')
    [ -n "$cname" ] && { echo "$cname"; return 0; }

    # Method 3: Generic pattern matching
    cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(timescale|postgres|mysql|mariadb|db)" | head -1)
    [ -n "$cname" ] && { echo "$cname"; return 0; }

    return 1
}

find_rebecca_db_container() {
    local cname=""

    # Method 1: docker compose
    for svc in mysql mariadb db database; do
        cname=$(cd "$REBECCA_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        [ -n "$cname" ] && { echo "$cname"; return 0; }
    done

    # Method 2: Pattern matching
    cname=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb|db)" | head -1)
    [ -n "$cname" ] && { echo "$cname"; return 0; }

    # Method 3: Any MySQL/MariaDB
    cname=$(docker ps --format '{{.Names}} {{.Image}}' | grep -iE "mysql|mariadb" | head -1 | awk '{print $1}')
    [ -n "$cname" ] && { echo "$cname"; return 0; }

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
        is_running "$dir" && { ok "$name started"; sleep 5; return 0; }
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
    (cd "$dir" && docker compose down 2>/dev/null) | tee -a "$LOG_FILE"
    sleep 3
    ok "$name stopped"
}

#==============================================================================
# BACKUP
#==============================================================================

create_backup() {
    info "Creating backup..."
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$backup_dir"
    echo "$backup_dir" > "$BACKUP_ROOT/.last_backup"

    if [ -d "$PASARGUARD_DIR" ]; then
        info "  Config..."
        tar --exclude='*/node_modules' -C "$(dirname "$PASARGUARD_DIR")" \
            -czf "$backup_dir/pasarguard_config.tar.gz" "$(basename "$PASARGUARD_DIR")" 2>/dev/null
        ok "  Config saved"
    fi

    if [ -d "$PASARGUARD_DATA" ]; then
        info "  Data..."
        tar -C "$(dirname "$PASARGUARD_DATA")" \
            -czf "$backup_dir/pasarguard_data.tar.gz" "$(basename "$PASARGUARD_DATA")" 2>/dev/null
        ok "  Data saved"
    fi

    local db_type
    db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$backup_dir/db_type.txt"
    info "  Database ($db_type)..."
    
    if ! export_database "$db_type" "$backup_dir"; then
        err "  Database export failed!"
        return 1
    fi

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
                cp "$PASARGUARD_DATA/db.sqlite3" "$backup_dir/database.sqlite3"
                ok "  SQLite exported"
                return 0
            else
                warn "  SQLite file not found"
                return 1
            fi
            ;;
        timescaledb|postgresql)
            export_postgresql "$backup_dir/database.sql"
            return $?
            ;;
        mysql|mariadb)
            export_mysql "$backup_dir/database.sql"
            return $?
            ;;
        *)
            warn "  Unknown db type"
            return 1
            ;;
    esac
}

#==============================================================================
# DATABASE EXPORT - FINAL FIXED VERSION
#==============================================================================

export_postgresql() {
    local output_file="$1"
    info "  Exporting PostgreSQL/TimescaleDB..."

    # 1. Get credentials from .env
    get_db_credentials "$PASARGUARD_DIR"
    local user="${DB_USER:-pasarguard}"
    local db="${DB_NAME:-pasarguard}"
    local pass="$DB_PASS"

    info "  User: $user, Database: $db"

    # 2. Find container
    local cname=$(find_db_container "$PASARGUARD_DIR" "postgresql")

    if [ -z "$cname" ]; then
        err "  Database container not found!"
        echo "  Available containers:"
        docker ps --format '    {{.Names}} - {{.Image}}'
        return 1
    fi

    info "  Container: $cname"

    # 3. Wait for PostgreSQL to be ready
    local i=0
    while [ $i -lt 30 ]; do
        if docker exec "$cname" pg_isready &>/dev/null; then
            break
        fi
        sleep 2
        i=$((i+2))
        echo -ne "  Waiting for PostgreSQL... ${i}s\r"
    done
    echo ""

    if ! docker exec "$cname" pg_isready &>/dev/null; then
        err "  PostgreSQL is not ready!"
        return 1
    fi

    local err_log="$TEMP_DIR/pg_dump.log"
    touch "$err_log"

    # 4. METHOD 1: Try with app user (PRIMARY - no postgres superuser in this setup)
    info "  Trying pg_dump with user: $user"
    if docker exec "$cname" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>"$err_log"; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Exported successfully: $size"
            return 0
        fi
    fi

    # 5. METHOD 2: Try with PGPASSWORD
    info "  Trying with PGPASSWORD..."
    if docker exec -e PGPASSWORD="$pass" "$cname" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>>"$err_log"; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Exported successfully: $size"
            return 0
        fi
    fi

    # 6. METHOD 3: Try postgres superuser (might not exist)
    info "  Trying postgres superuser..."
    if docker exec "$cname" pg_dump -U postgres -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Exported successfully: $size"
            return 0
        fi
    fi

    # 7. All methods failed
    err "  pg_dump failed!"
    echo ""
    echo "  --- Error Log ---"
    cat "$err_log" 2>/dev/null | head -10
    echo ""
    echo "  --- Manual Command ---"
    echo "  docker exec $cname pg_dump -U $user -d $db --no-owner --no-acl > /tmp/dump.sql"
    echo ""
    
    cat "$err_log" >> "$LOG_FILE" 2>/dev/null
    return 1
}

export_mysql() {
    local output_file="$1"
    info "  Exporting MySQL..."

    local cname=$(find_db_container "$PASARGUARD_DIR" "mysql")
    [ -z "$cname" ] && { err "  MySQL container not found"; return 1; }

    get_db_credentials "$PASARGUARD_DIR"
    local user="${DB_USER:-root}"
    local db="${DB_NAME:-pasarguard}"
    local pass="$DB_PASS"

    info "  Container: $cname"

    if docker exec "$cname" mysqldump -u"$user" -p"$pass" --single-transaction "$db" > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Exported successfully: $size"
            return 0
        fi
    fi

    err "  mysqldump failed"
    return 1
}

#==============================================================================
# CONVERSION
#==============================================================================

convert_to_mysql() {
    local src="$1" dst="$2" type="$3"
    case "$type" in
        sqlite) convert_sqlite "$src" "$dst" ;;
        postgresql|timescaledb) convert_postgresql "$src" "$dst" ;;
        mysql|mariadb) cp "$src" "$dst"; ok "No conversion needed" ;;
        *) err "Unknown type: $type"; return 1 ;;
    esac
}

convert_sqlite() {
    local src="$1" dst="$2"
    info "Converting SQLite → MySQL..."
    [ ! -f "$src" ] && { err "Source not found"; return 1; }
    local dump="$TEMP_DIR/sqlite.sql"

    if ! sqlite3 "$src" .dump > "$dump" 2>/dev/null; then
        err "SQLite dump failed"; return 1
    fi
    [ ! -s "$dump" ] && { err "Dump empty"; return 1; }

    python3 << PYEOF
import re
with open("$dump", 'r', encoding='utf-8', errors='replace') as f: c = f.read()
c = re.sub(r'BEGIN TRANSACTION;', 'START TRANSACTION;', c)
c = re.sub(r'PRAGMA.*?;\n?', '', c)
c = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
c = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
c = re.sub(r'\bINTEGER\b', 'INT', c, flags=re.I)
c = re.sub(r'\bREAL\b', 'DOUBLE', c, flags=re.I)
c = re.sub(r'\bBLOB\b', 'LONGBLOB', c, flags=re.I)
c = re.sub(r'\bAUTOINCREMENT\b', 'AUTO_INCREMENT', c, flags=re.I)
c = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`', c)
def fix_bool(m):
    s = m.group(0).replace("'t'", "'1'").replace("'f'", "'0'")
    return s.replace("'T'", "'1'").replace("'F'", "'0'")
c = re.sub(r'VALUES\s*\([^)]+\)', fix_bool, c, flags=re.I)
header = """-- SQLite to MySQL
SET NAMES utf8mb4; SET FOREIGN_KEY_CHECKS=0; SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';
"""
with open("$dst", 'w', encoding='utf-8') as f:
    f.write(header + c + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")
print("OK")
PYEOF
    [ $? -eq 0 ] && [ -s "$dst" ] && { ok "Conversion done"; return 0; }
    err "Conversion failed"; return 1
}

convert_postgresql() {
    local src="$1" dst="$2"
    info "Converting PostgreSQL → MySQL..."
    [ ! -f "$src" ] && { err "Source not found: $src"; return 1; }

    python3 << PYEOF
import re

with open("$src", 'r', encoding='utf-8', errors='replace') as f:
    c = f.read()

# Remove PostgreSQL-specific commands
patterns = [
    r'^SET\s+\w+.*?;$',
    r'^SELECT\s+pg_catalog\..*?;$',
    r'^\\\\connect.*$',
    r'^\\\\restrict.*$',
    r'^\\restrict.*$',
    r'^CREATE\s+EXTENSION.*?;$',
    r'^COMMENT\s+ON.*?;$',
    r'^ALTER\s+.*?OWNER\s+TO.*?;$',
    r'^GRANT\s+.*?;$',
    r'^REVOKE\s+.*?;$',
    r'^CREATE\s+SCHEMA.*?;$',
    r'^CREATE\s+SEQUENCE.*?;$',
    r'^ALTER\s+SEQUENCE.*?;$',
    r'^SELECT\s+.*?setval.*?;$',
    r'^SELECT\s+create_hypertable.*?;$',
    r'^SELECT\s+set_chunk.*?;$',
]
for p in patterns:
    c = re.sub(p, '', c, flags=re.M|re.I)

# Remove CREATE TYPE statements (MySQL handles ENUM differently)
c = re.sub(r'CREATE TYPE\s+\w+\.?\w*\s+AS\s+ENUM\s*\([^)]+\);', '', c, flags=re.I|re.S)

# Type conversions
types = [
    (r'\bSERIAL\b', 'INT AUTO_INCREMENT'),
    (r'\bBIGSERIAL\b', 'BIGINT AUTO_INCREMENT'),
    (r'\bSMALLSERIAL\b', 'SMALLINT AUTO_INCREMENT'),
    (r'\bBOOLEAN\b', 'TINYINT(1)'),
    (r'\bTIMESTAMP\s+WITH\s+TIME\s+ZONE\b', 'DATETIME'),
    (r'\bTIMESTAMP\s+WITHOUT\s+TIME\s+ZONE\b', 'DATETIME'),
    (r'\bTIMESTAMPTZ\b', 'DATETIME'),
    (r'\bBYTEA\b', 'LONGBLOB'),
    (r'\bUUID\b', 'VARCHAR(36)'),
    (r'\bJSONB\b', 'JSON'),
    (r'\bJSON\b', 'JSON'),
    (r'\bINET\b', 'VARCHAR(45)'),
    (r'\bCIDR\b', 'VARCHAR(45)'),
    (r'\bMACAADDR\b', 'VARCHAR(17)'),
    (r'\bDOUBLE\s+PRECISION\b', 'DOUBLE'),
    (r'\bCHARACTER\s+VARYING\b', 'VARCHAR'),
    (r'\bpublic\.', ''),
]
for p, r in types:
    c = re.sub(p, r, c, flags=re.I)

# Boolean values
c = re.sub(r"'t'::boolean", "'1'", c, flags=re.I)
c = re.sub(r"'f'::boolean", "'0'", c, flags=re.I)
c = re.sub(r'\btrue\b', "'1'", c, flags=re.I)
c = re.sub(r'\bfalse\b', "'0'", c, flags=re.I)

# Remove type casts
c = re.sub(r'::\w+(\[\])?', '', c)
c = re.sub(r"nextval\('[^']*'[^)]*\)", 'NULL', c, flags=re.I)

# CURRENT_TIMESTAMP
c = re.sub(r'\bCURRENT_TIMESTAMP\b', 'NOW()', c, flags=re.I)

# Convert identifiers from "name" to \`name\`
c = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`', c)

# Clean up multiple blank lines
c = re.sub(r'\n\s*\n\s*\n+', '\n\n', c)

header = """-- PostgreSQL to MySQL Conversion
-- Generated by MRM Migration Tool
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""

with open("$dst", 'w', encoding='utf-8') as f:
    f.write(header + c + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")

print("OK")
PYEOF

    if [ $? -eq 0 ] && [ -s "$dst" ]; then
        local size=$(du -h "$dst" | cut -f1)
        ok "Conversion done: $size"
        return 0
    fi
    err "Conversion failed"
    return 1
}

#==============================================================================
# REBECCA
#==============================================================================

check_rebecca_installed() { [ -d "$REBECCA_DIR" ] && [ -f "$REBECCA_DIR/.env" ]; }
check_rebecca_mysql() { [ -f "$REBECCA_DIR/.env" ] && grep -qiE "mysql|mariadb" "$REBECCA_DIR/.env"; }

install_rebecca() {
    echo ""
    echo -e "${YELLOW}Rebecca not installed.${NC}"
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
    err "Install failed"; return 1
}

wait_mysql() {
    local timeout="$1"
    info "Waiting for MySQL..."
    local i=0
    while [ $i -lt $timeout ]; do
        local cname=$(find_rebecca_db_container)
        if [ -n "$cname" ]; then
            local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
            if docker exec "$cname" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null; then
                ok "MySQL ready"
                return 0
            fi
        fi
        sleep 3
        i=$((i+3))
        echo -ne "  Waiting... ${i}s\r"
    done
    echo ""
    warn "MySQL not fully ready"
    return 1
}

import_to_rebecca() {
    local sql="$1"
    info "Importing to Rebecca..."
    [ ! -f "$sql" ] && { err "SQL file not found: $sql"; return 1; }

    local db pass
    db=$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    db="${db:-marzban}"

    local cname=$(find_rebecca_db_container)
    if [ -z "$cname" ]; then
        err "MySQL container not found"
        echo "Available containers:"
        docker ps --format '  {{.Names}} - {{.Image}}'
        return 1
    fi

    info "  Container: $cname"
    info "  Database: $db"

    # Method 1: Copy file and source
    docker cp "$sql" "$cname:/tmp/import.sql" 2>/dev/null
    if docker exec "$cname" mysql -uroot -p"$pass" "$db" -e "source /tmp/import.sql" 2>/dev/null; then
        docker exec "$cname" rm -f /tmp/import.sql 2>/dev/null
        ok "Import successful"
        return 0
    fi

    # Method 2: Pipe
    warn "Direct import failed, trying pipe..."
    if docker exec -i "$cname" mysql -uroot -p"$pass" "$db" < "$sql" 2>/dev/null; then
        ok "Import successful (pipe)"
        return 0
    fi

    err "Import failed"
    echo "Try manually:"
    echo "  docker exec -i $cname mysql -uroot -p'$pass' $db < $sql"
    return 1
}

#==============================================================================
# CONFIG MIGRATION
#==============================================================================

migrate_configs() {
    info "Migrating configs..."
    [ ! -f "$PASARGUARD_DIR/.env" ] && { warn "Pasarguard .env not found"; return 0; }
    [ ! -f "$REBECCA_DIR/.env" ] && { warn "Rebecca .env not found"; return 0; }

    local vars=(
        "SUDO_USERNAME" "SUDO_PASSWORD" "UVICORN_HOST" "UVICORN_PORT"
        "UVICORN_SSL_CERTFILE" "UVICORN_SSL_KEYFILE" "JWT_ACCESS_TOKEN_EXPIRE_MINUTES"
        "TELEGRAM_API_TOKEN" "TELEGRAM_ADMIN_ID" "TELEGRAM_PROXY_URL"
        "WEBHOOK_ADDRESS" "WEBHOOK_SECRET" "XRAY_JSON" "XRAY_EXECUTABLE_PATH"
        "XRAY_ASSETS_PATH" "XRAY_SUBSCRIPTION_URL_PREFIX" "XRAY_SUBSCRIPTION_TEMPLATE"
        "XRAY_FALLBACKS_INBOUND_TAG" "XRAY_EXCLUDE_INBOUND_TAGS"
        "CUSTOM_TEMPLATES_DIRECTORY" "SUBSCRIPTION_PAGE_TEMPLATE"
        "HOME_PAGE_TEMPLATE" "CLASH_SUBSCRIPTION_TEMPLATE" "DOCS" "DEBUG"
    )

    local n=0
    for v in "${vars[@]}"; do
        local val=$(grep "^${v}=" "$PASARGUARD_DIR/.env" 2>/dev/null | sed 's/[^=]*=//')
        if [ -n "$val" ]; then
            sed -i "/^${v}=/d" "$REBECCA_DIR/.env" 2>/dev/null
            echo "${v}=${val}" >> "$REBECCA_DIR/.env"
            n=$((n+1))
        fi
    done
    ok "Migrated $n variables"

    if [ -d "$PASARGUARD_DATA/certs" ]; then
        info "  Copying certs..."
        mkdir -p "$REBECCA_DATA/certs"
        cp -r "$PASARGUARD_DATA/certs/"* "$REBECCA_DATA/certs/" 2>/dev/null
        ok "  Certs copied"
    fi

    if [ -f "$PASARGUARD_DATA/xray_config.json" ]; then
        info "  Copying xray config..."
        mkdir -p "$REBECCA_DATA"
        cp "$PASARGUARD_DATA/xray_config.json" "$REBECCA_DATA/" 2>/dev/null
        ok "  Xray config copied"
    fi

    if [ -d "$PASARGUARD_DATA/templates" ]; then
        info "  Copying templates..."
        mkdir -p "$REBECCA_DATA/templates"
        cp -r "$PASARGUARD_DATA/templates/"* "$REBECCA_DATA/templates/" 2>/dev/null
        ok "  Templates copied"
    fi
}

#==============================================================================
# ROLLBACK
#==============================================================================

do_rollback() {
    clear
    echo -e "${CYAN}========== ROLLBACK TO PASARGUARD ==========${NC}"
    [ ! -f "$BACKUP_ROOT/.last_backup" ] && { err "No backup info found"; safe_pause; return 1; }
    local backup=$(cat "$BACKUP_ROOT/.last_backup")
    [ ! -d "$backup" ] && { err "Backup missing: $backup"; safe_pause; return 1; }

    echo -e "Using backup: ${GREEN}$backup${NC}"
    read -p "Type 'rollback' to confirm: " ans
    [ "$ans" != "rollback" ] && { info "Cancelled"; safe_pause; return 0; }

    init_migration
    is_running "$REBECCA_DIR" && stop_panel "$REBECCA_DIR" "Rebecca"

    if [ -f "$backup/pasarguard_config.tar.gz" ]; then
        info "Restoring config..."
        rm -rf "$PASARGUARD_DIR"
        mkdir -p "$(dirname "$PASARGUARD_DIR")"
        tar -xzf "$backup/pasarguard_config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")" 2>/dev/null
        ok "Config restored"
    fi

    if [ -f "$backup/pasarguard_data.tar.gz" ]; then
        info "Restoring data..."
        rm -rf "$PASARGUARD_DATA"
        mkdir -p "$(dirname "$PASARGUARD_DATA")"
        tar -xzf "$backup/pasarguard_data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")" 2>/dev/null
        ok "Data restored"
    fi

    info "Starting Pasarguard..."
    if start_panel "$PASARGUARD_DIR" "Pasarguard"; then
        echo -e "${GREEN}Rollback complete.${NC}"
    else
        err "Failed to start Pasarguard"
    fi
    cleanup_temp
    safe_pause
}

#==============================================================================
# MIGRATION FLOW
#==============================================================================

do_migration() {
    init_migration
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      PASARGUARD → REBECCA MIGRATION TOOL v9.5          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_dependencies || { safe_pause; cleanup_temp; return 1; }

    [ ! -d "$PASARGUARD_DIR" ] && { err "Pasarguard not found at $PASARGUARD_DIR"; safe_pause; cleanup_temp; return 1; }
    ok "Pasarguard found"

    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database type: ${CYAN}$db_type${NC}"
    [ "$db_type" = "unknown" ] && { err "Unknown database type"; safe_pause; cleanup_temp; return 1; }

    if ! check_rebecca_installed; then
        install_rebecca || { safe_pause; cleanup_temp; return 1; }
    else
        ok "Rebecca found"
    fi

    if ! check_rebecca_mysql; then
        err "Rebecca must be configured with MySQL/MariaDB"
        echo "Reinstall Rebecca with: --database mysql"
        safe_pause
        cleanup_temp
        return 1
    fi
    ok "Rebecca MySQL verified"

    echo ""
    echo -e "${YELLOW}This will migrate all data from Pasarguard to Rebecca.${NC}"
    read -p "Type 'migrate' to confirm: " ans
    [ "$ans" != "migrate" ] && { info "Cancelled"; safe_pause; cleanup_temp; return 0; }

    echo ""
    echo -e "${CYAN}━━━ Step 1: BACKUP ━━━${NC}"
    local backup_dir=$(create_backup)
    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        err "Backup failed"
        safe_pause
        cleanup_temp
        return 1
    fi

    echo ""
    echo -e "${CYAN}━━━ Step 2: VERIFY SOURCE ━━━${NC}"
    local src=""
    case "$db_type" in
        sqlite) src="$backup_dir/database.sqlite3" ;;
        *)      src="$backup_dir/database.sql" ;;
    esac

    if [ ! -f "$src" ] || [ ! -s "$src" ]; then
        err "Database export not found or empty: $src"
        safe_pause
        cleanup_temp
        return 1
    fi
    local src_size=$(du -h "$src" | cut -f1)
    ok "Source ready: $src ($src_size)"

    echo ""
    echo -e "${CYAN}━━━ Step 3: CONVERT ━━━${NC}"
    local mysql_sql="$TEMP_DIR/mysql_import.sql"
    if ! convert_to_mysql "$src" "$mysql_sql" "$db_type"; then
        err "Conversion failed"
        safe_pause
        cleanup_temp
        return 1
    fi
    cp "$mysql_sql" "$backup_dir/mysql_converted.sql" 2>/dev/null

    echo ""
    echo -e "${CYAN}━━━ Step 4: STOP PASARGUARD ━━━${NC}"
    stop_panel "$PASARGUARD_DIR" "Pasarguard"

    echo ""
    echo -e "${CYAN}━━━ Step 5: MIGRATE CONFIGS ━━━${NC}"
    migrate_configs

    echo ""
    echo -e "${CYAN}━━━ Step 6: START REBECCA & IMPORT ━━━${NC}"
    is_running "$REBECCA_DIR" || start_panel "$REBECCA_DIR" "Rebecca"
    wait_mysql "$MYSQL_WAIT"

    local import_ok=true
    if ! import_to_rebecca "$mysql_sql"; then
        import_ok=false
    fi

    echo ""
    echo -e "${CYAN}━━━ Step 7: RESTART REBECCA ━━━${NC}"
    info "Restarting Rebecca..."
    (cd "$REBECCA_DIR" && docker compose restart 2>/dev/null)
    sleep 5
    ok "Rebecca restarted"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$import_ok" = true ]; then
        echo -e "${GREEN}✓ Migration completed successfully!${NC}"
    else
        echo -e "${YELLOW}⚠ Migration completed with warnings.${NC}"
        echo -e "  Check SQL file: ${CYAN}$backup_dir/mysql_converted.sql${NC}"
    fi
    echo ""
    echo -e "Backup location: ${CYAN}$backup_dir${NC}"
    echo -e "To rollback: Select option 2 from menu"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    cleanup_temp
    safe_pause
}

#==============================================================================
# MENU
#==============================================================================

view_backups() {
    clear
    echo -e "${CYAN}=== BACKUPS ===${NC}"
    echo ""
    if [ -d "$BACKUP_ROOT" ]; then
        ls -lh "$BACKUP_ROOT" 2>/dev/null | grep -v "^total" || echo "No backups found"
    else
        echo "Backup directory not found"
    fi
    safe_pause
}

view_log() {
    clear
    echo -e "${CYAN}=== LOG (last 80 lines) ===${NC}"
    echo ""
    [ -f "$LOG_FILE" ] && tail -80 "$LOG_FILE" || echo "No log file found"
    safe_pause
}

show_status() {
    clear
    echo -e "${CYAN}=== STATUS ===${NC}"
    echo ""

    echo -e "${BOLD}Pasarguard:${NC}"
    if [ -d "$PASARGUARD_DIR" ]; then
        echo -e "  Directory: ${GREEN}$PASARGUARD_DIR${NC}"
        local pg_db=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
        echo -e "  Database: ${CYAN}$pg_db${NC}"
        if is_running "$PASARGUARD_DIR"; then
            echo -e "  Status: ${GREEN}Running${NC}"
        else
            echo -e "  Status: ${YELLOW}Stopped${NC}"
        fi
    else
        echo -e "  ${YELLOW}Not installed${NC}"
    fi

    echo ""
    echo -e "${BOLD}Rebecca:${NC}"
    if [ -d "$REBECCA_DIR" ]; then
        echo -e "  Directory: ${GREEN}$REBECCA_DIR${NC}"
        if check_rebecca_mysql; then
            echo -e "  Database: ${CYAN}MySQL${NC}"
        else
            echo -e "  Database: ${YELLOW}Not MySQL${NC}"
        fi
        if is_running "$REBECCA_DIR"; then
            echo -e "  Status: ${GREEN}Running${NC}"
        else
            echo -e "  Status: ${YELLOW}Stopped${NC}"
        fi
    else
        echo -e "  ${YELLOW}Not installed${NC}"
    fi

    echo ""
    echo -e "${BOLD}Last Backup:${NC}"
    if [ -f "$BACKUP_ROOT/.last_backup" ]; then
        cat "$BACKUP_ROOT/.last_backup"
    else
        echo "  None"
    fi

    safe_pause
}

migrator_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║     MRM MIGRATION TOOL v9.5            ║${NC}"
        echo -e "${BLUE}║     Pasarguard → Rebecca               ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
        echo ""
        echo " 1) Migrate Pasarguard → Rebecca"
        echo " 2) Rollback to Pasarguard"
        echo " 3) View Status"
        echo " 4) View Backups"
        echo " 5) View Log"
        echo " 0) Exit"
        echo ""
        read -p "Select option: " opt
        case "$opt" in
            1) do_migration ;;
            2) do_rollback ;;
            3) show_status ;;
            4) view_backups ;;
            5) view_log ;;
            0) exit 0 ;;
            *) echo "Invalid option" ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    migrator_menu
fi