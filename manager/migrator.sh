#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 9.6 (Final - All Bugs Fixed)
#==============================================================================

set -o pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================

PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"
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
        TEMP_DIR="/tmp/mrm-migration-$$"
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

log() {
    echo "[$(date +'%F %T')] $*" >> "$LOG_FILE"
}

info() {
    echo -e "${BLUE}→${NC} $*"
    log "INFO: $*"
}

ok() {
    echo -e "${GREEN}✓${NC} $*"
    log "OK: $*"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $*"
    log "WARN: $*"
}

err() {
    echo -e "${RED}✗${NC} $*"
    log "ERROR: $*"
}

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
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
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
# DATABASE DETECTION
#==============================================================================

detect_db_type() {
    local panel_dir="$1"
    local data_dir="$2"

    if [ ! -d "$panel_dir" ]; then
        echo "not_found"
        return 1
    fi

    local env_file="$panel_dir/.env"
    if [ -f "$env_file" ]; then
        local db_url
        db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')

        case "$db_url" in
            *timescale*|*postgresql+asyncpg*)
                echo "timescaledb"
                return 0
                ;;
            *postgresql*)
                echo "postgresql"
                return 0
                ;;
            *mysql+asyncmy*|*mysql*)
                echo "mysql"
                return 0
                ;;
            *mariadb*)
                echo "mariadb"
                return 0
                ;;
            *sqlite+aiosqlite*|*sqlite*)
                echo "sqlite"
                return 0
                ;;
        esac
    fi

    if [ -f "$data_dir/db.sqlite3" ]; then
        echo "sqlite"
        return 0
    fi

    echo "unknown"
    return 1
}

get_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"

    DB_USER=""
    DB_PASS=""
    DB_HOST=""
    DB_PORT=""
    DB_NAME=""

    if [ ! -f "$env_file" ]; then
        return 1
    fi

    local db_url
    db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d ' ')

    eval "$(python3 << PYEOF
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    scheme, rest = url.split('://', 1)
    if '+' in scheme:
        scheme = scheme.split('+', 1)[0]
    url = scheme + '://' + rest
    p = urlparse(url)
    print(f'DB_USER="{p.username or ""}"')
    print(f'DB_PASS="{unquote(p.password or "")}"')
    print(f'DB_HOST="{p.hostname or "localhost"}"')
    print(f'DB_PORT="{p.port or ""}"')
    print(f'DB_NAME="{(p.path or "").lstrip("/") or "pasarguard"}"')
else:
    print('DB_USER=""')
    print('DB_PASS=""')
    print('DB_HOST="localhost"')
    print('DB_PORT=""')
    print('DB_NAME="pasarguard"')
PYEOF
)"
    export DB_USER DB_PASS DB_HOST DB_PORT DB_NAME
}

#==============================================================================
# CONTAINER MANAGEMENT
#==============================================================================

