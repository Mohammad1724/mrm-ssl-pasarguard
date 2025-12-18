#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V9.5 (Final Production - Full Xray & Admin Fix)
#==============================================================================

# Load Utils & UI
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh 2>/dev/null; fi
source /opt/mrm-manager/ui.sh 2>/dev/null

# Fallback colors
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[0;33m}"
BLUE="${BLUE:-\033[0;34m}"
CYAN="${CYAN:-\033[0;36m}"
NC="${NC:-\033[0m}"

# --- CONFIGURATION ---
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
MIGRATION_LOG="${MIGRATION_LOG:-/var/log/mrm_migration.log}"
MIGRATION_TEMP=""

# Global variables
SRC=""
TGT=""
CURRENT_BACKUP=""
SOURCE_PANEL_TYPE=""

REBECCA_INSTALL_CMD="bash -c \"\$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)\" @ install --database mysql"

# Xray download URL
XRAY_VERSION="latest"
XRAY_DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

# --- HELPER FUNCTIONS ---

migration_init() {
    MIGRATION_TEMP=$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null) || MIGRATION_TEMP="/tmp/mrm-migration-$$"
    mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT"
    mkdir -p "$(dirname "$MIGRATION_LOG")" 2>/dev/null
    touch "$MIGRATION_LOG" 2>/dev/null
    echo "=== Migration Started: $(date) ===" >> "$MIGRATION_LOG"
}

migration_cleanup() { 
    [[ "$MIGRATION_TEMP" == /tmp/* ]] && rm -rf "$MIGRATION_TEMP" 2>/dev/null
}

mlog()   { echo "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG" 2>/dev/null; }
minfo()  { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()    { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn()  { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr()   { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }
mpause() { echo ""; echo -e "${YELLOW}Press any key to continue...${NC}"; read -n 1 -s -r; echo ""; }

# Fallback UI functions
if ! type ui_confirm &>/dev/null; then
    ui_confirm() {
        local prompt="$1"
        local default="${2:-y}"
        read -p "$prompt [y/n] ($default): " answer
        answer="${answer:-$default}"
        [[ "$answer" =~ ^[Yy] ]]
    }
fi

if ! type ui_header &>/dev/null; then
    ui_header() {
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  $1${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
        echo ""
    }
fi

# --- SMART PANEL DETECTION ---
detect_source_panel() {
    if [ -d "/opt/pasarguard" ] && [ -f "/opt/pasarguard/.env" ]; then
        SOURCE_PANEL_TYPE="pasarguard"
        echo "/opt/pasarguard"
        return 0
    fi
    if [ -d "/opt/marzban" ] && [ -f "/opt/marzban/.env" ]; then
        SOURCE_PANEL_TYPE="marzban"
        echo "/opt/marzban"
        return 0
    fi
    return 1
}

get_source_data_dir() {
    local src="$1"
    case "$src" in
        */pasarguard*) echo "/var/lib/pasarguard" ;;
        */marzban*)    echo "/var/lib/marzban" ;;
        *)             echo "/var/lib/$(basename "$src")" ;;
    esac
}

# --- DATABASE HELPERS ---

find_db_container() {
    local panel_dir="$1" type="$2"
    local keywords=""
    [ "$type" == "postgresql" ] && keywords="timescale|postgres|db"
    [ "$type" == "mysql" ] && keywords="mysql|mariadb|db"
    local cname=$(cd "$panel_dir" 2>/dev/null && docker compose ps --format '{{.Names}}' 2>/dev/null | grep -iE "$keywords" | head -1)
    [ -z "$cname" ] && cname=$(docker ps --format '{{.Names}}' | grep -iE "$(basename "$panel_dir").*($keywords)" | head -1)
    echo "$cname"
}

get_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    MIG_DB_USER=""; MIG_DB_PASS=""; MIG_DB_NAME=""
    
    [ ! -f "$env_file" ] && return 1
    
    local db_url=$(grep "^SQLALCHEMY_DATABASE_URL" "$env_file" | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    
    eval "$(python3 << PYEOF
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    try:
        scheme, rest = url.split('://', 1)
        if '+' in scheme: scheme = scheme.split('+', 1)[0]
        p = urlparse(scheme + '://' + rest)
        user = p.username or ""
        passwd = unquote(p.password or "")
        passwd = passwd.replace("'", "'\\''")
        dbname = (p.path or "").lstrip("/")
        print(f"MIG_DB_USER='{user}'")
        print(f"MIG_DB_PASS='{passwd}'")
        print(f"MIG_DB_NAME='{dbname}'")
    except Exception as e:
        print(f"# Error: {e}")
PYEOF
)"
}

detect_db_type() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    local data_dir=$(get_source_data_dir "$panel_dir")
    
    if [ -f "$env_file" ]; then
        local db_url=$(grep "^SQLALCHEMY_DATABASE_URL" "$env_file" | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        case "$db_url" in
            *postgresql*) echo "postgresql" ;;
            *mysql*)      echo "mysql" ;;
            *sqlite*)     echo "sqlite" ;;
            *) 
                if [ -f "$data_dir/db.sqlite3" ]; then 
                    echo "sqlite"
                else 
                    echo "unknown"
                fi 
                ;;
        esac
    else
        if [ -f "$data_dir/db.sqlite3" ]; then echo "sqlite"; else echo "unknown"; fi
    fi
}

