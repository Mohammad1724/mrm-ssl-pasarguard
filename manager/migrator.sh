#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 5.0 (Final - Based on Official Documentation)
#
# Pasarguard Docs:
#   - Install: /opt/pasarguard
#   - Data: /var/lib/pasarguard
#   - CLI: pasarguard cli
#   - Databases: TimescaleDB, PostgreSQL, MySQL, MariaDB, SQLite
#   - Async Drivers: asyncpg, asyncmy, aiosqlite
#
# Rebecca Docs:
#   - Install: /opt/rebecca
#   - Data: /var/lib/rebecca
#   - CLI: rebecca cli
#   - Databases: MySQL, MariaDB, SQLite
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

# Pasarguard Paths (from official docs)
PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"

# Rebecca Paths (from official docs)
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"

# Install URLs (official)
REBECCA_INSTALL_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"

# Backup & Logging
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
LOG_FILE="${LOG_FILE:-/var/log/mrm_migration.log}"

# Temp directory
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
# HELPER FUNCTIONS
#==============================================================================

create_temp_dir() {
    TEMP_DIR=$(mktemp -d /tmp/mrm-migration-XXXXXX)
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
        echo "========================================"
        echo "Migration Started: $(date)"
        echo "Temp Dir: $TEMP_DIR"
        echo "========================================"
    } >> "$LOG_FILE"
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
# DEPENDENCY CHECKS
#==============================================================================

check_dependencies() {
    info "Checking dependencies..."
    
    local missing=()
    local deps="docker curl tar gzip python3 sqlite3"
    
    for cmd in $deps; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing commands: ${missing[*]}"
        echo "Install with: apt update && apt install -y ${missing[*]}"
        return 1
    fi
    
    if ! docker info &>/dev/null; then
        err "Docker is not running!"
        return 1
    fi
    
    ok "All dependencies OK"
    return 0
}

#==============================================================================
# DATABASE DETECTION (Updated for Pasarguard async drivers)
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
        db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL\s*=" "$env_file" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'")
        
        # Pasarguard uses async drivers
        if echo "$db_url" | grep -qiE "postgresql\+asyncpg|timescale"; then
            echo "timescaledb"
            return 0
        elif echo "$db_url" | grep -qiE "postgresql"; then
            echo "postgresql"
            return 0
        elif echo "$db_url" | grep -qiE "mysql\+asyncmy|mysql"; then
            echo "mysql"
            return 0
        elif echo "$db_url" | grep -qiE "mariadb"; then
            echo "mariadb"
            return 0
        elif echo "$db_url" | grep -qiE "sqlite\+aiosqlite|sqlite"; then
            echo "sqlite"
            return 0
        fi
    fi
    
    # Fallback: check for SQLite file
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
    
    if [ ! -f "$env_file" ]; then
        return 1
    fi
    
    # Extract from SQLALCHEMY_DATABASE_URL
    local db_url
    db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL\s*=" "$env_file" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'")
    
    # Parse URL: protocol://user:pass@host:port/database
    # Example: postgresql+asyncpg://user:password@localhost/pasarguard
    
    DB_USER=$(echo "$db_url" | sed -n 's|.*://\([^:]*\):.*|\1|p')
    DB_PASS=$(echo "$db_url" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
    DB_HOST=$(echo "$db_url" | sed -n 's|.*@\([^:/]*\).*|\1|p')
    DB_NAME=$(echo "$db_url" | sed -n 's|.*/\([^?]*\).*|\1|p')
    
    # Defaults
    [ -z "$DB_HOST" ] && DB_HOST="localhost"
    [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
    
    export DB_USER DB_PASS DB_HOST DB_NAME
}

#==============================================================================
# CONTAINER MANAGEMENT
#==============================================================================

find_panel_container() {
    local project_dir="$1"
    
    if [ ! -d "$project_dir" ]; then
        return 1
    fi
    
    local container_ids
    container_ids=$(cd "$project_dir" && docker compose ps -q 2>/dev/null)
    
    if [ -z "$container_ids" ]; then
        return 1
    fi
    
    # Return first container (usually the panel)
    echo "$container_ids" | head -1
}

find_db_container() {
    local project_dir="$1"
    local db_type="$2"
    
    if [ ! -d "$project_dir" ]; then
        return 1
    fi
    
    local container_ids
    container_ids=$(cd "$project_dir" && docker compose ps -q 2>/dev/null)
    
    if [ -z "$container_ids" ]; then
        return 1
    fi
    
    local cid
    for cid in $container_ids; do
        case "$db_type" in
            "mysql"|"mariadb")
                if docker exec "$cid" mysql --version &>/dev/null 2>&1; then
                    echo "$cid"
                    return 0
                fi
                ;;
            "postgresql"|"timescaledb")
                if docker exec "$cid" psql --version &>/dev/null 2>&1; then
                    echo "$cid"
                    return 0
                fi
                ;;
        esac
    done
    
    return 1
}