find_pg_container() {
    local cname=""

    # Method 1: Docker compose service names
    for svc in timescaledb db postgres postgresql database; do
        cname=$(cd "$PASARGUARD_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        if [ -n "$cname" ]; then
            echo "$cname"
            return 0
        fi
    done

    # Method 2: Pattern matching
    cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(timescale|postgres|db)" | head -1)
    if [ -n "$cname" ]; then
        echo "$cname"
        return 0
    fi

    return 1
}

find_mysql_container() {
    local cname=""

    # Method 1: Docker compose service names
    for svc in mysql mariadb db database; do
        cname=$(cd "$REBECCA_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        if [ -n "$cname" ]; then
            echo "$cname"
            return 0
        fi
    done

    # Method 2: Pattern matching
    cname=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb|db)" | head -1)
    if [ -n "$cname" ]; then
        echo "$cname"
        return 0
    fi

    # Method 3: Any MySQL
    cname=$(docker ps --format '{{.Names}} {{.Image}}' | grep -iE "mysql|mariadb" | head -1 | awk '{print $1}')
    if [ -n "$cname" ]; then
        echo "$cname"
    fi
}

is_running() {
    local dir="$1"
    if [ -d "$dir" ]; then
        (cd "$dir" && docker compose ps 2>/dev/null | grep -qE "Up|running")
        return $?
    fi
    return 1
}

start_panel() {
    local dir="$1"
    local name="$2"

    info "Starting $name..."

    if [ ! -d "$dir" ]; then
        err "$dir not found"
        return 1
    fi

    (cd "$dir" && docker compose up -d) &>/dev/null

    local i=0
    while [ $i -lt $CONTAINER_TIMEOUT ]; do
        if is_running "$dir"; then
            ok "$name started"
            sleep 3
            return 0
        fi
        sleep 3
        i=$((i+3))
    done

    err "$name failed to start"
    return 1
}

stop_panel() {
    local dir="$1"
    local name="$2"

    if [ ! -d "$dir" ]; then
        return 0
    fi

    info "Stopping $name..."
    (cd "$dir" && docker compose down) &>/dev/null
    sleep 2
    ok "$name stopped"
}

#==============================================================================
# BACKUP
#==============================================================================

create_backup() {
    info "Creating backup..."

    local ts=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP_DIR="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$CURRENT_BACKUP_DIR"
    echo "$CURRENT_BACKUP_DIR" > "$BACKUP_ROOT/.last_backup"

    # Backup config
    if [ -d "$PASARGUARD_DIR" ]; then
        info "  Backing up config..."
        tar --exclude='*/node_modules' -C "$(dirname "$PASARGUARD_DIR")" \
            -czf "$CURRENT_BACKUP_DIR/pasarguard_config.tar.gz" "$(basename "$PASARGUARD_DIR")" 2>/dev/null
        ok "  Config saved"
    fi

    # Backup data
    if [ -d "$PASARGUARD_DATA" ]; then
        info "  Backing up data..."
        tar -C "$(dirname "$PASARGUARD_DATA")" \
            -czf "$CURRENT_BACKUP_DIR/pasarguard_data.tar.gz" "$(basename "$PASARGUARD_DATA")" 2>/dev/null
        ok "  Data saved"
    fi

    # Export database
    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$CURRENT_BACKUP_DIR/db_type.txt"
    info "  Exporting database ($db_type)..."

    local export_success=false

    case "$db_type" in
        sqlite)
            if [ -f "$PASARGUARD_DATA/db.sqlite3" ]; then
                cp "$PASARGUARD_DATA/db.sqlite3" "$CURRENT_BACKUP_DIR/database.sqlite3"
                ok "  SQLite exported"
                export_success=true
            else
                err "  SQLite file not found"
            fi
            ;;
        timescaledb|postgresql)
            if export_postgresql "$CURRENT_BACKUP_DIR/database.sql"; then
                export_success=true
            fi
            ;;
        mysql|mariadb)
            if export_mysql "$CURRENT_BACKUP_DIR/database.sql"; then
                export_success=true
            fi
            ;;
        *)
            err "  Unknown database type: $db_type"
            ;;
    esac

    # Write info file
    cat > "$CURRENT_BACKUP_DIR/info.txt" << EOF
Date: $(date)
Host: $(hostname)
Database: $db_type
Export Success: $export_success
Pasarguard Dir: $PASARGUARD_DIR
Pasarguard Data: $PASARGUARD_DATA
EOF

    ok "Backup saved to: $CURRENT_BACKUP_DIR"

    if [ "$export_success" = true ]; then
        return 0
    else
        return 1
    fi
}

