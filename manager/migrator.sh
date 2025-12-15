#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard -> Rebecca
# Version: 11.0 (Complete Rewrite - Robust Type Handling)
#==============================================================================

PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
MIGRATION_LOG="${MIGRATION_LOG:-/var/log/mrm_migration.log}"
MIGRATION_TEMP=""
CONTAINER_TIMEOUT=120
MYSQL_WAIT=60

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

migration_init() {
    MIGRATION_TEMP=$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null) || MIGRATION_TEMP="/tmp/mrm-migration-$$"
    mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT"
    mkdir -p "$(dirname "$MIGRATION_LOG")" 2>/dev/null || MIGRATION_LOG="/tmp/mrm_migration.log"
    echo "" >> "$MIGRATION_LOG"
    echo "=== Migration: $(date) ===" >> "$MIGRATION_LOG"
}

migration_cleanup() {
    [[ "$MIGRATION_TEMP" == /tmp/* ]] && rm -rf "$MIGRATION_TEMP" 2>/dev/null
}

mlog() { echo "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG"; }
minfo() { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok() { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn() { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr() { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }

mpause() {
    echo ""
    echo -e "${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s -r
    echo ""
}

detect_migration_db_type() {
    local panel_dir="$1" data_dir="$2"
    [ ! -d "$panel_dir" ] && { echo "not_found"; return 1; }

    local env_file="$panel_dir/.env"
    if [ -f "$env_file" ]; then
        local db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')
        case "$db_url" in
            *timescale*|*postgresql+asyncpg*) echo "timescaledb"; return 0 ;;
            *postgresql*) echo "postgresql"; return 0 ;;
            *mysql+asyncmy*|*mysql*) echo "mysql"; return 0 ;;
            *mariadb*) echo "mariadb"; return 0 ;;
            *sqlite*) echo "sqlite"; return 0 ;;
        esac
    fi
    [ -f "$data_dir/db.sqlite3" ] && { echo "sqlite"; return 0; }
    echo "unknown"; return 1
}

get_migration_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    MIG_DB_USER=""; MIG_DB_PASS=""; MIG_DB_HOST=""; MIG_DB_PORT=""; MIG_DB_NAME=""
    [ ! -f "$env_file" ] && return 1

    local db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')

    eval "$(python3 << PYEOF
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    scheme, rest = url.split('://', 1)
    if '+' in scheme: scheme = scheme.split('+', 1)[0]
    url = scheme + '://' + rest
    p = urlparse(url)
    print(f'MIG_DB_USER="{p.username or ""}"')
    print(f'MIG_DB_PASS="{unquote(p.password or "")}"')
    print(f'MIG_DB_HOST="{p.hostname or "localhost"}"')
    print(f'MIG_DB_PORT="{p.port or ""}"')
    print(f'MIG_DB_NAME="{(p.path or "").lstrip("/") or "pasarguard"}"')
else:
    print('MIG_DB_USER=""'); print('MIG_DB_PASS=""'); print('MIG_DB_HOST="localhost"'); print('MIG_DB_PORT=""'); print('MIG_DB_NAME="pasarguard"')
PYEOF
)"
}

find_migration_pg_container() {
    local cname=""
    for svc in timescaledb db postgres postgresql database; do
        cname=$(cd "$PASARGUARD_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        [ -n "$cname" ] && { echo "$cname"; return 0; }
    done
    cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(timescale|postgres|db)" | head -1)
    [ -n "$cname" ] && echo "$cname"
}

find_migration_mysql_container() {
    local cname=""
    for svc in mysql mariadb db database; do
        cname=$(cd "$REBECCA_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        [ -n "$cname" ] && { echo "$cname"; return 0; }
    done
    cname=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb|db)" | head -1)
    [ -n "$cname" ] && echo "$cname"
}

is_migration_running() {
    [ -d "$1" ] && (cd "$1" && docker compose ps 2>/dev/null | grep -qE "Up|running")
}

start_migration_panel() {
    local dir="$1" name="$2"
    minfo "Starting $name..."
    [ ! -d "$dir" ] && { merr "$dir not found"; return 1; }
    (cd "$dir" && docker compose up -d) &>/dev/null
    local i=0
    while [ $i -lt $CONTAINER_TIMEOUT ]; do
        is_migration_running "$dir" && { mok "$name started"; sleep 3; return 0; }
        sleep 3; i=$((i+3))
    done
    merr "$name failed to start"; return 1
}

stop_migration_panel() {
    local dir="$1" name="$2"
    [ ! -d "$dir" ] && return 0
    minfo "Stopping $name..."
    (cd "$dir" && docker compose down) &>/dev/null
    sleep 2
    mok "$name stopped"
}

create_migration_backup() {
    minfo "Creating backup..."
    local ts=$(date +%Y%m%d_%H%M%S)
    CURRENT_MIGRATION_BACKUP="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$CURRENT_MIGRATION_BACKUP"
    echo "$CURRENT_MIGRATION_BACKUP" > "$BACKUP_ROOT/.last_backup"

    if [ -d "$PASARGUARD_DIR" ]; then
        minfo "  Backing up config..."
        tar --exclude='*/node_modules' -C "$(dirname "$PASARGUARD_DIR")" \
            -czf "$CURRENT_MIGRATION_BACKUP/pasarguard_config.tar.gz" "$(basename "$PASARGUARD_DIR")" 2>/dev/null
        mok "  Config saved"
    fi

    if [ -d "$PASARGUARD_DATA" ]; then
        minfo "  Backing up data..."
        tar -C "$(dirname "$PASARGUARD_DATA")" \
            -czf "$CURRENT_MIGRATION_BACKUP/pasarguard_data.tar.gz" "$(basename "$PASARGUARD_DATA")" 2>/dev/null
        mok "  Data saved"
    fi

    local db_type=$(detect_migration_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$CURRENT_MIGRATION_BACKUP/db_type.txt"
    minfo "  Exporting database ($db_type)..."

    local export_success=false
    case "$db_type" in
        sqlite)
            if [ -f "$PASARGUARD_DATA/db.sqlite3" ]; then
                cp "$PASARGUARD_DATA/db.sqlite3" "$CURRENT_MIGRATION_BACKUP/database.sqlite3"
                mok "  SQLite exported"
                export_success=true
            fi
            ;;
        timescaledb|postgresql)
            export_migration_postgresql "$CURRENT_MIGRATION_BACKUP/database.sql" && export_success=true
            ;;
        mysql|mariadb)
            export_migration_mysql "$CURRENT_MIGRATION_BACKUP/database.sql" && export_success=true
            ;;
    esac

    mok "Backup: $CURRENT_MIGRATION_BACKUP"
    [ "$export_success" = true ]
}