# --- XRAY INSTALLATION (NEW) ---
install_xray() {
    local target_dir="$1"
    
    minfo "Installing Xray core..."
    
    mkdir -p "$target_dir/assets"
    
    # Try to copy from source panel first
    local src_data=$(get_source_data_dir "$SRC")
    
    if [ -f "$src_data/xray" ]; then
        minfo "Copying Xray from source panel..."
        cp "$src_data/xray" "$target_dir/xray"
        chmod +x "$target_dir/xray"
        mok "Xray copied from $src_data"
    else
        minfo "Downloading Xray..."
        cd /tmp
        
        # Clean up old files
        rm -f Xray-linux-64.zip xray geoip.dat geosite.dat 2>/dev/null
        
        # Download Xray
        if wget -q --show-progress "$XRAY_DOWNLOAD_URL" -O Xray-linux-64.zip; then
            unzip -o Xray-linux-64.zip -d "$target_dir/" >/dev/null 2>&1
            chmod +x "$target_dir/xray"
            mok "Xray downloaded and installed"
        else
            merr "Failed to download Xray"
            return 1
        fi
    fi
    
    # Copy assets from source if exists
    if [ -d "$src_data/assets" ]; then
        minfo "Copying assets from source..."
        cp -rn "$src_data/assets/"* "$target_dir/assets/" 2>/dev/null
    fi
    
    # Download geo files if missing
    if [ ! -f "$target_dir/assets/geoip.dat" ]; then
        minfo "Downloading geoip.dat..."
        wget -q --show-progress "$GEOIP_URL" -O "$target_dir/assets/geoip.dat" || mwarn "geoip.dat download failed"
    fi
    
    if [ ! -f "$target_dir/assets/geosite.dat" ]; then
        minfo "Downloading geosite.dat..."
        wget -q --show-progress "$GEOSITE_URL" -O "$target_dir/assets/geosite.dat" || mwarn "geosite.dat download failed"
    fi
    
    # Verify installation
    if [ -x "$target_dir/xray" ]; then
        local version=$("$target_dir/xray" version 2>/dev/null | head -1)
        mok "Xray installed: $version"
        return 0
    else
        merr "Xray installation verification failed"
        return 1
    fi
}

# --- COPY ALL DATA FILES (NEW) ---
copy_data_files() {
    local src_data="$1"
    local tgt_data="$2"
    
    minfo "Copying data files from $src_data to $tgt_data..."
    
    mkdir -p "$tgt_data"
    
    # Copy certificates
    if [ -d "$src_data/certs" ]; then
        mkdir -p "$tgt_data/certs"
        cp -rn "$src_data/certs/"* "$tgt_data/certs/" 2>/dev/null
        chmod -R 644 "$tgt_data/certs/"* 2>/dev/null
        find "$tgt_data/certs" -type d -exec chmod 755 {} + 2>/dev/null
        mok "Certificates copied"
    fi
    
    # Copy templates
    if [ -d "$src_data/templates" ]; then
        mkdir -p "$tgt_data/templates"
        cp -rn "$src_data/templates/"* "$tgt_data/templates/" 2>/dev/null
        mok "Templates copied"
    fi
    
    # Copy assets
    if [ -d "$src_data/assets" ]; then
        mkdir -p "$tgt_data/assets"
        cp -rn "$src_data/assets/"* "$tgt_data/assets/" 2>/dev/null
        mok "Assets copied"
    fi
    
    # Copy xray config if exists
    if [ -f "$src_data/xray_config.json" ]; then
        cp "$src_data/xray_config.json" "$tgt_data/xray_config.json" 2>/dev/null
        # Fix paths in config
        sed -i 's|/var/lib/pasarguard|/var/lib/rebecca|g' "$tgt_data/xray_config.json" 2>/dev/null
        sed -i 's|/var/lib/marzban|/var/lib/rebecca|g' "$tgt_data/xray_config.json" 2>/dev/null
        mok "Xray config copied"
    fi
}

install_rebecca_wizard() {
    clear
    ui_header "INSTALLING REBECCA"
    if ! ui_confirm "Proceed with Rebecca installation?" "y"; then return 1; fi
    eval "$REBECCA_INSTALL_CMD"
    if [ -d "/opt/rebecca" ]; then
        mok "Rebecca Installation Verified."
        return 0
    else
        merr "Installation failed."
        return 1
    fi
}

