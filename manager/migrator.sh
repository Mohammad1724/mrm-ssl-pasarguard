#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 6.0 (Final - Fully Tested)
#
# Pasarguard: /opt/pasarguard, /var/lib/pasarguard
#   - Databases: TimescaleDB, PostgreSQL, MySQL, MariaDB, SQLite
#   - CLI: pasarguard cli
#
# Rebecca: /opt/rebecca, /var/lib/rebecca
#   - Databases: MySQL, MariaDB, SQLite
#   - CLI: rebecca cli
#==============================================================================

#==============================================================================
# SAFETY
#==============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -o pipefail
fi

#==============================================================================
# CONFIGURATION
#==============================================================================

# Pasarguard (official paths)
PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"

# Rebecca (official paths)
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"

# Official install URL
REBECCA_INSTALL_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"

# Backup & Log
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
LOG_FILE="${LOG_FILE:-/var/log/mrm_migration.log}"

# Temp
TEMP_DIR=""

# Timeouts
CONTAINER_TIMEOUT=120
MYSQL_WAIT=60

# Colors
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
    echo "" >> "$LOG_FILE"
    echo "=== Migration: $(date) ===" >> "$LOG_FILE"
}

log() { echo "[$(date +'%F %T')] $*" >> "$LOG_FILE"; }
info() { echo -e "${BLUE}→${NC} $*"; log "INFO: $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; log "OK: $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; log "WARN: $*"; }
err() { echo -e "${RED}✗${NC} $*" >&2; log "ERROR: $*"; }

safe_pause() {
    echo ""
    echo -e "${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s -r
    echo ""
}

#==============================================================================
# DEPENDENCY CHECK
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
        err "Docker not running"
        return 1
    fi
    
    ok "Dependencies OK"
}

#==============================================================================
# DATABASE DETECTION
#==============================================================================

detect_db_type() {
    local panel_dir="$1"
    local data_dir="$2"
    
    [ ! -d "$panel_dir" ] && { echo "not_found"; return 1; }
    
    local env_file="$panel_dir/.env"
    
    if [ -f "$env_file" ]; then
        local db_url
        db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')
        
        # Check driver type (Pasarguard uses async drivers)
        case "$db_url" in
            *timescale*|*postgresql+asyncpg*)
                echo "timescaledb"; return 0 ;;
            *postgresql*)
                echo "postgresql"; return 0 ;;
            *mysql+asyncmy*|*mysql*)
                echo "mysql"; return 0 ;;
            *mariadb*)
                echo "mariadb"; return 0 ;;
            *sqlite+aiosqlite*|*sqlite*)
                echo "sqlite"; return 0 ;;
        esac
    fi
    
    # Fallback
    [ -f "$data_dir/db.sqlite3" ] && { echo "sqlite"; return 0; }
    
    echo "unknown"
    return 1
}

get_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    
    # Reset
    DB_USER="" DB_PASS="" DB_HOST="" DB_NAME="" DB_PORT=""
    
    [ ! -f "$env_file" ] && return 1
    
    local db_url
    db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')
    
    # Format: driver://user:pass@host:port/database
    # Use Python for reliable parsing (handles special chars in password)
    eval $(python3 << PYEOF
import re
import urllib.parse

url = "$db_url"
try:
    # Remove driver prefix
    url = re.sub(r'^[^:]+://', '', url)
    
    # Split user:pass@host:port/db
    if '@' in url:
        auth, rest = url.rsplit('@', 1)
        if ':' in auth:
            user, password = auth.split(':', 1)
        else:
            user, password = auth, ''
    else:
        user, password, rest = '', '', url
    
    # Split host:port/db
    if '/' in rest:
        hostport, db = rest.split('/', 1)
        db = db.split('?')[0]  # Remove query params
    else:
        hostport, db = rest, ''
    
    if ':' in hostport:
        host, port = hostport.rsplit(':', 1)
    else:
        host, port = hostport, ''
    
    # URL decode password
    password = urllib.parse.unquote(password)
    
    print(f'DB_USER="{user}"')
    print(f'DB_PASS="{password}"')
    print(f'DB_HOST="{host or "localhost"}"')
    print(f'DB_PORT="{port}"')
    print(f'DB_NAME="{db or "pasarguard"}"')
except:
    print('DB_USER=""')
    print('DB_PASS=""')
    print('DB_HOST="localhost"')
    print('DB_PORT=""')
    print('DB_NAME="pasarguard"')
PYEOF
)
    
    export DB_USER DB_PASS DB_HOST DB_PORT DB_NAME
}

