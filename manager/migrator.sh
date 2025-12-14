#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 9.0 (Fixed: Internal Port 5432 & Error Logging)
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
# CONTAINER FINDER
#==============================================================================

find_db_container() {
    local project_dir="$1" db_type="$2"
    [ ! -d "$project_dir" ] && return 1

    # 1. Try finding by service name in docker-compose
    local cid=$(cd "$project_dir" && docker compose ps -q 2>/dev/null | \
        xargs docker inspect --format '{{.Id}} {{.Config.Image}} {{.Name}}' 2>/dev/null | \
        grep -iE "postgres|timescale|mysql|mariadb|db" | head -1 | awk '{print $1}')
    
    if [ -n "$cid" ]; then
        echo "$cid"
        return 0
    fi

    # 2. Try simple name matching
    docker ps --format '{{.ID}} {{.Names}}' | grep -iE "pasarguard.*(db|postgres|timescale|mysql)" | head -1 | awk '{print $1}'
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
    (cd "$dir" && docker compose down 2>&null) | tee -a "$LOG_FILE"
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
    export_database "$db_type" "$backup_dir"

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
            warn "  Unknown db type"
            ;;
    esac
}

#==============================================================================
# DATABASE EXPORT - FIXED LOGIC
#==============================================================================

export_postgresql_host() {
    local output_file="$1" db_type="$2"
    info "  Exporting $db_type (Container Mode)..."

    # 1. Credentials
    get_db_credentials "$PASARGUARD_DIR"
    local user="${DB_USER:-pasarguard}"
    local db="${DB_NAME:-pasarguard}"
    local pass="$DB_PASS"

    # 2. Find container
    local cid=$(find_db_container "$PASARGUARD_DIR" "postgresql")
    [ -z "$cid" ] && { err "  Database container not found!"; return 1; }

    # 3. Dump via Container (Force Internal Port 5432)
    # We purposefully IGNORE $DB_PORT from .env (6432) because that's external.
    # Inside the container, Postgres is always on 5432.
    
    local dump_cmd="pg_dump -h 127.0.0.1 -p 5432 -U $user -d $db --no-owner --no-acl"
    local err_log="$TEMP_DIR/pg_dump.log"

    # Try with Password
    if docker exec -e PGPASSWORD="$pass" "$cid" sh -c "$dump_cmd" > "$output_file" 2> "$err_log"; then
        if [ -s "$output_file" ]; then
            ok "  Exported successfully"
            return 0
        fi
    fi

    # 4. Fallback: Host Mode (Using external port 6432)
    # This requires postgresql-client on host matching version, BUT if version mismatch occurs,
    # we can't do anything else.
    
    info "  Container dump failed. Showing error:"
    cat "$err_log" | head -n 5
    echo "..."
    
    # Check what actually happened
    if grep -q "Connection refused" "$err_log"; then
        warn "  Inside container connection failed. Trying socket..."
        # Try without -h (Socket)
        if docker exec -e PGPASSWORD="$pass" "$cid" sh -c "pg_dump -U $user -d $db --no-owner --no-acl" > "$output_file" 2>/dev/null; then
             if [ -s "$output_file" ]; then
                ok "  Exported successfully (Socket)"
                return 0
            fi
        fi
    fi

    err "  pg_dump failed completely."
    echo "--- Last Error Log ---" >> "$LOG_FILE"
    cat "$err_log" >> "$LOG_FILE"
    return 1
}