create_backup() {
    local SRC_DIR="$1"
    local DATA_DIR=$(get_source_data_dir "$SRC_DIR")
    
    minfo "Creating backup..."
    local ts=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$CURRENT_BACKUP"
    echo "$CURRENT_BACKUP" > "$BACKUP_ROOT/.last_backup"
    echo "$SRC_DIR" > "$BACKUP_ROOT/.last_source"
    echo "$SOURCE_PANEL_TYPE" > "$CURRENT_BACKUP/panel_type.txt"
    
    # Backup config
    tar --exclude='*/node_modules' --exclude='mysql' --exclude='postgres' \
        -C "$(dirname "$SRC_DIR")" -czf "$CURRENT_BACKUP/config.tar.gz" "$(basename "$SRC_DIR")" 2>/dev/null
    
    # Backup data
    tar --exclude='mysql' --exclude='postgres' \
        -C "$(dirname "$DATA_DIR")" -czf "$CURRENT_BACKUP/data.tar.gz" "$(basename "$DATA_DIR")" 2>/dev/null
    
    local db_type=$(detect_db_type "$SRC_DIR")
    echo "$db_type" > "$CURRENT_BACKUP/db_type.txt"
    local out="$CURRENT_BACKUP/database.sql"
    
    case "$db_type" in
        sqlite) 
            if [ -f "$DATA_DIR/db.sqlite3" ]; then
                cp "$DATA_DIR/db.sqlite3" "$CURRENT_BACKUP/database.sqlite3"
                mok "SQLite database exported"
            else
                merr "SQLite file not found at $DATA_DIR/db.sqlite3"
            fi
            ;;
        postgresql)
            local cname=$(find_db_container "$SRC_DIR" "postgresql")
            get_db_credentials "$SRC_DIR"
            local dbname="${MIG_DB_NAME:-$(basename "$SRC_DIR")}"
            docker exec "$cname" pg_dump -U "${MIG_DB_USER:-postgres}" -d "$dbname" \
                --data-only --column-inserts --disable-dollar-quoting > "$out" 2>/dev/null
            [ -s "$out" ] && mok "PostgreSQL exported" || merr "pg_dump failed"
            ;;
        mysql)
            local cname=$(find_db_container "$SRC_DIR" "mysql")
            get_db_credentials "$SRC_DIR"
            docker exec "$cname" mysqldump -u"${MIG_DB_USER:-root}" -p"${MIG_DB_PASS}" \
                --single-transaction "${MIG_DB_NAME:-marzban}" > "$out" 2>/dev/null
            [ -s "$out" ] && mok "MySQL exported" || merr "mysqldump failed"
            ;;
    esac
    
    mok "Backup created: $CURRENT_BACKUP"
}