#==============================================================================
# CONTAINER MANAGEMENT
#==============================================================================

find_panel_container() {
    local project_dir="$1"
    [ ! -d "$project_dir" ] && return 1
    
    (cd "$project_dir" && docker compose ps -q 2>/dev/null | head -1)
}

find_db_container() {
    local project_dir="$1"
    local db_type="$2"
    
    [ ! -d "$project_dir" ] && return 1
    
    local containers
    containers=$(cd "$project_dir" && docker compose ps -q 2>/dev/null)
    [ -z "$containers" ] && return 1
    
    local cid
    for cid in $containers; do
        case "$db_type" in
            mysql|mariadb)
                docker exec "$cid" mysql --version &>/dev/null && { echo "$cid"; return 0; }
                ;;
            postgresql|timescaledb)
                docker exec "$cid" psql --version &>/dev/null && { echo "$cid"; return 0; }
                ;;
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
    [ ! -d "$dir" ] && { err "Not found: $dir"; return 1; }
    
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
    (cd "$dir" && docker compose down 2>&1) | tee -a "$LOG_FILE"
    sleep 3
    ok "$name stopped"
}

#==============================================================================
# BACKUP
#==============================================================================

create_backup() {
    info "Creating backup..."
    
    local ts=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$backup_dir"
    
    echo "$backup_dir" > "$BACKUP_ROOT/.last_backup"
    
    # Config
    if [ -d "$PASARGUARD_DIR" ]; then
        info "  Config..."
        tar -czf "$backup_dir/config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")" "$(basename "$PASARGUARD_DIR")" 2>/dev/null
        ok "  Config saved"
    fi
    
    # Data
    if [ -d "$PASARGUARD_DATA" ]; then
        info "  Data (may take time)..."
        tar -czf "$backup_dir/data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")" "$(basename "$PASARGUARD_DATA")" 2>/dev/null
        ok "  Data saved"
    fi
    
    # Database
    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$backup_dir/db_type.txt"
    
    info "  Database ($db_type)..."
    export_database "$db_type" "$backup_dir"
    
    # Metadata
    cat > "$backup_dir/info.txt" << EOF
Date: $(date)
Host: $(hostname)
Panel: Pasarguard
Database: $db_type
Config: $PASARGUARD_DIR
Data: $PASARGUARD_DATA
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
                # Verify database integrity first
                if sqlite3 "$PASARGUARD_DATA/db.sqlite3" "PRAGMA integrity_check;" 2>/dev/null | grep -q "ok"; then
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
            export_postgresql "$backup_dir/database.sql" "$db_type"
            ;;
        mysql|mariadb)
            export_mysql "$backup_dir/database.sql"
            ;;
        *)
            warn "  Unknown database type"
            ;;
    esac
}

export_postgresql() {
    local output="$1" db_type="$2"
    
    local cid=$(find_db_container "$PASARGUARD_DIR" "postgresql")
    [ -z "$cid" ] && { err "  PostgreSQL container not found"; return 1; }
    
    get_db_credentials "$PASARGUARD_DIR"
    local user="${DB_USER:-postgres}"
    local db="${DB_NAME:-pasarguard}"
    
    if docker exec "$cid" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output" 2>/dev/null; then
        [ -s "$output" ] && { ok "  $db_type exported"; return 0; }
    fi
    
    err "  pg_dump failed"
    return 1
}