export_mysql_host() {
    local output_file="$1"
    info "  Exporting MySQL..."

    local cid=$(find_db_container "$PASARGUARD_DIR" "mysql")
    [ -z "$cid" ] && { err "  MySQL container not found"; return 1; }

    get_db_credentials "$PASARGUARD_DIR"
    local user="${DB_USER:-root}"
    local db="${DB_NAME:-pasarguard}"
    local pass="$DB_PASS"

    if docker exec "$cid" mysqldump -u"$user" -p"$pass" --single-transaction "$db" > "$output_file" 2>/dev/null; then
        ok "  Exported successfully"
        return 0
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
    [ ! -f "$src" ] && { err "Source not found"; return 1; }

    python3 << PYEOF
import re
with open("$src", 'r', encoding='utf-8', errors='replace') as f: c = f.read()
patterns = [
    r'^SET\s+\w+.*?;$', r'^SELECT\s+pg_catalog\..*?;$', r'^\\\\connect.*$',
    r'^CREATE\s+EXTENSION.*?;$', r'^COMMENT\s+ON.*?;$', r'^ALTER\s+.*?OWNER\s+TO.*?;$',
    r'^GRANT\s+.*?;$', r'^REVOKE\s+.*?;$', r'^CREATE\s+SCHEMA.*?;$',
    r'^CREATE\s+SEQUENCE.*?;$', r'^ALTER\s+SEQUENCE.*?;$', r'^SELECT\s+.*?setval.*?;$',
    r'^SELECT\s+create_hypertable.*?;$', r'^SELECT\s+set_chunk.*?;$'
]
for p in patterns: c = re.sub(p, '', c, flags=re.M|re.I)
types = [
    (r'\bSERIAL\b', 'INT AUTO_INCREMENT'), (r'\bBIGSERIAL\b', 'BIGINT AUTO_INCREMENT'),
    (r'\bSMALLSERIAL\b', 'SMALLINT AUTO_INCREMENT'), (r'\bBOOLEAN\b', 'TINYINT(1)'),
    (r'\bTIMESTAMP\s+WITH\s+TIME\s+ZONE\b', 'DATETIME'), (r'\bTIMESTAMP\s+WITHOUT\s+TIME\s+ZONE\b', 'DATETIME'),
    (r'\bTIMESTAMPTZ\b', 'DATETIME'), (r'\bBYTEA\b', 'LONGBLOB'), (r'\bUUID\b', 'VARCHAR(36)'),
    (r'\bJSONB?\b', 'JSON'), (r'\bINET\b', 'VARCHAR(45)'), (r'\bCIDR\b', 'VARCHAR(45)'),
    (r'\bMACAADDR\b', 'VARCHAR(17)'), (r'\bDOUBLE\s+PRECISION\b', 'DOUBLE'),
    (r'\bCHARACTER\s+VARYING\b', 'VARCHAR')
]
for p, r in types: c = re.sub(p, r, c, flags=re.I)
c = re.sub(r"'t'::boolean", "'1'", c, flags=re.I)
c = re.sub(r"'f'::boolean", "'0'", c, flags=re.I)
c = re.sub(r'\btrue\b', "'1'", c, flags=re.I)
c = re.sub(r'\bfalse\b', "'0'", c, flags=re.I)
c = re.sub(r'::\w+(\[\])?', '', c)
c = re.sub(r"nextval\('[^']*'[^)]*\)", 'NULL', c, flags=re.I)
c = re.sub(r'\bCURRENT_TIMESTAMP\b', 'NOW()', c, flags=re.I)
c = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'`\1`', c)
c = re.sub(r'\n\s*\n\s*\n+', '\n\n', c)
header = """-- PG to MySQL
SET NAMES utf8mb4; SET FOREIGN_KEY_CHECKS=0; SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';
"""
with open("$dst", 'w', encoding='utf-8') as f:
    f.write(header + c + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")
print("OK")
PYEOF
    [ $? -eq 0 ] && [ -s "$dst" ] && { ok "Conversion done"; return 0; }
    err "Conversion failed"; return 1
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
        local cid=$(find_db_container "$REBECCA_DIR" "mysql")
        if [ -n "$cid" ]; then
            local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
            docker exec "$cid" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null && { ok "MySQL ready"; return 0; }
        fi
        sleep 3; i=$((i+3))
        echo -ne "  ${i}s...\r"
    done
    echo ""
    warn "MySQL not fully ready"
    return 1
}

import_to_rebecca() {
    local sql="$1"
    info "Importing to Rebecca..."
    [ ! -f "$sql" ] && { err "SQL not found"; return 1; }

    local db pass
    db=$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    db="${db:-marzban}"

    local cid=$(find_db_container "$REBECCA_DIR" "mysql")
    [ -z "$cid" ] && { err "MySQL container not found"; return 1; }

    docker cp "$sql" "$cid:/tmp/import.sql" 2>/dev/null
    if docker exec "$cid" mysql -uroot -p"$pass" "$db" -e "source /tmp/import.sql" 2>/dev/null; then
        docker exec "$cid" rm -f /tmp/import.sql 2>/dev/null
        ok "Import successful"
        return 0
    fi
    warn "Direct import failed, trying pipe..."
    if docker exec -i "$cid" mysql -uroot -p"$pass" "$db" < "$sql" 2>/dev/null; then
        ok "Import successful (pipe)"
        return 0
    fi
    err "Import failed"; return 1
}