is_container_running() {
    local dir="$1"
    [ -d "$dir" ] && (cd "$dir" && docker compose ps 2>/dev/null | grep -qE "Up|running")
}

start_panel() {
    local dir="$1"
    local name="$2"
    
    info "Starting $name..."
    
    if [ ! -d "$dir" ]; then
        err "$name directory not found: $dir"
        return 1
    fi
    
    (cd "$dir" && docker compose up -d 2>&1) | tee -a "$LOG_FILE"
    
    local elapsed=0
    while [ $elapsed -lt $CONTAINER_TIMEOUT ]; do
        if is_container_running "$dir"; then
            ok "$name started"
            sleep 5
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
        echo -ne "  Waiting... ${elapsed}s\r"
    done
    echo ""
    
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
    (cd "$dir" && docker compose down 2>&1) | tee -a "$LOG_FILE"
    sleep 3
    ok "$name stopped"
}

#==============================================================================
# BACKUP FUNCTIONS
#==============================================================================

create_backup() {
    info "Creating full backup of Pasarguard..."
    
    local ts=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$backup_dir"
    
    # Save for rollback
    echo "$backup_dir" > "$BACKUP_ROOT/.last_backup"
    
    # Backup config
    if [ -d "$PASARGUARD_DIR" ]; then
        info "  Backing up config..."
        tar -czf "$backup_dir/pasarguard_config.tar.gz" \
            -C "$(dirname "$PASARGUARD_DIR")" \
            "$(basename "$PASARGUARD_DIR")" 2>/dev/null && ok "  Config saved"
    fi
    
    # Backup data
    if [ -d "$PASARGUARD_DATA" ]; then
        info "  Backing up data (may take time)..."
        tar -czf "$backup_dir/pasarguard_data.tar.gz" \
            -C "$(dirname "$PASARGUARD_DATA")" \
            "$(basename "$PASARGUARD_DATA")" 2>/dev/null && ok "  Data saved"
    fi
    
    # Detect database type
    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$backup_dir/db_type.txt"
    
    # Export database
    info "  Exporting database ($db_type)..."
    export_database "$db_type" "$backup_dir"
    
    # Save metadata
    cat > "$backup_dir/metadata.txt" << EOF
Backup Created: $(date)
Panel: Pasarguard
Config: $PASARGUARD_DIR
Data: $PASARGUARD_DATA
Database: $db_type
Hostname: $(hostname)
EOF
    
    ok "Backup complete: $backup_dir"
    echo "$backup_dir"
}

export_database() {
    local db_type="$1"
    local backup_dir="$2"
    
    # Ensure Pasarguard is running
    if ! is_container_running "$PASARGUARD_DIR"; then
        start_panel "$PASARGUARD_DIR" "Pasarguard" || return 1
        sleep 10
    fi
    
    case "$db_type" in
        "sqlite")
            if [ -f "$PASARGUARD_DATA/db.sqlite3" ]; then
                cp "$PASARGUARD_DATA/db.sqlite3" "$backup_dir/database.sqlite3"
                ok "  SQLite exported"
            fi
            ;;
        "timescaledb"|"postgresql")
            export_postgresql "$backup_dir/database.sql"
            ;;
        "mysql"|"mariadb")
            export_mysql "$backup_dir/database.sql"
            ;;
    esac
}