export_mysql() {
    local output="$1"
    
    local cid=$(find_db_container "$PASARGUARD_DIR" "mysql")
    [ -z "$cid" ] && { err "  MySQL container not found"; return 1; }
    
    get_db_credentials "$PASARGUARD_DIR"
    
    local pass="${DB_PASS}"
    [ -z "$pass" ] && pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$PASARGUARD_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    
    local db="${DB_NAME:-pasarguard}"
    
    if docker exec "$cid" mysqldump -uroot -p"$pass" --single-transaction "$db" > "$output" 2>/dev/null; then
        [ -s "$output" ] && { ok "  MySQL exported"; return 0; }
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
    
    # Dump with error handling
    if ! sqlite3 "$src" .dump > "$dump" 2>/dev/null; then
        err "SQLite dump failed"
        return 1
    fi
    
    [ ! -s "$dump" ] && { err "Dump is empty"; return 1; }
    
    # Convert
    python3 << PYEOF
import re

with open("$dump", 'r', encoding='utf-8', errors='replace') as f:
    c = f.read()

# Replacements
c = re.sub(r'BEGIN TRANSACTION;', 'START TRANSACTION;', c)
c = re.sub(r'PRAGMA.*?;\n?', '', c)
c = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
c = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
c = re.sub(r'\bINTEGER\b', 'INT', c, flags=re.I)
c = re.sub(r'\bREAL\b', 'DOUBLE', c, flags=re.I)
c = re.sub(r'\bBLOB\b', 'LONGBLOB', c, flags=re.I)
c = re.sub(r'\bAUTOINCREMENT\b', 'AUTO_INCREMENT', c, flags=re.I)
c = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`', c)

# Fix booleans in VALUES
def fix_bool(m):
    s = m.group(0)
    s = s.replace("'t'", "'1'").replace("'f'", "'0'")
    s = s.replace("'T'", "'1'").replace("'F'", "'0'")
    return s

c = re.sub(r'VALUES\s*\([^)]+\)', fix_bool, c, flags=re.I)

header = """-- SQLite to MySQL
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""

with open("$dst", 'w', encoding='utf-8') as f:
    f.write(header + c + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")

print("OK")
PYEOF
    
    [ $? -eq 0 ] && [ -s "$dst" ] && { ok "Conversion done"; return 0; }
    err "Conversion failed"
    return 1
}

convert_postgresql() {
    local src="$1" dst="$2"
    
    info "Converting PostgreSQL → MySQL..."
    
    [ ! -f "$src" ] && { err "Source not found"; return 1; }
    
    python3 << PYEOF
import re

with open("$src", 'r', encoding='utf-8', errors='replace') as f:
    c = f.read()

# Remove PG specific
patterns = [
    r'^SET\s+\w+.*?;$',
    r'^SELECT\s+pg_catalog\..*?;$',
    r'^\\\\connect.*$',
    r'^CREATE\s+EXTENSION.*?;$',
    r'^COMMENT\s+ON.*?;$',
    r'^ALTER\s+.*?OWNER\s+TO.*?;$',
    r'^GRANT\s+.*?;$',
    r'^REVOKE\s+.*?;$',
    r'^CREATE\s+SCHEMA.*?;$',
    r'^CREATE\s+SEQUENCE.*?;$',
    r'^ALTER\s+SEQUENCE.*?;$',
    r'^SELECT\s+.*?setval.*?;$',
    # TimescaleDB
    r'^SELECT\s+create_hypertable.*?;$',
    r'^SELECT\s+set_chunk.*?;$',
]

for p in patterns:
    c = re.sub(p, '', c, flags=re.M|re.I)

# Types
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
    (r'\bJSONB?\b', 'JSON'),
    (r'\bINET\b', 'VARCHAR(45)'),
    (r'\bCIDR\b', 'VARCHAR(45)'),
    (r'\bMACAADDR\b', 'VARCHAR(17)'),
    (r'\bDOUBLE\s+PRECISION\b', 'DOUBLE'),
    (r'\bCHARACTER\s+VARYING\b', 'VARCHAR'),
]

for p, r in types:
    c = re.sub(p, r, c, flags=re.I)

# Booleans
c = re.sub(r"'t'::boolean", "'1'", c, flags=re.I)
c = re.sub(r"'f'::boolean", "'0'", c, flags=re.I)
c = re.sub(r'\btrue\b', "'1'", c, flags=re.I)
c = re.sub(r'\bfalse\b', "'0'", c, flags=re.I)

# Remove casts
c = re.sub(r'::\w+(\[\])?', '', c)

# Sequences
c = re.sub(r"nextval\('[^']*'[^)]*\)", 'NULL', c, flags=re.I)

# Timestamp
c = re.sub(r'\bCURRENT_TIMESTAMP\b', 'NOW()', c, flags=re.I)

# Quotes
c = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`', c)

# Clean
c = re.sub(r'\n\s*\n\s*\n+', '\n\n', c)

header = """-- PostgreSQL to MySQL
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""

with open("$dst", 'w', encoding='utf-8') as f:
    f.write(header + c + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")

print("OK")
PYEOF
    
    [ $? -eq 0 ] && [ -s "$dst" ] && { ok "Conversion done"; return 0; }
    err "Conversion failed"
    return 1
}

#==============================================================================
# REBECCA CHECKS
#==============================================================================

check_rebecca() {
    [ -d "$REBECCA_DIR" ] && [ -f "$REBECCA_DIR/.env" ]
}

check_rebecca_mysql() {
    [ -f "$REBECCA_DIR/.env" ] && grep -qiE "mysql|mariadb" "$REBECCA_DIR/.env"
}

install_rebecca() {
    echo ""
    echo -e "${YELLOW}Rebecca not installed${NC}"
    echo ""
    echo "Command:"
    echo -e "  ${CYAN}sudo bash -c \"\$(curl -sL $REBECCA_INSTALL_URL)\" @ install --database mysql${NC}"
    echo ""
    
    read -p "Install now? (y/n): " ans
    [ "$ans" != "y" ] && return 1
    
    info "Installing Rebecca..."
    curl -sL "$REBECCA_INSTALL_URL" -o /tmp/rebecca.sh && bash /tmp/rebecca.sh install --database mysql
    rm -f /tmp/rebecca.sh
    
    check_rebecca && { ok "Rebecca installed"; return 0; }
    err "Installation failed"
    return 1
}

#==============================================================================
# IMPORT
#==============================================================================

wait_mysql() {
    local timeout="$1"
    info "Waiting for MySQL..."
    
    local i=0
    while [ $i -lt $timeout ]; do
        local cid=$(find_db_container "$REBECCA_DIR" "mysql")
        if [ -n "$cid" ]; then
            local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
            docker exec "$cid" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null && { ok "MySQL ready"; return 0; }
        fi
        sleep 3; i=$((i+3))
        echo -ne "  ${i}s...\r"
    done
    echo ""
    warn "MySQL may not be ready"
    return 1
}

import_to_rebecca() {
    local sql="$1"
    
    info "Importing to Rebecca..."
    
    [ ! -f "$sql" ] && { err "SQL not found"; return 1; }
    
    local db=$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    db="${db:-marzban}"
    
    local cid=$(find_db_container "$REBECCA_DIR" "mysql")
    [ -z "$cid" ] && { err "MySQL container not found"; return 1; }
    
    info "  Database: $db"
    
    # Method 1: Copy & source
    docker cp "$sql" "$cid:/tmp/import.sql" 2>/dev/null
    if docker exec "$cid" mysql -uroot -p"$pass" "$db" -e "source /tmp/import.sql" 2>/dev/null; then
        docker exec "$cid" rm -f /tmp/import.sql 2>/dev/null
        ok "Import successful"
        return 0
    fi
    
    # Method 2: Pipe
    warn "Trying alternative..."
    if docker exec -i "$cid" mysql -uroot -p"$pass" "$db" < "$sql" 2>/dev/null; then
        ok "Import successful"
        return 0
    fi
    
    err "Import failed"
    return 1
}

#==============================================================================
# CONFIG MIGRATION
#==============================================================================

migrate_configs() {
    info "Migrating configs..."
    
    [ ! -f "$PASARGUARD_DIR/.env" ] || [ ! -f "$REBECCA_DIR/.env" ] && { warn "Config missing"; return 0; }
    
    # Variables (from both official docs)
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
    
    # Certificates
    if [ -d "$PASARGUARD_DATA/certs" ]; then
        info "  Copying certs..."
        mkdir -p "$REBECCA_DATA/certs"
        cp -r "$PASARGUARD_DATA/certs/"* "$REBECCA_DATA/certs/" 2>/dev/null
        ok "  Certs copied"
    fi
    
    # Xray config
    if [ -f "$PASARGUARD_DATA/xray_config.json" ]; then
        info "  Copying xray config..."
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
# ROLLBACK
#==============================================================================

do_rollback() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}         ROLLBACK TO PASARGUARD              ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    [ ! -f "$BACKUP_ROOT/.last_backup" ] && { err "No backup found"; safe_pause; return 1; }
    
    local backup=$(cat "$BACKUP_ROOT/.last_backup")
    [ ! -d "$backup" ] && { err "Backup missing"; safe_pause; return 1; }
    
    echo -e "Backup: ${GREEN}$backup${NC}"
    [ -f "$backup/info.txt" ] && cat "$backup/info.txt"
    echo ""
    
    echo -e "${RED}This will stop Rebecca and restore Pasarguard${NC}"
    read -p "Type 'rollback': " ans
    [ "$ans" != "rollback" ] && { info "Cancelled"; safe_pause; return 0; }
    
    echo ""
    init_migration
    
    # Stop Rebecca
    is_running "$REBECCA_DIR" && stop_panel "$REBECCA_DIR" "Rebecca"
    
    # Restore
    if [ -f "$backup/config.tar.gz" ]; then
        info "Restoring config..."
        rm -rf "$PASARGUARD_DIR"
        mkdir -p "$(dirname "$PASARGUARD_DIR")"
        tar -xzf "$backup/config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")"
        ok "Config restored"
    fi
    
    if [ -f "$backup/data.tar.gz" ]; then
        info "Restoring data..."
        rm -rf "$PASARGUARD_DATA"
        mkdir -p "$(dirname "$PASARGUARD_DATA")"
        tar -xzf "$backup/data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")"
        ok "Data restored"
    fi
    
    # Start
    info "Starting Pasarguard..."
    start_panel "$PASARGUARD_DIR" "Pasarguard" && echo -e "${GREEN}Rollback complete!${NC}" || echo "Start failed. Try: cd $PASARGUARD_DIR && docker compose up -d"
    
    cleanup_temp
    safe_pause
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

do_migration() {
    init_migration
    
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}      PASARGUARD → REBECCA MIGRATION              ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Checks
    check_dependencies || { safe_pause; cleanup_temp; return 1; }
    echo ""
    
    [ ! -d "$PASARGUARD_DIR" ] && { err "Pasarguard not found"; safe_pause; cleanup_temp; return 1; }
    ok "Pasarguard found"
    
    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database: ${CYAN}$db_type${NC}"
    [ "$db_type" = "unknown" ] && { err "Unknown database"; safe_pause; cleanup_temp; return 1; }
    
    check_rebecca || { install_rebecca || { safe_pause; cleanup_temp; return 1; }; }
    ok "Rebecca found"
    
    check_rebecca_mysql || { err "Rebecca not using MySQL"; safe_pause; cleanup_temp; return 1; }
    ok "MySQL verified"
    
    # Confirm
    echo ""
    echo -e "${BOLD}$db_type → MySQL${NC}"
    echo -e "${RED}⚠ This will migrate all data ⚠${NC}"
    read -p "Type 'migrate': " ans
    [ "$ans" != "migrate" ] && { info "Cancelled"; safe_pause; cleanup_temp; return 0; }
    
    echo ""
    
    # 1. Backup
    echo -e "${BOLD}[1/6] Backup${NC}"
    local backup=$(create_backup)
    [ -z "$backup" ] && { err "Backup failed"; safe_pause; cleanup_temp; return 1; }
    echo ""
    
    # 2. Source
    echo -e "${BOLD}[2/6] Source${NC}"
    local src=""
    case "$db_type" in
        sqlite) src="$backup/database.sqlite3"; [ ! -f "$src" ] && src="$PASARGUARD_DATA/db.sqlite3" ;;
        *) src="$backup/database.sql" ;;
    esac
    [ ! -f "$src" ] && { err "Source not found"; safe_pause; cleanup_temp; return 1; }
    ok "Source: $src"
    echo ""
    
    # 3. Convert
    echo -e "${BOLD}[3/6] Convert${NC}"
    local mysql_sql="$TEMP_DIR/mysql.sql"
    convert_to_mysql "$src" "$mysql_sql" "$db_type" || { safe_pause; cleanup_temp; return 1; }
    cp "$mysql_sql" "$backup/mysql.sql" 2>/dev/null
    echo ""
    
    # 4. Stop
    echo -e "${BOLD}[4/6] Stop Pasarguard${NC}"
    stop_panel "$PASARGUARD_DIR" "Pasarguard"
    echo ""
    
    # 5. Configs
    echo -e "${BOLD}[5/6] Configs${NC}"
    migrate_configs
    echo ""
    
    # 6. Import
    echo -e "${BOLD}[6/6] Import${NC}"
    is_running "$REBECCA_DIR" || start_panel "$REBECCA_DIR" "Rebecca"
    wait_mysql "$MYSQL_WAIT"
    
    local ok_import=true
    import_to_rebecca "$mysql_sql" || ok_import=false
    
    info "Restarting Rebecca..."
    (cd "$REBECCA_DIR" && docker compose restart 2>/dev/null)
    sleep 5
    
    # Done
    echo ""
    if [ "$ok_import" = true ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}            MIGRATION SUCCESSFUL!                   ${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${YELLOW}Migration completed with warnings${NC}"
        echo "SQL: $backup/mysql.sql"
    fi
    
    echo ""
    echo -e "Backup: ${CYAN}$backup${NC}"
    echo -e "Dashboard: ${CYAN}https://YOUR_DOMAIN:8000/dashboard/${NC}"
    
    cleanup_temp
    safe_pause
}

#==============================================================================
# MENU
#==============================================================================

view_backups() {
    clear
    echo -e "${CYAN}Backups: $BACKUP_ROOT${NC}"
    echo ""
    ls -lh "$BACKUP_ROOT" 2>/dev/null | grep -v "^total" || echo "(empty)"
    [ -f "$BACKUP_ROOT/.last_backup" ] && echo -e "\nLast: $(cat "$BACKUP_ROOT/.last_backup")"
    safe_pause
}

view_log() {
    clear
    [ -f "$LOG_FILE" ] && tail -80 "$LOG_FILE" || echo "No log"
    safe_pause
}

migrator_menu() {
    while true; do
        clear
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}            MIGRATION TOOLS                    ${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} Migrate Pasarguard → Rebecca"
        echo -e "  ${RED}2)${NC} Rollback to Pasarguard"
        echo ""
        echo -e "  ${CYAN}3)${NC} View Backups"
        echo -e "  ${CYAN}4)${NC} View Log"
        echo ""
        echo -e "  ${YELLOW}0)${NC} Back"
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
# ENTRY
#==============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    migrator_menu
fi