export_postgresql() {
    local output_file="$1"

    # Get credentials
    get_db_credentials "$PASARGUARD_DIR"
    local user="${DB_USER:-pasarguard}"
    local db="${DB_NAME:-pasarguard}"
    local pass="$DB_PASS"

    info "  Database user: $user"
    info "  Database name: $db"

    # Find container
    local cname=$(find_pg_container)
    if [ -z "$cname" ]; then
        err "  PostgreSQL container not found!"
        echo "  Available containers:"
        docker ps --format '    {{.Names}} - {{.Image}}'
        return 1
    fi

    info "  Container: $cname"

    # Wait for PostgreSQL to be ready
    info "  Waiting for PostgreSQL..."
    local i=0
    while [ $i -lt 30 ]; do
        if docker exec "$cname" pg_isready &>/dev/null; then
            ok "  PostgreSQL is ready"
            break
        fi
        sleep 2
        i=$((i+2))
    done

    if [ $i -ge 30 ]; then
        warn "  PostgreSQL may not be ready"
    fi

    # Method 1: Try with app user (this works for your setup)
    info "  Dumping with user: $user"
    if docker exec "$cname" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Database exported: $size"
            return 0
        fi
    fi

    # Method 2: Try with PGPASSWORD
    info "  Trying with PGPASSWORD..."
    if docker exec -e PGPASSWORD="$pass" "$cname" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Database exported: $size"
            return 0
        fi
    fi

    # Method 3: Try postgres user
    info "  Trying postgres superuser..."
    if docker exec "$cname" pg_dump -U postgres -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Database exported: $size"
            return 0
        fi
    fi

    err "  All export methods failed"
    echo ""
    echo "  Try manually:"
    echo "  docker exec $cname pg_dump -U $user -d $db --no-owner --no-acl > /tmp/dump.sql"
    return 1
}

export_mysql() {
    local output_file="$1"

    get_db_credentials "$PASARGUARD_DIR"
    local user="${DB_USER:-root}"
    local db="${DB_NAME:-pasarguard}"
    local pass="$DB_PASS"

    local cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(mysql|mariadb|db)" | head -1)
    if [ -z "$cname" ]; then
        err "  MySQL container not found"
        return 1
    fi

    info "  Container: $cname"

    if docker exec "$cname" mysqldump -u"$user" -p"$pass" --single-transaction "$db" > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Database exported: $size"
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
    local src="$1"
    local dst="$2"
    local type="$3"

    case "$type" in
        sqlite)
            convert_sqlite "$src" "$dst"
            return $?
            ;;
        postgresql|timescaledb)
            convert_postgresql "$src" "$dst"
            return $?
            ;;
        mysql|mariadb)
            cp "$src" "$dst"
            ok "No conversion needed (already MySQL)"
            return 0
            ;;
        *)
            err "Unknown database type: $type"
            return 1
            ;;
    esac
}