#==============================================================================
# CONFIG MIGRATION
#==============================================================================

migrate_configs() {
    info "Migrating configs..."
    [ ! -f "$PASARGUARD_DIR/.env" ] || [ ! -f "$REBECCA_DIR/.env" ] && { warn "Config missing"; return 0; }

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
# ROLLBACK (FIXED)
#==============================================================================

do_rollback() {
    clear
    echo -e "${CYAN}========== ROLLBACK TO PASARGUARD ==========${NC}"
    [ ! -f "$BACKUP_ROOT/.last_backup" ] && { err "No backup info"; safe_pause; return 1; }
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
    echo -e "${CYAN}====== PASARGUARD → REBECCA MIGRATION ======${NC}"
    check_dependencies || { safe_pause; cleanup_temp; return 1; }

    [ ! -d "$PASARGUARD_DIR" ] && { err "Pasarguard not found"; safe_pause; cleanup_temp; return 1; }
    ok "Pasarguard found"

    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database: ${CYAN}$db_type${NC}"
    [ "$db_type" = "unknown" ] && { err "Unknown DB"; safe_pause; cleanup_temp; return 1; }

    if ! check_rebecca_installed; then
        install_rebecca || { safe_pause; cleanup_temp; return 1; }
    else
        ok "Rebecca found"
    fi

    if ! check_rebecca_mysql; then
        err "Rebecca needs MySQL"; safe_pause; cleanup_temp; return 1;
    fi
    ok "MySQL verified"

    echo ""
    read -p "Type 'migrate' to confirm: " ans
    [ "$ans" != "migrate" ] && { info "Cancelled"; safe_pause; cleanup_temp; return 0; }

    echo ""
    echo -e "${CYAN}--- 1. BACKUP ---${NC}"
    local backup_dir=$(create_backup)
    [ -z "$backup_dir" ] && { err "Backup failed"; safe_pause; cleanup_temp; return 1; }

    echo -e "${CYAN}--- 2. SOURCE ---${NC}"
    local src=""
    case "$db_type" in
        sqlite) src="$backup_dir/database.sqlite3" ;;
        *)      src="$backup_dir/database.sql" ;;
    esac
    [ ! -f "$src" ] && { err "Source not found ($src)"; safe_pause; cleanup_temp; return 1; }
    ok "Source: $src"

    echo -e "${CYAN}--- 3. CONVERT ---${NC}"
    local mysql_sql="$TEMP_DIR/mysql_import.sql"
    convert_to_mysql "$src" "$mysql_sql" "$db_type" || { safe_pause; cleanup_temp; return 1; }
    cp "$mysql_sql" "$backup_dir/mysql_converted.sql" 2>/dev/null

    echo -e "${CYAN}--- 4. STOP PASARGUARD ---${NC}"
    stop_panel "$PASARGUARD_DIR" "Pasarguard"

    echo -e "${CYAN}--- 5. MIGRATE CONFIGS ---${NC}"
    migrate_configs

    echo -e "${CYAN}--- 6. IMPORT ---${NC}"
    is_running "$REBECCA_DIR" || start_panel "$REBECCA_DIR" "Rebecca"
    wait_mysql "$MYSQL_WAIT"

    local import_ok=true
    import_to_rebecca "$mysql_sql" || import_ok=false

    info "Restarting Rebecca..."
    (cd "$REBECCA_DIR" && docker compose restart 2>/dev/null)
    sleep 5

    echo ""
    if [ "$import_ok" = true ]; then
        echo -e "${GREEN}Migration completed!${NC}"
    else
        echo -e "${YELLOW}Completed with warnings. Check SQL: $backup_dir/mysql_converted.sql${NC}"
    fi
    cleanup_temp
    safe_pause
}

#==============================================================================
# MENU
#==============================================================================

view_backups() {
    clear
    ls -lh "$BACKUP_ROOT" 2>/dev/null | grep -v "^total" || echo "Empty"
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
        echo -e "${BLUE}=== MIGRATION TOOLS ===${NC}"
        echo " 1) Migrate Pasarguard → Rebecca"
        echo " 2) Rollback"
        echo " 3) View Backups"
        echo " 4) View Log"
        echo " 0) Back"
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    migrator_menu
fi