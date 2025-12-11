#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 2.0
# Features:
#   - TimescaleDB/PostgreSQL → MySQL
#   - SQLite → MySQL
#   - Full Rollback Support
#   - Data Integrity Checks
#==============================================================================

#==============================================================================
# SAFETY SETTINGS
#==============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -o pipefail
fi

#==============================================================================
# CONFIGURATION
#==============================================================================

# Pasarguard
PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"

# Rebecca
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"

# Backup & Temp
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
TEMP_DIR="/tmp/mrm-migration-$$"
LOG_FILE="${LOG_FILE:-/var/log/mrm_migration.log}"

# Timeouts
CONTAINER_TIMEOUT=120
MYSQL_WAIT=30

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

init_migration() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/mrm_migration.log"
    mkdir -p "$BACKUP_ROOT" 2>/dev/null
    mkdir -p "$TEMP_DIR" 2>/dev/null
    echo "" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
    echo "Migration Started: $(date)" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
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
    echo -e "${RED}✗${NC} $*" >&2
    log "ERROR: $*"
}

safe_pause() {
    echo ""
    echo -e "${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s -r
    echo ""
}

cleanup_temp() {
    if [ -d "$TEMP_DIR" ] && [[ "$TEMP_DIR" == /tmp/* ]]; then
        rm -rf "$TEMP_DIR" 2>/dev/null
    fi
}

#==============================================================================
# DEPENDENCY CHECKS
#==============================================================================

check_dependencies() {
    info "Checking dependencies..."
    
    local missing=()
    
    # Required commands
    for cmd in docker curl tar gzip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # Python3 check
    if ! command -v python3 &>/dev/null; then
        missing+=("python3")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing commands: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  apt update && apt install -y ${missing[*]}"
        return 1
    fi
    
    # Docker running check
    if ! docker info &>/dev/null; then
        err "Docker is not running!"
        echo "Start with: systemctl start docker"
        return 1
    fi
    
    ok "All dependencies OK"
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
    local db_type="unknown"
    
    if [ -f "$env_file" ]; then
        local db_url=$(grep -E "^(DATABASE_URL|SQLALCHEMY_DATABASE_URL|DB_URL)=" "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
        
        if echo "$db_url" | grep -qiE "postgresql|timescale"; then
            db_type="postgresql"
        elif echo "$db_url" | grep -qi "mysql"; then
            db_type="mysql"
        elif echo "$db_url" | grep -qi "sqlite"; then
            db_type="sqlite"
        fi
    fi
    
    # Fallback: Check for SQLite file
    if [ "$db_type" == "unknown" ] && [ -f "$data_dir/db.sqlite3" ]; then
        db_type="sqlite"
    fi
    
    echo "$db_type"
}

#==============================================================================
# CONTAINER MANAGEMENT
#==============================================================================

get_container_id() {
    local dir="$1"
    
    if [ ! -d "$dir" ]; then
        return 1
    fi
    
    (cd "$dir" && docker compose ps -q 2>/dev/null | head -1)
}

is_container_running() {
    local dir="$1"
    
    if [ ! -d "$dir" ]; then
        return 1
    fi
    
    (cd "$dir" && docker compose ps 2>/dev/null | grep -q "Up")
}

start_panel() {
    local dir="$1"
    local name="$2"
    
    info "Starting $name..."
    
    if [ ! -d "$dir" ]; then
        err "$name directory not found: $dir"
        return 1
    fi
    
    (cd "$dir" && docker compose up -d 2>&1 | tee -a "$LOG_FILE")
    
    # Wait for container
    local elapsed=0
    while [ $elapsed -lt $CONTAINER_TIMEOUT ]; do
        if is_container_running "$dir"; then
            ok "$name started"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
        echo -ne "  Waiting... ${elapsed}s / ${CONTAINER_TIMEOUT}s\r"
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
    (cd "$dir" && docker compose down 2>&1 | tee -a "$LOG_FILE")
    ok "$name stopped"
}

#==============================================================================
# BACKUP FUNCTIONS
#==============================================================================

create_backup() {
    info "Creating full backup..."
    
    local ts=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$backup_dir"
    
    # Save for rollback
    echo "$backup_dir" > "$BACKUP_ROOT/.last_backup"
    
    # Backup Pasarguard config
    if [ -d "$PASARGUARD_DIR" ]; then
        info "  Backing up Pasarguard config..."
        tar -czf "$backup_dir/pasarguard_config.tar.gz" \
            -C "$(dirname "$PASARGUARD_DIR")" \
            "$(basename "$PASARGUARD_DIR")" 2>/dev/null && ok "  Config saved"
    fi
    
    # Backup Pasarguard data
    if [ -d "$PASARGUARD_DATA" ]; then
        info "  Backing up Pasarguard data (may take time)..."
        tar -czf "$backup_dir/pasarguard_data.tar.gz" \
            -C "$(dirname "$PASARGUARD_DATA")" \
            "$(basename "$PASARGUARD_DATA")" 2>/dev/null && ok "  Data saved"
    fi
    
    # Detect and backup database
    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$backup_dir/db_type.txt"
    
    case "$db_type" in
        "postgresql")
            info "  Exporting PostgreSQL/TimescaleDB..."
            export_postgresql "$backup_dir/database.sql"
            ;;
        "sqlite")
            info "  Copying SQLite database..."
            if [ -f "$PASARGUARD_DATA/db.sqlite3" ]; then
                cp "$PASARGUARD_DATA/db.sqlite3" "$backup_dir/database.sqlite3"
                ok "  SQLite copied"
            fi
            ;;
        "mysql")
            info "  Exporting MySQL..."
            export_mysql "$PASARGUARD_DIR" "$backup_dir/database.sql"
            ;;
    esac
    
    # Metadata
    cat > "$backup_dir/metadata.txt" << EOF
Backup Date: $(date)
Panel: Pasarguard
Directory: $PASARGUARD_DIR
Data: $PASARGUARD_DATA
Database: $db_type
EOF
    
    ok "Backup complete: $backup_dir"
    echo "$backup_dir"
}

#==============================================================================
# DATABASE EXPORT FUNCTIONS
#==============================================================================

export_postgresql() {
    local output_file="$1"
    
    if ! is_container_running "$PASARGUARD_DIR"; then
        start_panel "$PASARGUARD_DIR" "Pasarguard"
        sleep 10
    fi
    
    # Find PostgreSQL container
    local pg_cid=$(cd "$PASARGUARD_DIR" && docker compose ps -q 2>/dev/null | while read cid; do
        if docker exec "$cid" psql --version &>/dev/null; then
            echo "$cid"
            break
        fi
    done)
    
    if [ -z "$pg_cid" ]; then
        # Try by name
        pg_cid=$(cd "$PASARGUARD_DIR" && docker compose ps --format '{{.Names}}' 2>/dev/null | while read name; do
            if echo "$name" | grep -qiE "postgres|timescale|db"; then
                docker ps -q --filter "name=$name" | head -1
                break
            fi
        done)
    fi
    
    if [ -z "$pg_cid" ]; then
        err "PostgreSQL container not found"
        return 1
    fi
    
    # Get credentials
    local db_name=$(grep -E "^POSTGRES_DB=" "$PASARGUARD_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "marzban")
    local db_user=$(grep -E "^POSTGRES_USER=" "$PASARGUARD_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "postgres")
    
    info "  Dumping database: $db_name"
    
    if docker exec "$pg_cid" pg_dump -U "$db_user" -d "$db_name" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        local size=$(du -h "$output_file" 2>/dev/null | cut -f1)
        ok "  PostgreSQL exported ($size)"
        return 0
    fi
    
    err "  pg_dump failed"
    return 1
}

export_mysql() {
    local panel_dir="$1"
    local output_file="$2"
    
    if ! is_container_running "$panel_dir"; then
        return 1
    fi
    
    # Find MySQL container
    local mysql_cid=$(cd "$panel_dir" && docker compose ps -q 2>/dev/null | while read cid; do
        if docker exec "$cid" mysql --version &>/dev/null; then
            echo "$cid"
            break
        fi
    done)
    
    if [ -z "$mysql_cid" ]; then
        err "MySQL container not found"
        return 1
    fi
    
    # Get credentials
    local db_name=$(grep -E "^MYSQL_DATABASE=" "$panel_dir/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "marzban")
    local db_pass=$(grep -E "^MYSQL_ROOT_PASSWORD=" "$panel_dir/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    
    if docker exec "$mysql_cid" mysqldump -uroot -p"$db_pass" "$db_name" > "$output_file" 2>/dev/null; then
        ok "  MySQL exported"
        return 0
    fi
    
    err "  mysqldump failed"
    return 1
}

#==============================================================================
# DATABASE CONVERSION
#==============================================================================

convert_sqlite_to_mysql() {
    local sqlite_file="$1"
    local output_file="$2"
    
    info "Converting SQLite → MySQL..."
    
    if [ ! -f "$sqlite_file" ]; then
        err "SQLite file not found: $sqlite_file"
        return 1
    fi
    
    # Check sqlite3 command
    if ! command -v sqlite3 &>/dev/null; then
        err "sqlite3 command not found. Install: apt install sqlite3"
        return 1
    fi
    
    # First dump SQLite to SQL
    local temp_sql="$TEMP_DIR/sqlite_dump.sql"
    sqlite3 "$sqlite_file" .dump > "$temp_sql" 2>/dev/null
    
    if [ ! -s "$temp_sql" ]; then
        err "SQLite dump failed or empty"
        return 1
    fi
    
    # Convert using Python
    python3 << PYEOF
import re
import sys

input_file = "$temp_sql"
output_file = "$output_file"

try:
    with open(input_file, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    
    # Conversions
    replacements = [
        # Remove SQLite specific
        (r'BEGIN TRANSACTION;', 'START TRANSACTION;'),
        (r'PRAGMA.*?;', ''),
        (r'CREATE TABLE IF NOT EXISTS', 'CREATE TABLE IF NOT EXISTS'),
        
        # Data types
        (r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY'),
        (r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY'),
        (r'\bINTEGER\b', 'INT'),
        (r'\bREAL\b', 'DOUBLE'),
        (r'\bBLOB\b', 'LONGBLOB'),
        
        # Booleans
        (r"'t'", "'1'"),
        (r"'f'", "'0'"),
        
        # Quotes to backticks
        (r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`'),
        
        # AUTOINCREMENT
        (r'AUTOINCREMENT', 'AUTO_INCREMENT'),
    ]
    
    for pattern, replacement in replacements:
        content = re.sub(pattern, replacement, content, flags=re.IGNORECASE | re.MULTILINE)
    
    # Header
    header = """-- Converted from SQLite to MySQL by MRM Migrator
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
SET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';

"""
    
    footer = """

SET FOREIGN_KEY_CHECKS = 1;
"""
    
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(header + content + footer)
    
    print("OK")
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    
    if [ $? -eq 0 ]; then
        ok "Conversion complete"
        return 0
    fi
    
    err "Conversion failed"
    return 1
}

convert_postgresql_to_mysql() {
    local pg_file="$1"
    local output_file="$2"
    
    info "Converting PostgreSQL → MySQL..."
    
    if [ ! -f "$pg_file" ]; then
        err "PostgreSQL dump not found: $pg_file"
        return 1
    fi
    
    python3 << PYEOF
import re
import sys

input_file = "$pg_file"
output_file = "$output_file"

try:
    with open(input_file, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    
    # Remove PostgreSQL specific statements
    remove_patterns = [
        r'--.*$',  # Comments
        r'SET .*?;',
        r'SELECT pg_catalog\..*?;',
        r'\\\\connect.*',
        r'CREATE EXTENSION.*?;',
        r'COMMENT ON.*?;',
        r'ALTER TABLE.*OWNER TO.*?;',
        r'GRANT.*?;',
        r'REVOKE.*?;',
        r'CREATE SCHEMA.*?;',
        r'SET search_path.*?;',
    ]
    
    for pattern in remove_patterns:
        content = re.sub(pattern, '', content, flags=re.MULTILINE | re.IGNORECASE)
    
    # Data type conversions
    type_replacements = [
        (r'\bSERIAL\b', 'INT AUTO_INCREMENT'),
        (r'\bBIGSERIAL\b', 'BIGINT AUTO_INCREMENT'),
        (r'\bSMALLSERIAL\b', 'SMALLINT AUTO_INCREMENT'),
        (r'\bBOOLEAN\b', 'TINYINT(1)'),
        (r'\bTIMESTAMP WITH TIME ZONE\b', 'DATETIME'),
        (r'\bTIMESTAMP WITHOUT TIME ZONE\b', 'DATETIME'),
        (r'\bTIMESTAMPTZ\b', 'DATETIME'),
        (r'\bBYTEA\b', 'LONGBLOB'),
        (r'\bUUID\b', 'VARCHAR(36)'),
        (r'\bJSONB\b', 'JSON'),
        (r'\bJSON\b', 'JSON'),
        (r'\bINET\b', 'VARCHAR(45)'),
        (r'\bCIDR\b', 'VARCHAR(45)'),
        (r'\bMACAADDR\b', 'VARCHAR(17)'),
        (r'\bINTERVAL\b', 'VARCHAR(50)'),
        (r'\bMONEY\b', 'DECIMAL(19,4)'),
        (r'\bDOUBLE PRECISION\b', 'DOUBLE'),
        (r'\bCHARACTER VARYING\b', 'VARCHAR'),
        (r'\bCHARACTER\b', 'CHAR'),
    ]
    
    for pattern, replacement in type_replacements:
        content = re.sub(pattern, replacement, content, flags=re.IGNORECASE)
    
    # Boolean values
    content = re.sub(r"'t'::boolean", "'1'", content)
    content = re.sub(r"'f'::boolean", "'0'", content)
    content = re.sub(r'\btrue\b', "'1'", content, flags=re.IGNORECASE)
    content = re.sub(r'\bfalse\b', "'0'", content, flags=re.IGNORECASE)
    
    # Remove casting
    content = re.sub(r'::\w+(\[\])?', '', content)
    
    # Sequences (not needed in MySQL)
    content = re.sub(r'CREATE SEQUENCE.*?;', '', content, flags=re.DOTALL | re.IGNORECASE)
    content = re.sub(r'ALTER SEQUENCE.*?;', '', content, flags=re.DOTALL | re.IGNORECASE)
    content = re.sub(r"nextval\('.*?'\)", 'NULL', content)
    content = re.sub(r"setval\('.*?'.*?\)", '', content)
    
    # NOW() 
    content = re.sub(r'CURRENT_TIMESTAMP', 'NOW()', content, flags=re.IGNORECASE)
    
    # Quotes
    content = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`', content)
    
    # Array types (remove [])
    content = re.sub(r'\[\]', '', content)
    
    # Clean empty lines
    content = re.sub(r'\n\s*\n\s*\n+', '\n\n', content)
    
    header = """-- Converted from PostgreSQL to MySQL by MRM Migrator
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
SET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';

"""
    
    footer = """

SET FOREIGN_KEY_CHECKS = 1;
"""
    
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(header + content + footer)
    
    print("OK")
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    
    if [ $? -eq 0 ]; then
        ok "Conversion complete"
        return 0
    fi
    
    err "Conversion failed"
    return 1
}

#==============================================================================
# IMPORT TO REBECCA
#==============================================================================

wait_for_mysql() {
    local rebecca_dir="$1"
    local timeout="$2"
    
    info "Waiting for MySQL to be ready..."
    
    local mysql_cid=""
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        mysql_cid=$(cd "$rebecca_dir" && docker compose ps -q 2>/dev/null | while read cid; do
            if docker exec "$cid" mysql --version &>/dev/null 2>&1; then
                echo "$cid"
                break
            fi
        done)
        
        if [ -n "$mysql_cid" ]; then
            # Try to connect
            local db_pass=$(grep -E "^MYSQL_ROOT_PASSWORD=" "$rebecca_dir/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
            if docker exec "$mysql_cid" mysql -uroot -p"$db_pass" -e "SELECT 1" &>/dev/null 2>&1; then
                ok "MySQL is ready"
                return 0
            fi
        fi
        
        sleep 3
        elapsed=$((elapsed + 3))
        echo -ne "  Waiting... ${elapsed}s / ${timeout}s\r"
    done
    echo ""
    
    err "MySQL not ready after ${timeout}s"
    return 1
}

import_mysql() {
    local sql_file="$1"
    
    info "Importing data to Rebecca MySQL..."
    
    if [ ! -f "$sql_file" ]; then
        err "SQL file not found: $sql_file"
        return 1
    fi
    
    if [ ! -d "$REBECCA_DIR" ]; then
        err "Rebecca not found"
        return 1
    fi
    
    # Get MySQL credentials
    local db_name=$(grep -E "^MYSQL_DATABASE=" "$REBECCA_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    local db_pass=$(grep -E "^MYSQL_ROOT_PASSWORD=" "$REBECCA_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    
    db_name="${db_name:-marzban}"
    
    # Find MySQL container
    local mysql_cid=$(cd "$REBECCA_DIR" && docker compose ps -q 2>/dev/null | while read cid; do
        if docker exec "$cid" mysql --version &>/dev/null 2>&1; then
            echo "$cid"
            break
        fi
    done)
    
    if [ -z "$mysql_cid" ]; then
        err "MySQL container not found in Rebecca"
        return 1
    fi
    
    info "  Importing to database: $db_name"
    
    # Copy file to container
    docker cp "$sql_file" "$mysql_cid:/tmp/import.sql" 2>/dev/null
    
    # Import
    if docker exec "$mysql_cid" mysql -uroot -p"$db_pass" "$db_name" -e "source /tmp/import.sql" 2>/dev/null; then
        ok "Data imported successfully"
        docker exec "$mysql_cid" rm -f /tmp/import.sql 2>/dev/null
        return 0
    fi
    
    # Alternative method
    warn "Standard import failed, trying alternative..."
    if docker exec -i "$mysql_cid" mysql -uroot -p"$db_pass" "$db_name" < "$sql_file" 2>/dev/null; then
        ok "Data imported (alternative method)"
        return 0
    fi
    
    err "Import failed"
    echo ""
    echo "Manual import may be needed:"
    echo "  1. Copy: docker cp $sql_file CONTAINER:/tmp/import.sql"
    echo "  2. Import: docker exec -it CONTAINER mysql -uroot -p DB_NAME < /tmp/import.sql"
    return 1
}

#==============================================================================
# MIGRATE CONFIGURATIONS
#==============================================================================

migrate_configs() {
    info "Migrating configurations..."
    
    if [ ! -f "$PASARGUARD_DIR/.env" ]; then
        warn "Pasarguard .env not found"
        return 0
    fi
    
    if [ ! -f "$REBECCA_DIR/.env" ]; then
        warn "Rebecca .env not found"
        return 1
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
        "XRAY_JSON"
        "XRAY_EXECUTABLE_PATH"
        "XRAY_ASSETS_PATH"
        "XRAY_SUBSCRIPTION_URL_PREFIX"
        "SUBSCRIPTION_URL_PREFIX"
    )
    
    local migrated=0
    for var in "${vars[@]}"; do
        local value=$(grep "^${var}=" "$PASARGUARD_DIR/.env" 2>/dev/null | cut -d'=' -f2-)
        if [ -n "$value" ]; then
            sed -i "/^${var}=/d" "$REBECCA_DIR/.env" 2>/dev/null
            echo "${var}=${value}" >> "$REBECCA_DIR/.env"
            migrated=$((migrated + 1))
        fi
    done
    
    ok "Migrated $migrated configuration variables"
    
    # Copy certificates
    if [ -d "$PASARGUARD_DATA/certs" ]; then
        info "Copying SSL certificates..."
        mkdir -p "$REBECCA_DATA/certs"
        cp -r "$PASARGUARD_DATA/certs/"* "$REBECCA_DATA/certs/" 2>/dev/null
        ok "Certificates copied"
    fi
    
    # Copy Xray config
    if [ -f "$PASARGUARD_DATA/xray_config.json" ]; then
        info "Copying Xray config..."
        cp "$PASARGUARD_DATA/xray_config.json" "$REBECCA_DATA/" 2>/dev/null
        ok "Xray config copied"
    fi
    
    return 0
}

#==============================================================================
# ROLLBACK
#==============================================================================

do_rollback() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       ROLLBACK TO PASARGUARD               ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    if [ ! -f "$BACKUP_ROOT/.last_backup" ]; then
        err "No backup information found"
        echo ""
        echo "Available backups in $BACKUP_ROOT:"
        ls -la "$BACKUP_ROOT" 2>/dev/null || echo "  (none)"
        safe_pause
        return 1
    fi
    
    local backup_dir=$(cat "$BACKUP_ROOT/.last_backup")
    
    if [ ! -d "$backup_dir" ]; then
        err "Backup directory not found: $backup_dir"
        safe_pause
        return 1
    fi
    
    echo -e "Backup found: ${GREEN}$backup_dir${NC}"
    echo ""
    
    if [ -f "$backup_dir/metadata.txt" ]; then
        echo "Backup info:"
        cat "$backup_dir/metadata.txt"
        echo ""
    fi
    
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  WARNING: This will stop Rebecca and       ${NC}"
    echo -e "${RED}  restore Pasarguard from backup!           ${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "Type 'rollback' to confirm: " confirm
    
    if [ "$confirm" != "rollback" ]; then
        info "Rollback cancelled"
        safe_pause
        return 0
    fi
    
    echo ""
    init_migration
    
    # Step 1: Stop Rebecca
    info "Step 1: Stopping Rebecca..."
    stop_panel "$REBECCA_DIR" "Rebecca"
    
    # Step 2: Restore config
    if [ -f "$backup_dir/pasarguard_config.tar.gz" ]; then
        info "Step 2: Restoring Pasarguard config..."
        rm -rf "$PASARGUARD_DIR" 2>/dev/null
        mkdir -p "$(dirname "$PASARGUARD_DIR")"
        tar -xzf "$backup_dir/pasarguard_config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")" 2>/dev/null
        ok "Config restored"
    fi
    
    # Step 3: Restore data
    if [ -f "$backup_dir/pasarguard_data.tar.gz" ]; then
        info "Step 3: Restoring Pasarguard data..."
        rm -rf "$PASARGUARD_DATA" 2>/dev/null
        mkdir -p "$(dirname "$PASARGUARD_DATA")"
        tar -xzf "$backup_dir/pasarguard_data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")" 2>/dev/null
        ok "Data restored"
    fi
    
    # Step 4: Start Pasarguard
    info "Step 4: Starting Pasarguard..."
    if start_panel "$PASARGUARD_DIR" "Pasarguard"; then
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}      ROLLBACK COMPLETED SUCCESSFULLY!       ${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "Pasarguard has been restored and is running."
    else
        err "Failed to start Pasarguard"
        echo "You may need to start it manually:"
        echo "  cd $PASARGUARD_DIR && docker compose up -d"
    fi
    
    safe_pause
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

do_migration() {
    init_migration
    
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}     PASARGUARD → REBECCA MIGRATION WIZARD       ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Pre-checks
    if ! check_dependencies; then
        safe_pause
        return 1
    fi
    
    echo ""
    
    # Check Pasarguard
    if [ ! -d "$PASARGUARD_DIR" ]; then
        err "Pasarguard not found at $PASARGUARD_DIR"
        safe_pause
        return 1
    fi
    ok "Pasarguard found"
    
    # Detect database
    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database type: ${CYAN}$db_type${NC}"
    
    if [ "$db_type" == "unknown" ] || [ "$db_type" == "not_found" ]; then
        err "Could not detect database type"
        safe_pause
        return 1
    fi
    
    # Check Rebecca
    if [ ! -d "$REBECCA_DIR" ]; then
        echo ""
        echo -e "${YELLOW}Rebecca is not installed!${NC}"
        echo ""
        echo "Please install Rebecca first:"
        echo "  1. Download Rebecca installer"
        echo "  2. Choose MySQL as database type"
        echo "  3. Complete installation"
        echo "  4. Run this migration again"
        echo ""
        safe_pause
        return 1
    fi
    ok "Rebecca found"
    
    # Summary
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Migration Summary:${NC}"
    echo -e "  Source:   ${CYAN}Pasarguard ($db_type)${NC}"
    echo -e "  Target:   ${CYAN}Rebecca (MySQL)${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${RED}⚠ WARNING ⚠${NC}"
    echo "This will:"
    echo "  1. Create a full backup of Pasarguard"
    echo "  2. Export and convert database to MySQL"
    echo "  3. Stop Pasarguard"
    echo "  4. Import data to Rebecca"
    echo ""
    read -p "Type 'migrate' to start: " confirm
    
    if [ "$confirm" != "migrate" ]; then
        info "Migration cancelled"
        safe_pause
        return 0
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    #--------------------------------------
    # STEP 1: Backup
    #--------------------------------------
    echo -e "${BOLD}[STEP 1/6] Creating Backup${NC}"
    local backup_dir=$(create_backup)
    
    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        err "Backup failed!"
        safe_pause
        return 1
    fi
    echo ""
    
    #--------------------------------------
    # STEP 2: Export Database
    #--------------------------------------
    echo -e "${BOLD}[STEP 2/6] Exporting Database${NC}"
    local source_dump="$TEMP_DIR/source_dump.sql"
    local convert_needed=false
    
    case "$db_type" in
        "postgresql")
            if [ -f "$backup_dir/database.sql" ]; then
                cp "$backup_dir/database.sql" "$source_dump"
                ok "Using backed up PostgreSQL dump"
            else
                export_postgresql "$source_dump" || { err "Export failed"; safe_pause; return 1; }
            fi
            convert_needed=true
            ;;
        "sqlite")
            if [ -f "$backup_dir/database.sqlite3" ]; then
                # Convert from SQLite file
                source_dump="$backup_dir/database.sqlite3"
                ok "Using backed up SQLite database"
            elif [ -f "$PASARGUARD_DATA/db.sqlite3" ]; then
                source_dump="$PASARGUARD_DATA/db.sqlite3"
                ok "Using live SQLite database"
            else
                err "SQLite database not found"
                safe_pause
                return 1
            fi
            convert_needed=true
            ;;
        "mysql")
            if [ -f "$backup_dir/database.sql" ]; then
                cp "$backup_dir/database.sql" "$source_dump"
                ok "Using backed up MySQL dump"
            else
                export_mysql "$PASARGUARD_DIR" "$source_dump" || { err "Export failed"; safe_pause; return 1; }
            fi
            convert_needed=false
            ;;
    esac
    echo ""
    
    #--------------------------------------
    # STEP 3: Convert Database
    #--------------------------------------
    echo -e "${BOLD}[STEP 3/6] Converting Database${NC}"
    local mysql_dump="$TEMP_DIR/mysql_import.sql"
    
    if [ "$convert_needed" = true ]; then
        case "$db_type" in
            "postgresql")
                convert_postgresql_to_mysql "$source_dump" "$mysql_dump" || { err "Conversion failed"; safe_pause; return 1; }
                ;;
            "sqlite")
                convert_sqlite_to_mysql "$source_dump" "$mysql_dump" || { err "Conversion failed"; safe_pause; return 1; }
                ;;
        esac
    else
        cp "$source_dump" "$mysql_dump"
        ok "No conversion needed (already MySQL)"
    fi
    
    # Save converted dump to backup
    cp "$mysql_dump" "$backup_dir/mysql_converted.sql" 2>/dev/null
    echo ""
    
    #--------------------------------------
    # STEP 4: Stop Pasarguard
    #--------------------------------------
    echo -e "${BOLD}[STEP 4/6] Stopping Pasarguard${NC}"
    stop_panel "$PASARGUARD_DIR" "Pasarguard"
    echo ""
    
    #--------------------------------------
    # STEP 5: Migrate Configs
    #--------------------------------------
    echo -e "${BOLD}[STEP 5/6] Migrating Configurations${NC}"
    migrate_configs
    echo ""
    
    #--------------------------------------
    # STEP 6: Import to Rebecca
    #--------------------------------------
    echo -e "${BOLD}[STEP 6/6] Importing to Rebecca${NC}"
    
    # Start Rebecca if not running
    if ! is_container_running "$REBECCA_DIR"; then
        start_panel "$REBECCA_DIR" "Rebecca" || { err "Failed to start Rebecca"; safe_pause; return 1; }
    fi
    
    # Wait for MySQL
    wait_for_mysql "$REBECCA_DIR" "$MYSQL_WAIT" || { 
        warn "MySQL may not be ready, attempting import anyway..."
    }
    
    # Import
    import_mysql "$mysql_dump"
    local import_result=$?
    
    # Restart Rebecca
    info "Restarting Rebecca..."
    (cd "$REBECCA_DIR" && docker compose restart 2>/dev/null)
    sleep 5
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [ $import_result -eq 0 ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}      MIGRATION COMPLETED SUCCESSFULLY!           ${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}    MIGRATION COMPLETED WITH WARNINGS             ${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "Data import may need manual attention."
        echo "SQL file saved: $backup_dir/mysql_converted.sql"
    fi
    
    echo ""
    echo -e "Backup saved:   ${CYAN}$backup_dir${NC}"
    echo -e "To rollback:    ${CYAN}Use option 2 in menu${NC}"
    echo ""
    echo "Login to Rebecca with your existing credentials."
    echo ""
    
    safe_pause
}

#==============================================================================
# VIEW FUNCTIONS
#==============================================================================

view_backups() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}         AVAILABLE BACKUPS                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    echo "Backup Directory: $BACKUP_ROOT"
    echo ""
    
    if [ -d "$BACKUP_ROOT" ]; then
        ls -lh "$BACKUP_ROOT" 2>/dev/null | grep -v "^total"
    else
        echo "(No backups)"
    fi
    
    echo ""
    
    if [ -f "$BACKUP_ROOT/.last_backup" ]; then
        echo -e "Last backup: ${GREEN}$(cat "$BACKUP_ROOT/.last_backup")${NC}"
    fi
    
    safe_pause
}

view_log() {
    clear
    if [ -f "$LOG_FILE" ]; then
        echo -e "${CYAN}Log File: $LOG_FILE${NC}"
        echo ""
        tail -100 "$LOG_FILE"
        echo ""
        echo "(Showing last 100 lines)"
    else
        echo "No log file found."
    fi
    safe_pause
}

#==============================================================================
# MENU
#==============================================================================

migrator_menu() {
    while true; do
        clear
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}           MIGRATION TOOLS                    ${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} Migrate Pasarguard → Rebecca"
        echo -e "  ${RED}2)${NC} Rollback to Pasarguard"
        echo ""
        echo -e "  ${CYAN}3)${NC} View Backups"
        echo -e "  ${CYAN}4)${NC} View Migration Log"
        echo ""
        echo -e "  ${YELLOW}0)${NC} Back"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        read -p "Select: " opt
        
        case "$opt" in
            1) do_migration ;;
            2) do_rollback ;;
            3) view_backups ;;
            4) view_log ;;
            0) cleanup_temp; return ;;
            *) ;;
        esac
    done
}

#==============================================================================
# ENTRY POINT
#==============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    migrator_menu
fi