export_migration_postgresql() {
    local output_file="$1"
    get_migration_db_credentials "$PASARGUARD_DIR"
    local user="${MIG_DB_USER:-pasarguard}"
    local db="${MIG_DB_NAME:-pasarguard}"

    minfo "  User: $user, DB: $db"

    local cname=$(find_migration_pg_container)
    [ -z "$cname" ] && { merr "  PostgreSQL container not found!"; return 1; }
    minfo "  Container: $cname"

    local i=0
    while [ $i -lt 30 ]; do
        docker exec "$cname" pg_isready &>/dev/null && break
        sleep 2; i=$((i+2))
    done

    minfo "  Running pg_dump (Safe Mode)..."
    local PG_FLAGS="--no-owner --no-acl --inserts --no-comments"

    if docker exec "$cname" pg_dump -U "$user" -d "$db" $PG_FLAGS > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            mok "  Exported: $(du -h "$output_file" | cut -f1)"
            return 0
        fi
    fi

    if docker exec -e PGPASSWORD="$MIG_DB_PASS" "$cname" pg_dump -U "$user" -d "$db" $PG_FLAGS > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            mok "  Exported: $(du -h "$output_file" | cut -f1)"
            return 0
        fi
    fi

    merr "  pg_dump failed"
    return 1
}

export_migration_mysql() {
    local output_file="$1"
    get_migration_db_credentials "$PASARGUARD_DIR"
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(mysql|mariadb|db)" | head -1)
    [ -z "$cname" ] && { merr "  MySQL container not found"; return 1; }

    if docker exec "$cname" mysqldump -u"${MIG_DB_USER:-root}" -p"$MIG_DB_PASS" --single-transaction "${MIG_DB_NAME:-pasarguard}" > "$output_file" 2>/dev/null; then
        [ -s "$output_file" ] && { mok "  Exported"; return 0; }
    fi
    merr "  mysqldump failed"; return 1
}