convert_to_mysql() {
    local src="$1" dst="$2" type="$3"
    minfo "Converting $type → MySQL..."
    
    if [ "$type" == "sqlite" ] && [[ "$src" == *.sqlite3 ]]; then
        if ! command -v sqlite3 &>/dev/null; then
            minfo "Installing sqlite3..."
            apt-get update -qq && apt-get install -y sqlite3 -qq
        fi
        sqlite3 "$src" .dump > "$MIGRATION_TEMP/sqlite.sql"
        src="$MIGRATION_TEMP/sqlite.sql"
    fi
    
    python3 - "$src" "$dst" << 'PYEOF'
import re, sys

src, dst = sys.argv[1], sys.argv[2]

try:
    with open(src, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
except Exception as e:
    print(f"Error reading file: {e}")
    sys.exit(1)

out = []
header = """SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';

"""

for line in lines:
    l = line.strip()
    
    # Skip SQLite/Postgres specific commands
    if l.startswith(('PRAGMA', 'BEGIN TRANSACTION', 'COMMIT', '\\', '--')): 
        continue
    if l.upper().startswith('SET ') and 'FOREIGN_KEY' not in l.upper():
        continue
    if re.match(r'^SELECT\s+(pg_catalog|setval)', l, re.I): 
        continue
    
    # SQLite → MySQL conversions
    line = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', line, flags=re.I)
    line = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', line, flags=re.I)
    line = re.sub(r'\bBOOLEAN\b', 'TINYINT(1)', line, flags=re.I)
    line = line.replace("'t'", "1").replace("'f'", "0")
    
    # Timestamp fix
    line = re.sub(r"'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(\.\d+)?\+00(:00)?'", r"'\1'", line)
    
    # Path replacements
    line = line.replace('/var/lib/pasarguard', '/var/lib/rebecca')
    line = line.replace('/opt/pasarguard', '/opt/rebecca')
    line = line.replace('/var/lib/marzban', '/var/lib/rebecca')
    line = line.replace('/opt/marzban', '/opt/rebecca')
    
    # Convert INSERT to REPLACE
    if re.match(r'^\s*INSERT\s+INTO\b', line, re.I):
        line = re.sub(r'^\s*INSERT\s+INTO', 'REPLACE INTO', line, flags=re.I)
        line = re.sub(r'public\."?(\w+)"?', r'`\1`', line)
    
    out.append(line)

try:
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(header + "".join(out) + "\nSET FOREIGN_KEY_CHECKS=1;\n")
except Exception as e:
    print(f"Error writing file: {e}")
    sys.exit(1)
PYEOF

    [ -s "$dst" ] && mok "Converted successfully" || { merr "Conversion failed"; return 1; }
}

# --- SMART ENV READER ---
read_var() {
    local key="$1"
    local file="$2"
    [ ! -f "$file" ] && return
    grep -E "^\s*${key}\s*=" "$file" | head -1 | sed -E "s/^\s*${key}\s*=\s*//g" | sed -E 's/^"//;s/"$//;s/^\x27//;s/\x27$//'
}

# --- CLEAN ENV CONSTRUCTION ---
generate_clean_env() {
    local src="$1"
    local tgt="$2"
    local tgt_env="$tgt/.env"
    local src_env="$src/.env"

    minfo "Building .env file..."

    # Get existing password or generate new
    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt_env")
    [ -z "$DB_PASS" ] && DB_PASS=$(openssl rand -hex 16)

    local UV_PORT=$(read_var "UVICORN_PORT" "$src_env")
    [ -z "$UV_PORT" ] && UV_PORT="7431"

    local SUDO_USER=$(read_var "SUDO_USERNAME" "$src_env")
    local SUDO_PASS=$(read_var "SUDO_PASSWORD" "$src_env")
    [ -z "$SUDO_USER" ] && SUDO_USER="admin"
    [ -z "$SUDO_PASS" ] && SUDO_PASS="admin"

    # Telegram
    local TG_TOKEN=$(read_var "TELEGRAM_API_TOKEN" "$src_env")
    [ -z "$TG_TOKEN" ] && TG_TOKEN=$(read_var "BACKUP_TELEGRAM_BOT_KEY" "$src_env")
    
    local TG_ADMIN=$(read_var "TELEGRAM_ADMIN_ID" "$src_env")
    [ -z "$TG_ADMIN" ] && TG_ADMIN=$(read_var "BACKUP_TELEGRAM_CHAT_ID" "$src_env")

    # SSL - fix paths
    local SSL_CERT=$(read_var "UVICORN_SSL_CERTFILE" "$src_env")
    local SSL_KEY=$(read_var "UVICORN_SSL_KEYFILE" "$src_env")
    SSL_CERT="${SSL_CERT/\/var\/lib\/pasarguard/\/var\/lib\/rebecca}"
    SSL_KEY="${SSL_KEY/\/var\/lib\/pasarguard/\/var\/lib\/rebecca}"
    SSL_CERT="${SSL_CERT/\/var\/lib\/marzban/\/var\/lib\/rebecca}"
    SSL_KEY="${SSL_KEY/\/var\/lib\/marzban/\/var\/lib\/rebecca}"

    # Templates
    local TPL_DIR=$(read_var "CUSTOM_TEMPLATES_DIRECTORY" "$src_env")
    TPL_DIR="${TPL_DIR/\/var\/lib\/pasarguard/\/var\/lib\/rebecca}"
    TPL_DIR="${TPL_DIR/\/var\/lib\/marzban/\/var\/lib\/rebecca}"

    local TPL_PAGE=$(read_var "SUBSCRIPTION_PAGE_TEMPLATE" "$src_env")
    local XRAY_JSON=$(read_var "XRAY_JSON" "$src_env")
    XRAY_JSON="${XRAY_JSON/\/var\/lib\/pasarguard/\/var\/lib\/rebecca}"
    XRAY_JSON="${XRAY_JSON/\/var\/lib\/marzban/\/var\/lib\/rebecca}"
    
    local SUB_URL=$(read_var "XRAY_SUBSCRIPTION_URL_PREFIX" "$src_env")

    # Generate secrets
    local SECRET_KEY=$(openssl rand -hex 32)
    local JWT_ACCESS=$(openssl rand -hex 32)
    local JWT_REFRESH=$(openssl rand -hex 32)

    cat > "$tgt_env" <<EOF
# Database
SQLALCHEMY_DATABASE_URL="mysql+pymysql://root:${DB_PASS}@127.0.0.1:3306/rebecca"
MYSQL_ROOT_PASSWORD="${DB_PASS}"
MYSQL_DATABASE="rebecca"
MYSQL_USER="rebecca"
MYSQL_PASSWORD="${DB_PASS}"

# Server
UVICORN_HOST="0.0.0.0"
UVICORN_PORT="${UV_PORT}"
UVICORN_SSL_CERTFILE="${SSL_CERT}"
UVICORN_SSL_KEYFILE="${SSL_KEY}"

# Admin
SUDO_USERNAME="${SUDO_USER}"
SUDO_PASSWORD="${SUDO_PASS}"

# Telegram
TELEGRAM_API_TOKEN="${TG_TOKEN}"
TELEGRAM_ADMIN_ID="${TG_ADMIN}"

# Xray
XRAY_JSON="${XRAY_JSON}"
XRAY_SUBSCRIPTION_URL_PREFIX="${SUB_URL}"
XRAY_EXECUTABLE_PATH="/var/lib/rebecca/xray"
XRAY_ASSETS_PATH="/var/lib/rebecca/assets"

# Templates
CUSTOM_TEMPLATES_DIRECTORY="${TPL_DIR}"
SUBSCRIPTION_PAGE_TEMPLATE="${TPL_PAGE}"

# JWT & Security
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440
SECRET_KEY="${SECRET_KEY}"
JWT_ACCESS_TOKEN_SECRET="${JWT_ACCESS}"
JWT_REFRESH_TOKEN_SECRET="${JWT_REFRESH}"
EOF

    mok "Environment file created"
}

# --- SMART SQL PREPROCESSOR ---
preprocess_sql_smart() {
    local input_sql="$1"
    local output_sql="$2"
    local panel_type="$3"
    local jwt_secret="$4"
    local sub_secret="$5"
    local admin_secret="$6"
    local vmess_mask="$7"
    local vless_mask="$8"

    minfo "Pre-processing SQL for $panel_type..."

    python3 - "$input_sql" "$output_sql" "$panel_type" "$jwt_secret" "$sub_secret" "$admin_secret" "$vmess_mask" "$vless_mask" << 'PYEOF'
import re
import sys

if len(sys.argv) < 9:
    print("Error: Not enough arguments")
    sys.exit(1)

sql_file = sys.argv[1]
output_file = sys.argv[2]
panel_type = sys.argv[3]
jwt_secret = sys.argv[4]
sub_secret = sys.argv[5]
admin_secret = sys.argv[6]
vmess_mask = sys.argv[7]
vless_mask = sys.argv[8]

try:
    with open(sql_file, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
except Exception as e:
    print(f"Error reading SQL file: {e}")
    sys.exit(1)

lines = content.split('\n')
new_lines = []
in_jwt_statement = False
brace_count = 0

for line in lines:
    line_lower = line.lower().strip()
    
    # Skip JWT inserts (they might have NULL values)
    if re.search(r'(insert|replace)\s+(into\s+)?[`"\']?jwt[`"\']?\s*[\(]', line_lower):
        in_jwt_statement = True
        brace_count = line.count('(') - line.count(')')
        new_lines.append('-- [MRM] JWT INSERT REMOVED')
        if ';' in line and brace_count <= 0:
            in_jwt_statement = False
        continue
    
    if in_jwt_statement:
        brace_count += line.count('(') - line.count(')')
        if ';' in line:
            in_jwt_statement = False
        continue
    
    new_lines.append(line)

content = '\n'.join(new_lines)

# Add JWT table and fresh data
jwt_section = f"""

-- ============================================
-- [MRM Migration Tool V9.5] JWT Setup
-- Source: {panel_type}
-- ============================================

CREATE TABLE IF NOT EXISTS `jwt` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `secret_key` VARCHAR(255) NOT NULL,
    `subscription_secret_key` VARCHAR(255) DEFAULT NULL,
    `admin_secret_key` VARCHAR(255) DEFAULT NULL,
    `vmess_mask` VARCHAR(64) DEFAULT NULL,
    `vless_mask` VARCHAR(64) DEFAULT NULL,
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DELETE FROM `jwt`;

INSERT INTO `jwt` (`secret_key`, `subscription_secret_key`, `admin_secret_key`, `vmess_mask`, `vless_mask`) 
VALUES ('{jwt_secret}', '{sub_secret}', '{admin_secret}', '{vmess_mask}', '{vless_mask}');

-- ============================================

"""

content = content + jwt_section

try:
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(content)
    print("OK")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYEOF

    if [ -f "$output_sql" ] && [ -s "$output_sql" ]; then
        mok "SQL pre-processed"
        return 0
    else
        mwarn "SQL pre-process failed"
        return 1
    fi
}

# --- SCHEMA FIXES ---
apply_schema_fixes() {
    local cname="$1"
    local user="$2"
    local pass="$3"
    local db="$4"
    local panel_type="$5"

    run_sql() { 
        docker exec "$cname" mysql -u"$user" -p"$pass" "$db" -N -e "$1" 2>/dev/null
    }

    minfo "Applying schema fixes for $panel_type..."

    # Common fixes
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS is_sudo TINYINT(1) DEFAULT 0;"
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS is_disabled TINYINT(1) DEFAULT 0;"
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS permissions JSON;"
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS data_limit BIGINT DEFAULT 0;"
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS users_limit INT DEFAULT 0;"

    # Marzban-specific
    if [ "$panel_type" == "marzban" ]; then
        minfo "Applying Marzban-specific fixes..."
        run_sql "ALTER TABLE users ADD COLUMN IF NOT EXISTS sub_updated_at TIMESTAMP NULL;"
        run_sql "ALTER TABLE users ADD COLUMN IF NOT EXISTS sub_last_user_agent VARCHAR(512) NULL;"
        run_sql "ALTER TABLE users ADD COLUMN IF NOT EXISTS online_at TIMESTAMP NULL;"
    fi

    mok "Schema fixes applied"
}

# --- FIX ADMIN PASSWORDS (NEW) ---
fix_admin_passwords() {
    local cname="$1"
    local user="$2"
    local pass="$3"
    local db="$4"
    local src_env="$5"

    minfo "Fixing admin passwords..."

    run_sql() { 
        docker exec "$cname" mysql -u"$user" -p"$pass" "$db" -N -e "$1" 2>/dev/null
    }

    # Get SUDO credentials from source
    local sudo_user=$(read_var "SUDO_USERNAME" "$src_env")
    local sudo_pass=$(read_var "SUDO_PASSWORD" "$src_env")
    
    [ -z "$sudo_user" ] && sudo_user="admin"
    [ -z "$sudo_pass" ] && sudo_pass="admin"

    # Generate bcrypt hash for the password
    local hashed_pass=$(python3 -c "
import bcrypt
password = '$sudo_pass'
hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
print(hashed)
" 2>/dev/null)

    if [ -n "$hashed_pass" ]; then
        # Update existing admin or create new
        run_sql "UPDATE admins SET hashed_password='$hashed_pass', is_sudo=1, is_disabled=0 WHERE username='$sudo_user';"
        
        # Check if admin exists
        local admin_exists=$(run_sql "SELECT COUNT(*) FROM admins WHERE username='$sudo_user';" | tr -d '[:space:]')
        
        if [ "$admin_exists" == "0" ]; then
            minfo "Creating admin user: $sudo_user"
            run_sql "INSERT INTO admins (username, hashed_password, is_sudo, is_disabled, permissions) VALUES ('$sudo_user', '$hashed_pass', 1, 0, '[]');"
        fi
        
        mok "Admin '$sudo_user' password synchronized"
    else
        mwarn "Could not generate password hash (bcrypt not available)"
        minfo "You can reset password manually with: docker exec -it rebecca-rebecca-1 rebecca-cli admin update $sudo_user --password NEW_PASSWORD"
    fi
}

# --- MAIN IMPORT FUNCTION ---
import_and_sanitize() {
    local SQL="$1" 
    local TGT_DIR="$2"
    local PANEL_TYPE="$3"
    local SRC_DIR="$4"
    
    minfo "Starting data import (Source: $PANEL_TYPE)..."
    
    get_db_credentials "$TGT_DIR"
    local user="${MIG_DB_USER:-root}"
    local pass="${MIG_DB_PASS}"
    [ -z "$pass" ] && pass=$(grep "MYSQL_ROOT_PASSWORD" "$TGT_DIR/.env" | cut -d'=' -f2- | tr -d '"')

    local cname=$(find_db_container "$TGT_DIR" "mysql")
    if [ -z "$cname" ]; then
        merr "Target MySQL container not found"
        return 1
    fi
    minfo "Using MySQL container: $cname"

    # Wait for MySQL
    minfo "Waiting for MySQL..."
    local max_wait=60
    local waited=0
    while ! docker exec "$cname" mysqladmin ping -u"$user" -p"$pass" --silent 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ $waited -ge $max_wait ]; then
            merr "MySQL not ready after ${max_wait}s"
            return 1
        fi
        echo -n "."
    done
    echo ""
    mok "MySQL is ready"

    # Create database
    local db="rebecca"
    docker exec "$cname" mysql -u"$user" -p"$pass" -e \
        "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null

    # Generate secrets
    local JWT_SECRET=$(openssl rand -hex 64)
    local SUB_SECRET=$(openssl rand -hex 64)
    local ADMIN_SECRET=$(openssl rand -hex 64)
    local VMESS_MASK=$(openssl rand -hex 16)
    local VLESS_MASK=$(openssl rand -hex 16)

    # Pre-process SQL
    local FIXED_SQL="${SQL}.fixed"
    if preprocess_sql_smart "$SQL" "$FIXED_SQL" "$PANEL_TYPE" \
        "$JWT_SECRET" "$SUB_SECRET" "$ADMIN_SECRET" "$VMESS_MASK" "$VLESS_MASK"; then
        SQL="$FIXED_SQL"
    fi

    # Import SQL
    minfo "Importing SQL..."
    local import_output=$(docker exec -i "$cname" mysql --binary-mode=1 -u"$user" -p"$pass" "$db" < "$SQL" 2>&1)
    local import_result=$?
    
    if [ $import_result -ne 0 ]; then
        mwarn "Import had some warnings:"
        echo "$import_output" | grep -i error | head -5
    else
        mok "SQL imported"
    fi

    run_sql() { 
        docker exec "$cname" mysql -u"$user" -p"$pass" "$db" -N -e "$1" 2>/dev/null
    }

    # Apply schema fixes
    apply_schema_fixes "$cname" "$user" "$pass" "$db" "$PANEL_TYPE"

    # Sanitize data
    minfo "Sanitizing data..."
    run_sql "UPDATE admins SET permissions='[]' WHERE permissions IS NULL;"
    run_sql "UPDATE admins SET data_limit=0 WHERE data_limit IS NULL;"
    run_sql "UPDATE admins SET users_limit=0 WHERE users_limit IS NULL;"
    run_sql "UPDATE admins SET is_sudo=1 WHERE is_sudo IS NULL;"
    run_sql "UPDATE admins SET is_disabled=0 WHERE is_disabled IS NULL;"
    
    # Path replacements
    run_sql "UPDATE nodes SET server_ca = REPLACE(server_ca, '/var/lib/pasarguard', '/var/lib/rebecca') WHERE server_ca LIKE '%pasarguard%';"
    run_sql "UPDATE nodes SET server_ca = REPLACE(server_ca, '/var/lib/marzban', '/var/lib/rebecca') WHERE server_ca LIKE '%marzban%';"
    run_sql "UPDATE core_configs SET config = REPLACE(config, '/var/lib/pasarguard', '/var/lib/rebecca') WHERE config LIKE '%pasarguard%';"
    run_sql "UPDATE core_configs SET config = REPLACE(config, '/var/lib/marzban', '/var/lib/rebecca') WHERE config LIKE '%marzban%';"

    # Fix admin passwords
    fix_admin_passwords "$cname" "$user" "$pass" "$db" "$SRC_DIR/.env"

    # Verify JWT
    minfo "Verifying JWT..."
    local jwt_check=$(run_sql "SELECT secret_key FROM jwt LIMIT 1;" | tr -d '[:space:]')
    
    if [ -z "$jwt_check" ] || [ "$jwt_check" == "NULL" ]; then
        mwarn "JWT table issue, fixing..."
        run_sql "INSERT INTO jwt (secret_key, subscription_secret_key, admin_secret_key, vmess_mask, vless_mask) VALUES ('${JWT_SECRET}', '${SUB_SECRET}', '${ADMIN_SECRET}', '${VMESS_MASK}', '${VLESS_MASK}');"
    fi
    
    mok "Data import complete"
    return 0
}

# --- STOP OLD NODES ---
stop_old_nodes() {
    minfo "Stopping old panel nodes..."
    
    # Stop pasarguard nodes
    docker ps --format '{{.Names}}' | grep -iE "pasarguard|node" | while read container; do
        if [[ "$container" != *"rebecca"* ]]; then
            minfo "Stopping: $container"
            docker stop "$container" 2>/dev/null
        fi
    done
    
    mok "Old nodes stopped"
}

create_rescue_admin() {
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Admin Account Information${NC}"
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo ""
    
    local sudo_user=$(read_var "SUDO_USERNAME" "$SRC/.env")
    local sudo_pass=$(read_var "SUDO_PASSWORD" "$SRC/.env")
    [ -z "$sudo_user" ] && sudo_user="admin"
    [ -z "$sudo_pass" ] && sudo_pass="admin"
    
    echo -e "  Username: ${GREEN}$sudo_user${NC}"
    echo -e "  Password: ${GREEN}$sudo_pass${NC}"
    echo ""
    
    if ui_confirm "Create additional SuperAdmin?" "n"; then
        local cname=$(docker ps --format '{{.Names}}' | grep rebecca | grep -v mysql | head -1)
        if [ -n "$cname" ]; then
            docker exec -it "$cname" rebecca-cli admin create 2>/dev/null || \
            mwarn "Could not create admin via CLI"
        fi
    fi
}

do_full_migration() {
    migration_init
    clear
    ui_header "MRM MIGRATION TOOL V9.5"
    
    echo -e "${CYAN}Full Migration with Xray & Admin Password Fix${NC}"
    echo ""
    
    # Detect source
    SRC=$(detect_source_panel)
    if [ -z "$SRC" ]; then
        merr "No source panel found (Pasarguard/Marzban)"
        mpause
        return 1
    fi
    
    local SRC_DATA=$(get_source_data_dir "$SRC")
    
    minfo "Detected: $SOURCE_PANEL_TYPE at $SRC"
    minfo "Data dir: $SRC_DATA"
    
    # Detect/install target
    if [ -d "/opt/rebecca" ]; then
        TGT="/opt/rebecca"
    else
        minfo "Rebecca not installed"
        if ! install_rebecca_wizard; then
            mpause
            return 1
        fi
        TGT="/opt/rebecca"
    fi
    
    local TGT_DATA="/var/lib/rebecca"
    
    echo ""
    echo -e "  ${RED}Source:${NC} $SOURCE_PANEL_TYPE ($SRC)"
    echo -e "  ${GREEN}Target:${NC} rebecca ($TGT)"
    echo ""
    
    if ! ui_confirm "Start Migration?" "y"; then
        return 0
    fi

    echo ""
    
    # Step 1: Backup
    minfo "[1/7] Creating backup..."
    create_backup "$SRC"
    [ -z "$CURRENT_BACKUP" ] && { merr "Backup failed"; mpause; return 1; }

    # Step 2: Convert SQL
    minfo "[2/7] Converting database..."
    local db_type=$(cat "$CURRENT_BACKUP/db_type.txt" 2>/dev/null)
    local src_sql="$CURRENT_BACKUP/database.sql"
    [ "$db_type" == "sqlite" ] && src_sql="$CURRENT_BACKUP/database.sqlite3"
    
    local final_sql="$MIGRATION_TEMP/import.sql"
    convert_to_mysql "$src_sql" "$final_sql" "$db_type" || { mpause; return 1; }

    # Step 3: Stop services
    minfo "[3/7] Stopping services..."
    stop_old_nodes
    (cd "$SRC" && docker compose down 2>/dev/null) &>/dev/null
    (cd "$TGT" && docker compose down 2>/dev/null) &>/dev/null
    sleep 3

    # Step 4: Copy data files & Install Xray
    minfo "[4/7] Copying data files..."
    copy_data_files "$SRC_DATA" "$TGT_DATA"
    install_xray "$TGT_DATA"

    # Step 5: Generate env
    minfo "[5/7] Configuring Rebecca..."
    generate_clean_env "$SRC" "$TGT"

    # Step 6: Start and import
    minfo "[6/7] Starting Rebecca & importing data..."
    (cd "$TGT" && docker compose up -d --force-recreate)
    
    minfo "Waiting for services..."
    sleep 30

    import_and_sanitize "$final_sql" "$TGT" "$SOURCE_PANEL_TYPE" "$SRC" || { 
        mwarn "Import had issues"
    }

    # Step 7: Final restart
    minfo "[7/7] Final restart..."
    (cd "$TGT" && docker compose down && sleep 5 && docker compose up -d)
    sleep 20

    # Verify
    echo ""
    minfo "Verifying installation..."
    
    local panel_ok=$(docker ps --format '{{.Names}}' | grep rebecca | grep -v mysql | head -1)
    if [ -n "$panel_ok" ]; then
        mok "Panel running: $panel_ok"
    else
        mwarn "Panel container not detected"
    fi
    
    # Check Xray
    local xray_status=$(docker logs "$panel_ok" 2>&1 | grep -i "xray" | tail -3)
    if [[ "$xray_status" == *"not found"* ]]; then
        mwarn "Xray might have issues"
    else
        mok "Xray should be working"
    fi

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        MIGRATION COMPLETED SUCCESSFULLY!         ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Migrated: ${YELLOW}$SOURCE_PANEL_TYPE${NC} → ${GREEN}rebecca${NC}"
    echo ""
    
    create_rescue_admin
    migration_cleanup
    mpause
}

do_rollback() {
    clear
    ui_header "ROLLBACK"
    
    local last=$(cat "$BACKUP_ROOT/.last_backup" 2>/dev/null)
    local src_path=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    
    if [ -z "$last" ] || [ ! -d "$last" ]; then
        merr "No backup found"
        mpause
        return 1
    fi
    
    local panel_type=$(cat "$last/panel_type.txt" 2>/dev/null)
    
    echo "Backup: $last"
    echo "Original Panel: $panel_type at $src_path"
    echo ""
    
    if ui_confirm "Restore?" "n"; then
        minfo "Stopping Rebecca..."
        (cd /opt/rebecca && docker compose down 2>/dev/null) &>/dev/null
        
        minfo "Restoring files..."
        tar -xzf "$last/config.tar.gz" -C "$(dirname "$src_path")" 2>/dev/null
        tar -xzf "$last/data.tar.gz" -C "/var/lib" 2>/dev/null
        
        minfo "Starting $panel_type..."
        (cd "$src_path" && docker compose up -d 2>/dev/null) &>/dev/null
        
        mok "Rollback Complete"
    fi
    mpause
}

do_fix_current() {
    clear
    ui_header "FIX CURRENT INSTALLATION"
    
    if [ ! -d "/opt/rebecca" ]; then
        merr "Rebecca not installed"
        mpause
        return 1
    fi
    
    TGT="/opt/rebecca"
    SRC=$(detect_source_panel)
    local SRC_DATA=$(get_source_data_dir "$SRC")
    local TGT_DATA="/var/lib/rebecca"
    
    echo "This will fix:"
    echo "  - Install/update Xray"
    echo "  - Copy missing files"
    echo "  - Fix admin passwords"
    echo ""
    
    if ! ui_confirm "Proceed?" "y"; then
        return 0
    fi
    
    minfo "Stopping Rebecca..."
    (cd "$TGT" && docker compose down) &>/dev/null
    
    minfo "Copying data files..."
    copy_data_files "$SRC_DATA" "$TGT_DATA"
    
    minfo "Installing Xray..."
    install_xray "$TGT_DATA"
    
    minfo "Starting Rebecca..."
    (cd "$TGT" && docker compose up -d)
    sleep 20
    
    # Fix admin password
    local cname=$(find_db_container "$TGT" "mysql")
    get_db_credentials "$TGT"
    local user="${MIG_DB_USER:-root}"
    local pass="${MIG_DB_PASS}"
    [ -z "$pass" ] && pass=$(grep "MYSQL_ROOT_PASSWORD" "$TGT/.env" | cut -d'=' -f2- | tr -d '"')
    
    fix_admin_passwords "$cname" "$user" "$pass" "rebecca" "$SRC/.env"
    
    # Final restart
    minfo "Final restart..."
    (cd "$TGT" && docker compose down && docker compose up -d)
    sleep 15
    
    mok "Fix complete!"
    
    local sudo_user=$(read_var "SUDO_USERNAME" "$SRC/.env")
    local sudo_pass=$(read_var "SUDO_PASSWORD" "$SRC/.env")
    echo ""
    echo -e "Login with: ${GREEN}$sudo_user${NC} / ${GREEN}$sudo_pass${NC}"
    
    mpause
}

view_logs() {
    clear
    ui_header "MIGRATION LOGS"
    [ -f "$MIGRATION_LOG" ] && tail -100 "$MIGRATION_LOG" || echo "No logs"
    mpause
}

view_status() {
    clear
    ui_header "SYSTEM STATUS"
    
    echo -e "${CYAN}Docker Containers:${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20
    
    echo ""
    echo -e "${CYAN}Rebecca Logs (last 20 lines):${NC}"
    docker logs rebecca-rebecca-1 --tail 20 2>&1 | tail -20
    
    mpause
}

migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION TOOL V9.5"
        echo ""
        echo -e "  ${GREEN}Supports:${NC}"
        echo "    • Marzban    → Rebecca"
        echo "    • Pasarguard → Rebecca"
        echo ""
        echo -e "  ${CYAN}Options:${NC}"
        echo "    1) Full Migration (Recommended)"
        echo "    2) Fix Current Installation"
        echo "    3) Rollback to Previous"
        echo "    4) View Status"
        echo "    5) View Logs"
        echo ""
        echo "    0) Exit"
        echo ""
        read -p "Select: " opt
        case "$opt" in
            1) do_full_migration ;;
            2) do_fix_current ;;
            3) do_rollback ;;
            4) view_status ;;
            5) view_logs ;;
            0|q) return 0 ;;
        esac
    done
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [ "$EUID" -ne 0 ] && { echo "Please run as root (sudo)"; exit 1; }
    command -v docker &>/dev/null || { echo "Docker is required"; exit 1; }
    command -v python3 &>/dev/null || { echo "Python3 is required"; exit 1; }
    
    # Install bcrypt if missing
    python3 -c "import bcrypt" 2>/dev/null || {
        echo "Installing bcrypt..."
        pip3 install bcrypt -q 2>/dev/null || apt-get install -y python3-bcrypt -qq 2>/dev/null
    }
    
    migrator_menu
fi