export_postgresql() {
    local output_file="$1"
    
    local pg_cid=$(find_db_container "$PASARGUARD_DIR" "postgresql")
    
    if [ -z "$pg_cid" ]; then
        err "  PostgreSQL container not found"
        return 1
    fi
    
    get_db_credentials "$PASARGUARD_DIR"
    
    local user="${DB_USER:-postgres}"
    local db="${DB_NAME:-pasarguard}"
    
    if docker exec "$pg_cid" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        ok "  PostgreSQL/TimescaleDB exported"
        return 0
    fi
    
    err "  pg_dump failed"
    return 1
}

export_mysql() {
    local output_file="$1"
    
    local mysql_cid=$(find_db_container "$PASARGUARD_DIR" "mysql")
    
    if [ -z "$mysql_cid" ]; then
        err "  MySQL container not found"
        return 1
    fi
    
    get_db_credentials "$PASARGUARD_DIR"
    
    # Also check env vars
    local pass="${DB_PASS}"
    if [ -z "$pass" ] && [ -f "$PASARGUARD_DIR/.env" ]; then
        pass=$(grep -E "^MYSQL_ROOT_PASSWORD=" "$PASARGUARD_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
    
    local db="${DB_NAME:-pasarguard}"
    
    if docker exec "$mysql_cid" mysqldump -uroot -p"$pass" --single-transaction "$db" > "$output_file" 2>/dev/null; then
        ok "  MySQL exported"
        return 0
    fi
    
    err "  mysqldump failed"
    return 1
}

#==============================================================================
# DATABASE CONVERSION
#==============================================================================

convert_to_mysql() {
    local source_file="$1"
    local output_file="$2"
    local source_type="$3"
    
    case "$source_type" in
        "sqlite")
            convert_sqlite_to_mysql "$source_file" "$output_file"
            ;;
        "postgresql"|"timescaledb")
            convert_postgresql_to_mysql "$source_file" "$output_file"
            ;;
        "mysql"|"mariadb")
            cp "$source_file" "$output_file"
            ok "No conversion needed (already MySQL/MariaDB)"
            ;;
        *)
            err "Unknown source type: $source_type"
            return 1
            ;;
    esac
}

convert_sqlite_to_mysql() {
    local sqlite_file="$1"
    local output_file="$2"
    
    info "Converting SQLite → MySQL..."
    
    if [ ! -f "$sqlite_file" ]; then
        err "SQLite file not found"
        return 1
    fi
    
    # Dump SQLite
    local temp_sql="$TEMP_DIR/sqlite_dump.sql"
    sqlite3 "$sqlite_file" .dump > "$temp_sql" 2>/dev/null
    
    if [ ! -s "$temp_sql" ]; then
        err "SQLite dump failed or empty"
        return 1
    fi
    
    # Convert
    export INPUT_SQL="$temp_sql"
    export OUTPUT_SQL="$output_file"
    
    python3 << 'PYEOF'
import re
import os

input_file = os.environ['INPUT_SQL']
output_file = os.environ['OUTPUT_SQL']

with open(input_file, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

# Conversions
replacements = [
    (r'BEGIN TRANSACTION;', 'START TRANSACTION;'),
    (r'PRAGMA.*?;\n?', ''),
    (r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY'),
    (r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY'),
    (r'\bINTEGER\b', 'INT'),
    (r'\bREAL\b', 'DOUBLE'),
    (r'\bBLOB\b', 'LONGBLOB'),
    (r'\bAUTOINCREMENT\b', 'AUTO_INCREMENT'),
    (r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'`\1`'),
]

for pattern, replacement in replacements:
    content = re.sub(pattern, replacement, content, flags=re.IGNORECASE)

# Fix booleans in INSERT
def fix_bool(m):
    return m.group(0).replace("'t'", "'1'").replace("'f'", "'0'")
content = re.sub(r'INSERT INTO.*?;', fix_bool, content, flags=re.IGNORECASE | re.DOTALL)

header = """-- SQLite to MySQL Conversion
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
SET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';

"""
footer = "\n\nSET FOREIGN_KEY_CHECKS = 1;\n"

with open(output_file, 'w', encoding='utf-8') as f:
    f.write(header + content + footer)

print("OK")
PYEOF
    
    if [ $? -eq 0 ] && [ -s "$output_file" ]; then
        ok "Conversion complete"
        return 0
    fi
    
    err "Conversion failed"
    return 1
}

convert_postgresql_to_mysql() {
    local pg_file="$1"
    local output_file="$2"
    
    info "Converting PostgreSQL/TimescaleDB → MySQL..."
    
    if [ ! -f "$pg_file" ]; then
        err "PostgreSQL dump not found"
        return 1
    fi
    
    export INPUT_SQL="$pg_file"
    export OUTPUT_SQL="$output_file"
    
    python3 << 'PYEOF'
import re
import os

input_file = os.environ['INPUT_SQL']
output_file = os.environ['OUTPUT_SQL']

with open(input_file, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

# Remove PostgreSQL specific
remove_patterns = [
    r'^SET\s+\w+\s*=.*?;$',
    r'^SELECT\s+pg_catalog\..*?;$',
    r'^\\connect.*$',
    r'^CREATE\s+EXTENSION.*?;$',
    r'^COMMENT\s+ON.*?;$',
    r'^ALTER\s+TABLE.*?OWNER\s+TO.*?;$',
    r'^GRANT\s+.*?;$',
    r'^REVOKE\s+.*?;$',
    r'^CREATE\s+SCHEMA.*?;$',
    r'^CREATE\s+SEQUENCE.*?;$',
    r'^ALTER\s+SEQUENCE.*?;$',
    # TimescaleDB specific
    r'^SELECT\s+create_hypertable.*?;$',
    r'^SELECT\s+set_chunk_time_interval.*?;$',
]

for pattern in remove_patterns:
    content = re.sub(pattern, '', content, flags=re.MULTILINE | re.IGNORECASE)

# Type conversions
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

for pattern, replacement in type_conv:
    content = re.sub(pattern, replacement, content, flags=re.IGNORECASE)

# Booleans
content = re.sub(r"'t'::boolean", "'1'", content)
content = re.sub(r"'f'::boolean", "'0'", content)

# Remove casts
content = re.sub(r'::\w+(\[\])?', '', content)

# Sequences
content = re.sub(r"nextval\('[^']*'(::\w+)?\)", 'NULL', content, flags=re.IGNORECASE)

# CURRENT_TIMESTAMP
content = re.sub(r'\bCURRENT_TIMESTAMP\b', 'NOW()', content, flags=re.IGNORECASE)

# Identifiers
content = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'`\1`', content)

# Clean empty lines
content = re.sub(r'\n\s*\n\s*\n+', '\n\n', content)

header = """-- PostgreSQL/TimescaleDB to MySQL Conversion
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
SET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';

"""
footer = "\n\nSET FOREIGN_KEY_CHECKS = 1;\n"

with open(output_file, 'w', encoding='utf-8') as f:
    f.write(header + content + footer)

print("OK")
PYEOF
    
    if [ $? -eq 0 ] && [ -s "$output_file" ]; then
        ok "Conversion complete"
        return 0
    fi
    
    err "Conversion failed"
    return 1
}

#==============================================================================
# REBECCA CHECKS
#==============================================================================

check_rebecca_installed() {
    [ -d "$REBECCA_DIR" ] && [ -f "$REBECCA_DIR/.env" ]
}

check_rebecca_mysql() {
    [ -f "$REBECCA_DIR/.env" ] && grep -qiE "(mysql|mariadb)" "$REBECCA_DIR/.env" 2>/dev/null
}

install_rebecca_prompt() {
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}   Rebecca is not installed                    ${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Installation command:"
    echo -e "  ${CYAN}sudo bash -c \"\$(curl -sL $REBECCA_INSTALL_URL)\" @ install --database mysql${NC}"
    echo ""
    
    read -p "Install Rebecca now? (y/n): " install_now
    
    if [ "$install_now" = "y" ]; then
        info "Downloading Rebecca installer..."
        if curl -sL "$REBECCA_INSTALL_URL" -o /tmp/rebecca_install.sh; then
            chmod +x /tmp/rebecca_install.sh
            bash /tmp/rebecca_install.sh install --database mysql
            rm -f /tmp/rebecca_install.sh
            
            if check_rebecca_installed; then
                ok "Rebecca installed"
                return 0
            fi
        fi
        err "Installation failed"
        return 1
    fi
    
    return 1
}

#==============================================================================
# IMPORT TO REBECCA
#==============================================================================

wait_for_mysql() {
    local timeout="$1"
    info "Waiting for MySQL..."
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local mysql_cid=$(find_db_container "$REBECCA_DIR" "mysql")
        if [ -n "$mysql_cid" ]; then
            local pass=$(grep -E "^MYSQL_ROOT_PASSWORD=" "$REBECCA_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
            if docker exec "$mysql_cid" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null; then
                ok "MySQL ready"
                return 0
            fi
        fi
        sleep 3
        elapsed=$((elapsed + 3))
        echo -ne "  Waiting... ${elapsed}s\r"
    done
    echo ""
    warn "MySQL may not be ready"
    return 1
}

import_to_rebecca() {
    local sql_file="$1"
    
    info "Importing to Rebecca MySQL..."
    
    if [ ! -f "$sql_file" ]; then
        err "SQL file not found"
        return 1
    fi
    
    # Get credentials
    local db_name=$(grep -E "^MYSQL_DATABASE=" "$REBECCA_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    local db_pass=$(grep -E "^MYSQL_ROOT_PASSWORD=" "$REBECCA_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    db_name="${db_name:-marzban}"
    
    local mysql_cid=$(find_db_container "$REBECCA_DIR" "mysql")
    
    if [ -z "$mysql_cid" ]; then
        err "MySQL container not found"
        return 1
    fi
    
    info "  Database: $db_name"
    
    # Copy and import
    docker cp "$sql_file" "$mysql_cid:/tmp/import.sql" 2>/dev/null
    
    if docker exec "$mysql_cid" mysql -uroot -p"$db_pass" "$db_name" -e "source /tmp/import.sql" 2>/dev/null; then
        docker exec "$mysql_cid" rm -f /tmp/import.sql 2>/dev/null
        ok "Import successful"
        return 0
    fi
    
    # Alternative
    warn "Trying alternative method..."
    if docker exec -i "$mysql_cid" mysql -uroot -p"$db_pass" "$db_name" < "$sql_file" 2>/dev/null; then
        ok "Import successful (alternative)"
        return 0
    fi
    
    err "Import failed"
    return 1
}

#==============================================================================
# MIGRATE CONFIGURATIONS
#==============================================================================

migrate_configs() {
    info "Migrating configurations..."
    
    if [ ! -f "$PASARGUARD_DIR/.env" ] || [ ! -f "$REBECCA_DIR/.env" ]; then
        warn "Config files missing"
        return 0
    fi
    
    # Variables to migrate (common between both panels)
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
        "XRAY_FALLBACKS_INBOUND_TAG"
        "XRAY_EXCLUDE_INBOUND_TAGS"
        "CUSTOM_TEMPLATES_DIRECTORY"
        "SUBSCRIPTION_PAGE_TEMPLATE"
    )
    
    local count=0
    for var in "${vars[@]}"; do
        local value=$(grep "^${var}=" "$PASARGUARD_DIR/.env" 2>/dev/null | cut -d'=' -f2-)
        if [ -n "$value" ]; then
            sed -i "/^${var}=/d" "$REBECCA_DIR/.env" 2>/dev/null
            echo "${var}=${value}" >> "$REBECCA_DIR/.env"
            count=$((count + 1))
        fi
    done
    
    ok "Migrated $count variables"
    
    # Copy certificates
    if [ -d "$PASARGUARD_DATA/certs" ]; then
        info "  Copying certificates..."
        mkdir -p "$REBECCA_DATA/certs"
        cp -r "$PASARGUARD_DATA/certs/"* "$REBECCA_DATA/certs/" 2>/dev/null
        ok "  Certificates copied"
    fi
    
    # Copy Xray config
    if [ -f "$PASARGUARD_DATA/xray_config.json" ]; then
        info "  Copying Xray config..."
        mkdir -p "$REBECCA_DATA"
        cp "$PASARGUARD_DATA/xray_config.json" "$REBECCA_DATA/" 2>/dev/null
        ok "  Xray config copied"
    fi
    
    # Copy templates (note: Pasarguard uses xray/, older versions used v2ray/)
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
    
    if [ ! -f "$BACKUP_ROOT/.last_backup" ]; then
        err "No backup found"
        ls -la "$BACKUP_ROOT" 2>/dev/null || echo "(empty)"
        safe_pause
        return 1
    fi
    
    local backup_dir=$(cat "$BACKUP_ROOT/.last_backup")
    
    if [ ! -d "$backup_dir" ]; then
        err "Backup missing: $backup_dir"
        safe_pause
        return 1
    fi
    
    echo -e "Backup: ${GREEN}$backup_dir${NC}"
    [ -f "$backup_dir/metadata.txt" ] && cat "$backup_dir/metadata.txt"
    echo ""
    
    echo -e "${RED}This will stop Rebecca and restore Pasarguard!${NC}"
    read -p "Type 'rollback' to confirm: " confirm
    
    if [ "$confirm" != "rollback" ]; then
        info "Cancelled"
        safe_pause
        return 0
    fi
    
    echo ""
    init_migration
    
    # Stop Rebecca
    [ -d "$REBECCA_DIR" ] && is_container_running "$REBECCA_DIR" && stop_panel "$REBECCA_DIR" "Rebecca"
    
    # Restore config
    if [ -f "$backup_dir/pasarguard_config.tar.gz" ]; then
        info "Restoring config..."
        rm -rf "$PASARGUARD_DIR" 2>/dev/null
        mkdir -p "$(dirname "$PASARGUARD_DIR")"
        tar -xzf "$backup_dir/pasarguard_config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")" 2>/dev/null
        ok "Config restored"
    fi
    
    # Restore data
    if [ -f "$backup_dir/pasarguard_data.tar.gz" ]; then
        info "Restoring data..."
        rm -rf "$PASARGUARD_DATA" 2>/dev/null
        mkdir -p "$(dirname "$PASARGUARD_DATA")"
        tar -xzf "$backup_dir/pasarguard_data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")" 2>/dev/null
        ok "Data restored"
    fi
    
    # Start Pasarguard
    info "Starting Pasarguard..."
    if start_panel "$PASARGUARD_DIR" "Pasarguard"; then
        echo -e "${GREEN}Rollback complete!${NC}"
    else
        err "Start failed. Try: cd $PASARGUARD_DIR && docker compose up -d"
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
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}      PASARGUARD → REBECCA MIGRATION WIZARD        ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Checks
    check_dependencies || { safe_pause; cleanup_temp; return 1; }
    echo ""
    
    # Check Pasarguard
    if [ ! -d "$PASARGUARD_DIR" ]; then
        err "Pasarguard not found: $PASARGUARD_DIR"
        safe_pause; cleanup_temp; return 1
    fi
    ok "Pasarguard found"
    
    # Detect database
    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database: ${CYAN}$db_type${NC}"
    
    if [ "$db_type" = "unknown" ]; then
        err "Unknown database type"
        safe_pause; cleanup_temp; return 1
    fi
    
    # Check Rebecca
    if ! check_rebecca_installed; then
        install_rebecca_prompt || { safe_pause; cleanup_temp; return 1; }
    else
        ok "Rebecca found"
    fi
    
    if ! check_rebecca_mysql; then
        err "Rebecca not using MySQL. Reinstall with --database mysql"
        safe_pause; cleanup_temp; return 1
    fi
    ok "Rebecca MySQL verified"
    
    # Confirmation
    echo ""
    echo -e "${BOLD}Migration: ${CYAN}Pasarguard ($db_type)${NC} → ${CYAN}Rebecca (MySQL)${NC}"
    echo ""
    echo -e "${RED}⚠ This will stop Pasarguard and migrate all data ⚠${NC}"
    read -p "Type 'migrate' to confirm: " confirm
    
    if [ "$confirm" != "migrate" ]; then
        info "Cancelled"
        safe_pause; cleanup_temp; return 0
    fi
    
    echo ""
    
    # Step 1: Backup
    echo -e "${BOLD}[1/6] Backup${NC}"
    local backup_dir=$(create_backup)
    [ -z "$backup_dir" ] && { err "Backup failed"; safe_pause; cleanup_temp; return 1; }
    echo ""
    
    # Step 2: Get source
    echo -e "${BOLD}[2/6] Prepare Database${NC}"
    local source_file=""
    
    case "$db_type" in
        "sqlite")
            source_file="$backup_dir/database.sqlite3"
            [ ! -f "$source_file" ] && source_file="$PASARGUARD_DATA/db.sqlite3"
            ;;
        *)
            source_file="$backup_dir/database.sql"
            ;;
    esac
    
    [ ! -f "$source_file" ] && { err "Source not found"; safe_pause; cleanup_temp; return 1; }
    ok "Source ready: $source_file"
    echo ""
    
    # Step 3: Convert
    echo -e "${BOLD}[3/6] Convert Database${NC}"
    local mysql_file="$TEMP_DIR/mysql_import.sql"
    convert_to_mysql "$source_file" "$mysql_file" "$db_type" || { safe_pause; cleanup_temp; return 1; }
    cp "$mysql_file" "$backup_dir/mysql_converted.sql" 2>/dev/null
    echo ""
    
    # Step 4: Stop Pasarguard
    echo -e "${BOLD}[4/6] Stop Pasarguard${NC}"
    stop_panel "$PASARGUARD_DIR" "Pasarguard"
    echo ""
    
    # Step 5: Migrate configs
    echo -e "${BOLD}[5/6] Migrate Configs${NC}"
    migrate_configs
    echo ""
    
    # Step 6: Import
    echo -e "${BOLD}[6/6] Import to Rebecca${NC}"
    is_container_running "$REBECCA_DIR" || start_panel "$REBECCA_DIR" "Rebecca"
    wait_for_mysql "$MYSQL_WAIT"
    
    local import_ok=true
    import_to_rebecca "$mysql_file" || import_ok=false
    
    # Restart
    info "Restarting Rebecca..."
    (cd "$REBECCA_DIR" && docker compose restart 2>/dev/null)
    sleep 5
    
    # Done
    echo ""
    if [ "$import_ok" = true ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}        MIGRATION COMPLETED SUCCESSFULLY!           ${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${YELLOW}Migration completed with warnings${NC}"
        echo "SQL file: $backup_dir/mysql_converted.sql"
    fi
    
    echo ""
    echo -e "Backup: ${CYAN}$backup_dir${NC}"
    echo -e "Dashboard: ${CYAN}https://YOUR_DOMAIN:8000/dashboard/${NC}"
    echo "Login with your existing credentials."
    
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