convert_migration_to_mysql() {
    local src="$1" dst="$2" type="$3"
    case "$type" in
        sqlite) convert_migration_sqlite "$src" "$dst" ;;
        postgresql|timescaledb) convert_migration_postgresql "$src" "$dst" ;;
        mysql|mariadb) cp "$src" "$dst"; mok "No conversion needed" ;;
        *) merr "Unknown: $type"; return 1 ;;
    esac
}

convert_migration_sqlite() {
    local src="$1" dst="$2"
    minfo "Converting SQLite → MySQL..."
    [ ! -f "$src" ] && { merr "Source not found"; return 1; }

    local dump="$MIGRATION_TEMP/sqlite_dump.sql"
    sqlite3 "$src" .dump > "$dump" 2>/dev/null || { merr "Dump failed"; return 1; }

    python3 - "$dump" "$dst" << 'PYEOF'
import sys, re
src_file = sys.argv[1]
dst_file = sys.argv[2]
try:
    with open(src_file, 'r', errors='replace') as f: c = f.read()
    c = re.sub(r'BEGIN TRANSACTION;', 'START TRANSACTION;', c)
    c = re.sub(r'PRAGMA.*?;\n?', '', c)
    c = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
    c = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
    c = re.sub(r'\bINTEGER\b', 'INT', c, flags=re.I)
    c = re.sub(r'\bREAL\b', 'DOUBLE', c, flags=re.I)
    c = re.sub(r'\bBLOB\b', 'LONGBLOB', c, flags=re.I)
    c = re.sub(r'"([a-zA-Z_]\w*)"', r'`\1`', c)
    with open(dst_file, 'w') as f:
        f.write("SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\n\n" + c + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")
except Exception as e:
    print(e)
    sys.exit(1)
PYEOF
    [ -s "$dst" ] && { mok "Converted"; return 0; }
    merr "Conversion failed"; return 1
}

convert_migration_postgresql() {
    local src="$1" dst="$2"
    minfo "Converting PostgreSQL → MySQL..."
    [ ! -f "$src" ] && { merr "Source not found"; return 1; }

    python3 - "$src" "$dst" << 'PYEOF'
import re
import sys

def convert_pg_to_mysql(input_file, output_file):
    with open(input_file, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    
    lines = content.split('\n')
    result_lines = []
    
    # Known MySQL column types
    MYSQL_TYPES = {
        'INT', 'INTEGER', 'BIGINT', 'SMALLINT', 'TINYINT', 'MEDIUMINT',
        'VARCHAR', 'CHAR', 'TEXT', 'MEDIUMTEXT', 'LONGTEXT', 'TINYTEXT',
        'DATETIME', 'DATE', 'TIME', 'TIMESTAMP', 'YEAR',
        'FLOAT', 'DOUBLE', 'DECIMAL', 'NUMERIC', 'REAL',
        'BLOB', 'MEDIUMBLOB', 'LONGBLOB', 'TINYBLOB',
        'JSON', 'ENUM', 'SET', 'BOOLEAN', 'BOOL',
        'AUTO_INCREMENT', 'PRIMARY', 'KEY', 'NOT', 'NULL', 'DEFAULT', 'UNIQUE'
    }
    
    # PostgreSQL to MySQL type mapping
    PG_TYPE_MAP = {
        'BOOLEAN': 'TINYINT(1)',
        'BOOL': 'TINYINT(1)',
        'TIMESTAMP WITH TIME ZONE': 'DATETIME',
        'TIMESTAMP WITHOUT TIME ZONE': 'DATETIME',
        'TIMESTAMPTZ': 'DATETIME',
        'JSONB': 'JSON',
        'UUID': 'VARCHAR(36)',
        'BYTEA': 'LONGBLOB',
        'INET': 'VARCHAR(45)',
        'CIDR': 'VARCHAR(45)',
        'MACADDR': 'VARCHAR(17)',
        'DOUBLE PRECISION': 'DOUBLE',
        'SERIAL': 'INT AUTO_INCREMENT',
        'BIGSERIAL': 'BIGINT AUTO_INCREMENT',
        'SMALLSERIAL': 'SMALLINT AUTO_INCREMENT',
        'CHARACTER VARYING': 'VARCHAR',
    }
    
    # Lines to skip entirely
    skip_patterns = [
        r'^\s*\\',  # psql commands
        r'^\s*--',  # comments
        r'^\s*SET\s+\w+',  # SET commands
        r'^\s*SELECT\s+pg_catalog',  # pg_catalog
        r'^\s*SELECT\s+setval',  # setval
        r'^\s*CREATE\s+TYPE',  # custom types
        r'^\s*CREATE\s+SEQUENCE',  # sequences
        r'^\s*ALTER\s+SEQUENCE',  # alter sequence
        r'^\s*CREATE\s+EXTENSION',  # extensions
        r'^\s*COMMENT\s+ON',  # comments
        r'^\s*GRANT\s+',  # grants
        r'^\s*REVOKE\s+',  # revokes
        r'^\s*ALTER\s+.*OWNER\s+TO',  # owner changes
    ]
    
    in_create_table = False
    skip_until_semicolon = False
    
    for line in lines:
        original_line = line
        
        # Skip certain lines
        skip_line = False
        for pattern in skip_patterns:
            if re.match(pattern, line, re.I):
                skip_line = True
                break
        
        if skip_line:
            continue
        
        if skip_until_semicolon:
            if ';' in line:
                skip_until_semicolon = False
            continue
        
        # Skip ALTER TABLE ... SET DEFAULT nextval
        if re.match(r'^\s*ALTER\s+TABLE.*SET\s+DEFAULT\s+nextval', line, re.I):
            skip_until_semicolon = ';' not in line
            continue
        
        # Track CREATE TABLE
        if re.match(r'^\s*CREATE\s+TABLE', line, re.I):
            in_create_table = True
        
        if in_create_table and ');' in line:
            in_create_table = False
        
        # === TRANSFORMATIONS ===
        
        # 1. Remove type casts: 'value'::typename -> 'value'
        line = re.sub(r"('[^']*')::[a-zA-Z_][a-zA-Z0-9_]*(\([^)]*\))?", r'\1', line)
        line = re.sub(r"(\d+)::[a-zA-Z_][a-zA-Z0-9_]*", r'\1', line)
        line = re.sub(r"::[a-zA-Z_][a-zA-Z0-9_]*(\[\])?", '', line)
        
        # 2. Remove 'public.' schema prefix
        line = re.sub(r'\bpublic\.', '', line)
        
        # 3. Convert PostgreSQL types to MySQL
        for pg_type, mysql_type in PG_TYPE_MAP.items():
            line = re.sub(r'\b' + pg_type + r'\b', mysql_type, line, flags=re.I)
        
        # 4. Handle CHARACTER VARYING(n)
        line = re.sub(r'\bCHARACTER\s+VARYING\s*\((\d+)\)', r'VARCHAR(\1)', line, flags=re.I)
        line = re.sub(r'\bCHARACTER\s+VARYING\b', 'VARCHAR(255)', line, flags=re.I)
        
        # 5. Handle GENERATED AS IDENTITY
        line = re.sub(r'\bGENERATED\s+BY\s+DEFAULT\s+AS\s+IDENTITY(\s*\([^)]*\))?', 'AUTO_INCREMENT', line, flags=re.I)
        line = re.sub(r'\bGENERATED\s+ALWAYS\s+AS\s+IDENTITY(\s*\([^)]*\))?', 'AUTO_INCREMENT', line, flags=re.I)
        
        # 6. Convert arrays to JSON
        line = re.sub(r'\b(\w+)\s*\[\]', 'JSON', line)
        line = re.sub(r"'\{\}'", 'NULL', line)
        line = re.sub(r'ARRAY\[[^\]]*\]', 'NULL', line, flags=re.I)
        
        # 7. Remove nextval
        line = re.sub(r"DEFAULT\s+nextval\([^)]+\)", '', line, flags=re.I)
        line = re.sub(r"nextval\([^)]+\)", 'NULL', line, flags=re.I)
        
        # 8. Convert boolean values
        line = re.sub(r'\bTRUE\b', '1', line, flags=re.I)
        line = re.sub(r'\bFALSE\b', '0', line, flags=re.I)
        
        # 9. Remove USING btree
        line = re.sub(r'\s+USING\s+btree', '', line, flags=re.I)
        
        # 10. Quote table names (handle reserved words like 'groups')
        line = re.sub(r'CREATE TABLE\s+(?!`)([a-zA-Z_][a-zA-Z0-9_]*)', r'CREATE TABLE `\1`', line, flags=re.I)
        line = re.sub(r'INSERT INTO\s+(?!`)([a-zA-Z_][a-zA-Z0-9_]*)', r'INSERT INTO `\1`', line, flags=re.I)
        line = re.sub(r'ALTER TABLE\s+(?!`)([a-zA-Z_][a-zA-Z0-9_]*)', r'ALTER TABLE `\1`', line, flags=re.I)
        line = re.sub(r'REFERENCES\s+(?!`)([a-zA-Z_][a-zA-Z0-9_]*)', r'REFERENCES `\1`', line, flags=re.I)
        
        # 11. Convert PostgreSQL quotes to MySQL backticks
        line = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'`\1`', line)
        
        # 12. Handle column definitions with unknown types
        if in_create_table and not re.match(r'^\s*(CREATE|PRIMARY|\)|,?\s*CONSTRAINT)', line, re.I):
            # Pattern: column_name type_name ...
            match = re.match(r'^(\s*)(\w+)\s+([a-zA-Z_][a-zA-Z0-9_]*)(.*)$', line)
            if match:
                indent = match.group(1)
                col_name = match.group(2)
                type_name = match.group(3).upper()
                rest = match.group(4)
                
                # Check if type_name is a known MySQL type
                base_type = type_name.split('(')[0] if '(' in type_name else type_name
                
                if base_type not in MYSQL_TYPES and col_name.upper() not in ['PRIMARY', 'UNIQUE', 'CONSTRAINT', 'CHECK', 'FOREIGN']:
                    # Unknown type - convert to VARCHAR(255)
                    print(f"    Converting unknown type: {type_name} -> VARCHAR(255)")
                    line = f"{indent}{col_name} VARCHAR(255){rest}"
        
        # 13. Remove CHECK constraints
        line = re.sub(r',?\s*CONSTRAINT\s+`?[^`\s]+`?\s+CHECK\s*\([^)]+\)', '', line, flags=re.I)
        line = re.sub(r',?\s*CHECK\s*\([^)]+\)', '', line, flags=re.I)
        
        result_lines.append(line)
    
    # Join and clean up
    result = '\n'.join(result_lines)
    
    # Final cleanups
    result = re.sub(r'\n\s*\n\s*\n+', '\n\n', result)
    result = re.sub(r';\s*;', ';', result)
    result = re.sub(r',\s*\)', ')', result)  # Remove trailing commas before )
    
    # Add MySQL header
    header = """SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""
    footer = """

SET FOREIGN_KEY_CHECKS=1;
"""
    
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(header + result + footer)
    
    print("  Conversion completed successfully")

# Main
try:
    src_file = sys.argv[1]
    dst_file = sys.argv[2]
    print(f"  Reading {src_file}...")
    convert_pg_to_mysql(src_file, dst_file)
except Exception as e:
    print(f"  Error: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYEOF

    if [ $? -eq 0 ] && [ -s "$dst" ]; then
        mok "Conversion successful"
        return 0
    else
        merr "Conversion failed"
        return 1
    fi
}

check_migration_rebecca() { [ -d "$REBECCA_DIR" ] && [ -f "$REBECCA_DIR/.env" ]; }
check_migration_rebecca_mysql() { [ -f "$REBECCA_DIR/.env" ] && grep -qiE "mysql|mariadb" "$REBECCA_DIR/.env"; }

wait_migration_mysql() {
    minfo "Waiting for MySQL..."
    local i=0
    while [ $i -lt $MYSQL_WAIT ]; do
        local cname=$(find_migration_mysql_container)
        if [ -n "$cname" ]; then
            local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'")
            docker exec "$cname" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null && { mok "MySQL ready"; return 0; }
        fi
        sleep 3; i=$((i+3))
    done
    mwarn "MySQL timeout"; return 1
}

import_migration_to_rebecca() {
    local sql="$1"
    minfo "Importing to Rebecca..."
    [ ! -f "$sql" ] && { merr "SQL not found"; return 1; }

    local db=$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'")
    [ -z "$db" ] && db="marzban"
    local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'")
    local cname=$(find_migration_mysql_container)

    [ -z "$cname" ] && { merr "MySQL container not found"; return 1; }
    minfo "  Container: $cname, DB: $db"
    minfo "  SQL file: $(du -h "$sql" | cut -f1), $(wc -l < "$sql") lines"

    minfo "  Resetting database..."
    docker exec "$cname" mysql -uroot -p"$pass" -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null

    local err_file="$MIGRATION_TEMP/mysql_import.err"
    minfo "  Running MySQL import..."

    if docker exec -i "$cname" mysql --binary-mode=1 -uroot -p"$pass" "$db" < "$sql" 2> "$err_file"; then
        local tables=$(docker exec "$cname" mysql -uroot -p"$pass" "$db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
        mok "Import successful! ($tables tables)"
        
        docker exec "$cname" mysql -uroot -p"$pass" "$db" -N -e "SHOW TABLES;" 2>/dev/null | head -10 | while read t; do
            echo "    - $t"
        done
        [ $tables -gt 10 ] && echo "    ... and $((tables-10)) more"
        
        return 0
    else
        merr "Import failed!"
        grep -v "Using a password" "$err_file" | head -20
        mlog "MySQL Error: $(cat "$err_file")"
        
        local line_num=$(grep -oP 'at line \K[0-9]+' "$err_file" 2>/dev/null | head -1)
        if [ -n "$line_num" ]; then
            echo ""
            mwarn "Problem around line $line_num:"
            sed -n "$((line_num > 2 ? line_num-2 : 1)),$((line_num+3))p" "$sql" 2>/dev/null
        fi
        return 1
    fi
}

migrate_migration_configs() {
    minfo "Migrating configs..."
    [ ! -f "$PASARGUARD_DIR/.env" ] || [ ! -f "$REBECCA_DIR/.env" ] && return 0

    local vars=("SUDO_USERNAME" "SUDO_PASSWORD" "UVICORN_PORT" "TELEGRAM_API_TOKEN" "TELEGRAM_ADMIN_ID"
                "XRAY_SUBSCRIPTION_URL_PREFIX" "WEBHOOK_ADDRESS" "WEBHOOK_SECRET")
    local n=0
    for v in "${vars[@]}"; do
        local val=$(grep "^${v}=" "$PASARGUARD_DIR/.env" 2>/dev/null | sed 's/[^=]*=//')
        if [ -n "$val" ]; then
            sed -i "/^${v}=/d" "$REBECCA_DIR/.env" 2>/dev/null
            echo "${v}=${val}" >> "$REBECCA_DIR/.env"
            n=$((n+1))
        fi
    done
    mok "Migrated $n variables"
}

do_full_migration() {
    migration_init
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   PASARGUARD → REBECCA MIGRATION v11.0        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    for cmd in docker python3 sqlite3; do
        command -v "$cmd" &>/dev/null || { merr "Missing: $cmd"; mpause; return 1; }
    done
    mok "Dependencies OK"

    [ ! -d "$PASARGUARD_DIR" ] && { merr "Pasarguard not found"; mpause; return 1; }
    mok "Pasarguard found"

    local db_type=$(detect_migration_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database: ${CYAN}$db_type${NC}"

    check_migration_rebecca || { merr "Rebecca not installed"; mpause; return 1; }
    mok "Rebecca found"
    check_migration_rebecca_mysql || { merr "Rebecca needs MySQL"; mpause; return 1; }
    mok "MySQL verified"

    echo ""
    read -p "Type 'migrate' to start: " confirm
    [ "$confirm" != "migrate" ] && { minfo "Cancelled"; return 0; }

    echo -e "\n${CYAN}━━━ STEP 1: BACKUP ━━━${NC}"
    is_migration_running "$PASARGUARD_DIR" || start_migration_panel "$PASARGUARD_DIR" "Pasarguard"
    create_migration_backup || { merr "Backup failed"; mpause; migration_cleanup; return 1; }

    local backup_dir=$(cat "$BACKUP_ROOT/.last_backup" 2>/dev/null)

    echo -e "\n${CYAN}━━━ STEP 2: VERIFY ━━━${NC}"
    local src=""
    case "$db_type" in
        sqlite) src="$backup_dir/database.sqlite3" ;;
        *) src="$backup_dir/database.sql" ;;
    esac
    [ ! -s "$src" ] && { merr "Source empty"; mpause; return 1; }
    mok "Source: $(du -h "$src" | cut -f1)"

    echo -e "\n${CYAN}━━━ STEP 3: CONVERT ━━━${NC}"
    local mysql_sql="$MIGRATION_TEMP/mysql_import.sql"
    convert_migration_to_mysql "$src" "$mysql_sql" "$db_type" || { mpause; return 1; }
    cp "$mysql_sql" "$backup_dir/mysql_converted.sql" 2>/dev/null

    echo -e "\n${CYAN}━━━ STEP 4: STOP PASARGUARD ━━━${NC}"
    stop_migration_panel "$PASARGUARD_DIR" "Pasarguard"

    echo -e "\n${CYAN}━━━ STEP 5: CONFIGS ━━━${NC}"
    migrate_migration_configs

    echo -e "\n${CYAN}━━━ STEP 6: IMPORT ━━━${NC}"
    is_migration_running "$REBECCA_DIR" || start_migration_panel "$REBECCA_DIR" "Rebecca"
    wait_migration_mysql
    import_migration_to_rebecca "$mysql_sql" || { mpause; }

    echo -e "\n${CYAN}━━━ STEP 7: RESTART ━━━${NC}"
    (cd "$REBECCA_DIR" && docker compose restart) &>/dev/null
    sleep 3
    mok "Rebecca restarted"

    echo -e "\n${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Migration completed!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo "Backup: $backup_dir"

    migration_cleanup
    mpause
}

do_migration_rollback() {
    clear
    echo -e "${CYAN}=== ROLLBACK ===${NC}"
    [ ! -f "$BACKUP_ROOT/.last_backup" ] && { merr "No backup"; mpause; return 1; }
    local backup=$(cat "$BACKUP_ROOT/.last_backup")
    [ ! -d "$backup" ] && { merr "Backup missing"; mpause; return 1; }

    echo "Backup: $backup"
    read -p "Type 'rollback': " ans
    [ "$ans" != "rollback" ] && return 0

    migration_init
    stop_migration_panel "$REBECCA_DIR" "Rebecca"

    [ -f "$backup/pasarguard_config.tar.gz" ] && {
        rm -rf "$PASARGUARD_DIR"
        mkdir -p "$(dirname "$PASARGUARD_DIR")"
        tar -xzf "$backup/pasarguard_config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")"
        mok "Config restored"
    }
    [ -f "$backup/pasarguard_data.tar.gz" ] && {
        rm -rf "$PASARGUARD_DATA"
        mkdir -p "$(dirname "$PASARGUARD_DATA")"
        tar -xzf "$backup/pasarguard_data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")"
        mok "Data restored"
    }

    start_migration_panel "$PASARGUARD_DIR" "Pasarguard"
    echo -e "${GREEN}Rollback done${NC}"
    migration_cleanup
    mpause
}

migrator_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   MIGRATION TOOLS v11.0            ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
        echo ""
        echo " 1) Migrate Pasarguard → Rebecca"
        echo " 2) Rollback to Pasarguard"
        echo " 3) View Backups"
        echo " 4) View Log"
        echo " 0) Back"
        echo ""
        read -p "Select: " opt
        case "$opt" in
            1) do_full_migration ;;
            2) do_migration_rollback ;;
            3) clear; ls -lh "$BACKUP_ROOT" 2>/dev/null || echo "No backups"; mpause ;;
            4) clear; tail -50 "$MIGRATION_LOG" 2>/dev/null || echo "No log"; mpause ;;
            0) return ;;
        esac
    done
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && migrator_menu