convert_sqlite() {
    local src="$1"
    local dst="$2"

    info "Converting SQLite → MySQL..."

    if [ ! -f "$src" ]; then
        err "Source file not found: $src"
        return 1
    fi

    local dump="$TEMP_DIR/sqlite_dump.sql"

    if ! sqlite3 "$src" .dump > "$dump" 2>/dev/null; then
        err "SQLite dump failed"
        return 1
    fi

    if [ ! -s "$dump" ]; then
        err "SQLite dump is empty"
        return 1
    fi

    python3 << PYEOF
import re

with open("$dump", 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

# Basic conversions
content = re.sub(r'BEGIN TRANSACTION;', 'START TRANSACTION;', content)
content = re.sub(r'PRAGMA.*?;\n?', '', content)
content = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', content, flags=re.I)
content = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', content, flags=re.I)
content = re.sub(r'\bINTEGER\b', 'INT', content, flags=re.I)
content = re.sub(r'\bREAL\b', 'DOUBLE', content, flags=re.I)
content = re.sub(r'\bBLOB\b', 'LONGBLOB', content, flags=re.I)
content = re.sub(r'\bAUTOINCREMENT\b', 'AUTO_INCREMENT', content, flags=re.I)

# Quote conversion
content = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`', content)

# Boolean fix
def fix_bool(m):
    s = m.group(0)
    s = s.replace("'t'", "'1'").replace("'f'", "'0'")
    s = s.replace("'T'", "'1'").replace("'F'", "'0'")
    return s
content = re.sub(r'VALUES\s*\([^)]+\)', fix_bool, content, flags=re.I)

header = """-- Converted from SQLite to MySQL
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""

with open("$dst", 'w', encoding='utf-8') as f:
    f.write(header + content + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")

print("OK")
PYEOF

    if [ $? -eq 0 ] && [ -s "$dst" ]; then
        local size=$(du -h "$dst" | cut -f1)
        ok "Conversion complete: $size"
        return 0
    fi

    err "Conversion failed"
    return 1
}

convert_postgresql() {
    local src="$1"
    local dst="$2"

    info "Converting PostgreSQL → MySQL..."

    if [ ! -f "$src" ]; then
        err "Source file not found: $src"
        return 1
    fi

    python3 << PYEOF
import re

with open("$src", 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

# Remove PostgreSQL-specific commands
patterns_to_remove = [
    r'^SET\s+\w+.*?;$',
    r'^SELECT\s+pg_catalog\..*?;$',
    r'^\\\\connect.*$',
    r'^\\\\.*$',
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

for pattern in patterns_to_remove:
    content = re.sub(pattern, '', content, flags=re.M|re.I)

# Remove CREATE TYPE statements
content = re.sub(r'CREATE TYPE\s+[\w.]+\s+AS\s+ENUM\s*\([^)]+\);', '', content, flags=re.I|re.S)

# Type conversions
type_mappings = [
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

for pattern, replacement in type_mappings:
    content = re.sub(pattern, replacement, content, flags=re.I)

# Boolean conversions
content = re.sub(r"'t'::boolean", "'1'", content, flags=re.I)
content = re.sub(r"'f'::boolean", "'0'", content, flags=re.I)
content = re.sub(r'\btrue\b', "'1'", content, flags=re.I)
content = re.sub(r'\bfalse\b', "'0'", content, flags=re.I)

# Remove type casts
content = re.sub(r'::\w+(\[\])?', '', content)
content = re.sub(r"nextval\('[^']*'[^)]*\)", 'NULL', content, flags=re.I)

# Convert CURRENT_TIMESTAMP
content = re.sub(r'\bCURRENT_TIMESTAMP\b', 'NOW()', content, flags=re.I)

# Quote conversion (PostgreSQL uses " for identifiers, MySQL uses backticks)
content = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`', content)

# Clean up multiple blank lines
content = re.sub(r'\n\s*\n\s*\n+', '\n\n', content)

header = """-- Converted from PostgreSQL to MySQL
-- Generated by MRM Migration Tool
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""

with open("$dst", 'w', encoding='utf-8') as f:
    f.write(header + content + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")

print("OK")
PYEOF

    if [ $? -eq 0 ] && [ -s "$dst" ]; then
        local size=$(du -h "$dst" | cut -f1)
        ok "Conversion complete: $size"
        return 0
    fi

    err "Conversion failed"
    return 1
}

#==============================================================================
# REBECCA FUNCTIONS
#==============================================================================

check_rebecca_installed() {
    [ -d "$REBECCA_DIR" ] && [ -f "$REBECCA_DIR/.env" ]
}

check_rebecca_mysql() {
    if [ -f "$REBECCA_DIR/.env" ]; then
        grep -qiE "mysql|mariadb" "$REBECCA_DIR/.env"
        return $?
    fi
    return 1
}

wait_for_mysql() {
    local timeout="${1:-60}"

    info "Waiting for MySQL to be ready..."

    local i=0
    while [ $i -lt $timeout ]; do
        local cname=$(find_mysql_container)
        if [ -n "$cname" ]; then
            local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
            if docker exec "$cname" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null; then
                ok "MySQL is ready"
                return 0
            fi
        fi
        sleep 3
        i=$((i+3))
        echo -ne "  Waiting... ${i}s\r"
    done

    echo ""
    warn "MySQL may not be fully ready (timeout)"
    return 1
}

import_to_rebecca() {
    local sql_file="$1"

    info "Importing database to Rebecca..."

    if [ ! -f "$sql_file" ]; then
        err "SQL file not found: $sql_file"
        return 1
    fi

    # Get MySQL credentials from Rebecca
    local db=$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' | tr -d "'")
    db="${db:-marzban}"

    # Find MySQL container
    local cname=$(find_mysql_container)
    if [ -z "$cname" ]; then
        err "MySQL container not found"
        echo "Available containers:"
        docker ps --format '  {{.Names}} - {{.Image}}'
        return 1
    fi

    info "  Container: $cname"
    info "  Database: $db"

    # Try import with pipe
    if docker exec -i "$cname" mysql -uroot -p"$pass" "$db" < "$sql_file" 2>/dev/null; then
        ok "Import successful"
        return 0
    fi

    # Try import with file copy
    warn "Pipe import failed, trying file copy..."
    docker cp "$sql_file" "$cname:/tmp/import.sql" 2>/dev/null
    if docker exec "$cname" mysql -uroot -p"$pass" "$db" -e "source /tmp/import.sql" 2>/dev/null; then
        docker exec "$cname" rm -f /tmp/import.sql 2>/dev/null
        ok "Import successful"
        return 0
    fi

    err "Import failed"
    echo ""
    echo "Try manually:"
    echo "  docker exec -i $cname mysql -uroot -p'$pass' $db < $sql_file"
    return 1
}

migrate_configs() {
    info "Migrating configurations..."

    if [ ! -f "$PASARGUARD_DIR/.env" ]; then
        warn "Pasarguard .env not found"
        return 0
    fi

    if [ ! -f "$REBECCA_DIR/.env" ]; then
        warn "Rebecca .env not found"
        return 0
    fi

    # Variables to migrate
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
    for var in "${vars[@]}"; do
        local val=$(grep "^${var}=" "$PASARGUARD_DIR/.env" 2>/dev/null | sed 's/[^=]*=//')
        if [ -n "$val" ]; then
            sed -i "/^${var}=/d" "$REBECCA_DIR/.env" 2>/dev/null
            echo "${var}=${val}" >> "$REBECCA_DIR/.env"
            count=$((count+1))
        fi
    done

    ok "Migrated $count environment variables"

    # Copy certificates
    if [ -d "$PASARGUARD_DATA/certs" ]; then
        info "  Copying certificates..."
        mkdir -p "$REBECCA_DATA/certs"
        cp -r "$PASARGUARD_DATA/certs/"* "$REBECCA_DATA/certs/" 2>/dev/null
        ok "  Certificates copied"
    fi

    # Copy xray config
    if [ -f "$PASARGUARD_DATA/xray_config.json" ]; then
        info "  Copying xray config..."
        mkdir -p "$REBECCA_DATA"
        cp "$PASARGUARD_DATA/xray_config.json" "$REBECCA_DATA/" 2>/dev/null
        ok "  Xray config copied"
    fi

    # Copy templates
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
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            ROLLBACK TO PASARGUARD             ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    if [ ! -f "$BACKUP_ROOT/.last_backup" ]; then
        err "No backup information found"
        safe_pause
        return 1
    fi

    local backup=$(cat "$BACKUP_ROOT/.last_backup")

    if [ ! -d "$backup" ]; then
        err "Backup directory not found: $backup"
        safe_pause
        return 1
    fi

    echo -e "Backup to restore: ${GREEN}$backup${NC}"
    echo ""
    read -p "Type 'rollback' to confirm: " confirm

    if [ "$confirm" != "rollback" ]; then
        info "Rollback cancelled"
        safe_pause
        return 0
    fi

    init_migration

    # Stop Rebecca
    if is_running "$REBECCA_DIR"; then
        stop_panel "$REBECCA_DIR" "Rebecca"
    fi

    # Restore config
    if [ -f "$backup/pasarguard_config.tar.gz" ]; then
        info "Restoring Pasarguard config..."
        rm -rf "$PASARGUARD_DIR"
        mkdir -p "$(dirname "$PASARGUARD_DIR")"
        tar -xzf "$backup/pasarguard_config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")" 2>/dev/null
        ok "Config restored"
    fi

    # Restore data
    if [ -f "$backup/pasarguard_data.tar.gz" ]; then
        info "Restoring Pasarguard data..."
        rm -rf "$PASARGUARD_DATA"
        mkdir -p "$(dirname "$PASARGUARD_DATA")"
        tar -xzf "$backup/pasarguard_data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")" 2>/dev/null
        ok "Data restored"
    fi

    # Start Pasarguard
    if start_panel "$PASARGUARD_DIR" "Pasarguard"; then
        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║           ROLLBACK COMPLETED!                 ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
    else
        err "Failed to start Pasarguard after rollback"
    fi

    cleanup_temp
    safe_pause
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

do_migration() {
    init_migration
    clear

    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    PASARGUARD → REBECCA MIGRATION v9.6        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    # Check dependencies
    if ! check_dependencies; then
        safe_pause
        cleanup_temp
        return 1
    fi

    # Check Pasarguard
    if [ ! -d "$PASARGUARD_DIR" ]; then
        err "Pasarguard not found at $PASARGUARD_DIR"
        safe_pause
        cleanup_temp
        return 1
    fi
    ok "Pasarguard found"

    # Detect database type
    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database type: ${CYAN}$db_type${NC}"

    if [ "$db_type" = "unknown" ]; then
        err "Could not detect database type"
        safe_pause
        cleanup_temp
        return 1
    fi

    # Check Rebecca
    if ! check_rebecca_installed; then
        err "Rebecca not installed at $REBECCA_DIR"
        echo "Install Rebecca first with MySQL database"
        safe_pause
        cleanup_temp
        return 1
    fi
    ok "Rebecca found"

    # Check Rebecca MySQL
    if ! check_rebecca_mysql; then
        err "Rebecca must be configured with MySQL/MariaDB"
        echo "Reinstall Rebecca with: --database mysql"
        safe_pause
        cleanup_temp
        return 1
    fi
    ok "Rebecca MySQL configuration verified"

    echo ""
    echo -e "${YELLOW}This will migrate all data from Pasarguard to Rebecca.${NC}"
    echo -e "${YELLOW}A backup will be created before any changes.${NC}"
    echo ""
    read -p "Type 'migrate' to start: " confirm

    if [ "$confirm" != "migrate" ]; then
        info "Migration cancelled"
        safe_pause
        cleanup_temp
        return 0
    fi

    #==========================================================================
    # STEP 1: BACKUP
    #==========================================================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 1: CREATING BACKUP${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Make sure Pasarguard is running for DB export
    if ! is_running "$PASARGUARD_DIR"; then
        start_panel "$PASARGUARD_DIR" "Pasarguard"
        sleep 5
    fi

    if ! create_backup; then
        err "Backup failed - cannot continue"
        safe_pause
        cleanup_temp
        return 1
    fi

    # Get backup directory from file
    local backup_dir=$(cat "$BACKUP_ROOT/.last_backup" 2>/dev/null)

    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        err "Backup directory not found"
        safe_pause
        cleanup_temp
        return 1
    fi

    #==========================================================================
    # STEP 2: VERIFY SOURCE
    #==========================================================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 2: VERIFYING SOURCE${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local src_file=""
    case "$db_type" in
        sqlite)
            src_file="$backup_dir/database.sqlite3"
            ;;
        *)
            src_file="$backup_dir/database.sql"
            ;;
    esac

    if [ ! -f "$src_file" ] || [ ! -s "$src_file" ]; then
        err "Source database file not found or empty: $src_file"
        safe_pause
        cleanup_temp
        return 1
    fi

    local src_size=$(du -h "$src_file" | cut -f1)
    ok "Source file ready: $src_file ($src_size)"

    #==========================================================================
    # STEP 3: CONVERT
    #==========================================================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 3: CONVERTING DATABASE${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local mysql_file="$TEMP_DIR/mysql_import.sql"

    if ! convert_to_mysql "$src_file" "$mysql_file" "$db_type"; then
        err "Database conversion failed"
        safe_pause
        cleanup_temp
        return 1
    fi

    # Save converted file to backup
    cp "$mysql_file" "$backup_dir/mysql_converted.sql" 2>/dev/null

    #==========================================================================
    # STEP 4: STOP PASARGUARD
    #==========================================================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 4: STOPPING PASARGUARD${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    stop_panel "$PASARGUARD_DIR" "Pasarguard"

    #==========================================================================
    # STEP 5: MIGRATE CONFIGS
    #==========================================================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 5: MIGRATING CONFIGURATIONS${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    migrate_configs

    #==========================================================================
    # STEP 6: START REBECCA & IMPORT
    #==========================================================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 6: IMPORTING TO REBECCA${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if ! is_running "$REBECCA_DIR"; then
        start_panel "$REBECCA_DIR" "Rebecca"
    fi

    wait_for_mysql "$MYSQL_WAIT"

    local import_success=true
    if ! import_to_rebecca "$mysql_file"; then
        import_success=false
    fi

    #==========================================================================
    # STEP 7: RESTART REBECCA
    #==========================================================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 7: RESTARTING REBECCA${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    info "Restarting Rebecca..."
    (cd "$REBECCA_DIR" && docker compose restart) &>/dev/null
    sleep 5
    ok "Rebecca restarted"

    #==========================================================================
    # DONE
    #==========================================================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ "$import_success" = true ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║       MIGRATION COMPLETED SUCCESSFULLY!       ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
    else
        echo -e "${YELLOW}╔═══════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║     MIGRATION COMPLETED WITH WARNINGS         ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "Check the converted SQL file:"
        echo -e "  ${CYAN}$backup_dir/mysql_converted.sql${NC}"
    fi

    echo ""
    echo -e "Backup location: ${CYAN}$backup_dir${NC}"
    echo -e "To rollback: Select option 2 from menu"
    echo ""

    cleanup_temp
    safe_pause
}

#==============================================================================
# STATUS
#==============================================================================

show_status() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    STATUS                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${BOLD}Pasarguard:${NC}"
    if [ -d "$PASARGUARD_DIR" ]; then
        echo -e "  Directory: ${GREEN}$PASARGUARD_DIR${NC}"
        local pg_db=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
        echo -e "  Database:  ${CYAN}$pg_db${NC}"
        if is_running "$PASARGUARD_DIR"; then
            echo -e "  Status:    ${GREEN}Running${NC}"
        else
            echo -e "  Status:    ${YELLOW}Stopped${NC}"
        fi
    else
        echo -e "  ${YELLOW}Not installed${NC}"
    fi

    echo ""
    echo -e "${BOLD}Rebecca:${NC}"
    if [ -d "$REBECCA_DIR" ]; then
        echo -e "  Directory: ${GREEN}$REBECCA_DIR${NC}"
        if check_rebecca_mysql; then
            echo -e "  Database:  ${CYAN}MySQL${NC}"
        else
            echo -e "  Database:  ${YELLOW}Not MySQL${NC}"
        fi
        if is_running "$REBECCA_DIR"; then
            echo -e "  Status:    ${GREEN}Running${NC}"
        else
            echo -e "  Status:    ${YELLOW}Stopped${NC}"
        fi
    else
        echo -e "  ${YELLOW}Not installed${NC}"
    fi

    echo ""
    echo -e "${BOLD}Last Backup:${NC}"
    if [ -f "$BACKUP_ROOT/.last_backup" ]; then
        echo -e "  $(cat "$BACKUP_ROOT/.last_backup")"
    else
        echo -e "  ${YELLOW}None${NC}"
    fi

    safe_pause
}

#==============================================================================
# VIEW BACKUPS
#==============================================================================

view_backups() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                   BACKUPS                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    if [ -d "$BACKUP_ROOT" ]; then
        ls -lh "$BACKUP_ROOT" 2>/dev/null | grep -v "^total" | grep -v ".last_backup" || echo "No backups found"
    else
        echo "Backup directory does not exist"
    fi

    safe_pause
}

#==============================================================================
# VIEW LOG
#==============================================================================

view_log() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              LOG (last 50 lines)              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    if [ -f "$LOG_FILE" ]; then
        tail -50 "$LOG_FILE"
    else
        echo "No log file found"
    fi

    safe_pause
}

#==============================================================================
# MAIN MENU
#==============================================================================

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔═══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║       MRM MIGRATION TOOL v9.6                 ║${NC}"
        echo -e "${BLUE}║       Pasarguard → Rebecca                    ║${NC}"
        echo -e "${BLUE}╚═══════════════════════════════════════════════╝${NC}"
        echo ""
        echo " 1) Migrate Pasarguard → Rebecca"
        echo " 2) Rollback to Pasarguard"
        echo " 3) Show Status"
        echo " 4) View Backups"
        echo " 5) View Log"
        echo " 0) Exit"
        echo ""
        read -p "Select option: " option

        case "$option" in
            1) do_migration ;;
            2) do_rollback ;;
            3) show_status ;;
            4) view_backups ;;
            5) view_log ;;
            0) echo "Goodbye!"; exit 0 ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

#==============================================================================
# ENTRY POINT
#==============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi