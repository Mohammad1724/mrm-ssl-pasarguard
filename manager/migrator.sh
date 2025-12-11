#!/usr/bin/env bash
# Pasarguard -> Rebecca Migration Tool (Official Installer Method - Production Ready)
# Fixed: Security, Rollback, Validation, Race Conditions

set -euo pipefail

# -----------------------
# Configuration
# -----------------------
readonly PASARGUARD_DIR="/opt/pasarguard"
readonly REBECCA_DIR="/opt/rebecca"
readonly REBECCA_DATA_DIR="/var/lib/rebecca"
readonly BACKUP_ROOT="/var/backups/migration"
readonly TEMP_DB="/tmp/migration_export_$$.sqlite3"
readonly TEMP_INSTALLER="/tmp/rebecca_installer_$$.sh"
readonly LOG_FILE="/var/log/mrm_migration.log"
readonly EXPORT_IN_CONTAINER="/tmp/dump.sqlite3"

# Rebecca Installer URL (GitHub)
readonly REBECCA_INSTALL_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"

# Timeouts
readonly DB_WAIT_TIMEOUT=60
readonly CONTAINER_START_TIMEOUT=30
readonly VERIFY_TIMEOUT=30

# -----------------------
# Colors
# -----------------------
readonly CYAN="$(tput setaf 6 2>/dev/null || echo '')"
readonly YELLOW="$(tput setaf 3 2>/dev/null || echo '')"
readonly GREEN="$(tput setaf 2 2>/dev/null || echo '')"
readonly RED="$(tput setaf 1 2>/dev/null || echo '')"
readonly BLUE="$(tput setaf 4 2>/dev/null || echo '')"
readonly NC="$(tput sgr0 2>/dev/null || echo '')"

# -----------------------
# Logging Functions
# -----------------------
log() {
  local msg="[$(date +'%T')] $*"
  echo -e "${BLUE}→${NC} $*"
  echo "$msg" >> "$LOG_FILE"
}

success() {
  local msg="[$(date +'%T')] ✓ $*"
  echo -e "${GREEN}✓${NC} $*"
  echo "$msg" >> "$LOG_FILE"
}

warn() {
  local msg="[$(date +'%T')] ⚠ $*"
  echo -e "${YELLOW}⚠${NC} $*" >&2
  echo "$msg" >> "$LOG_FILE"
}

error() {
  local msg="[$(date +'%T')] ✗ $*"
  echo -e "${RED}✗${NC} $*" >&2
  echo "$msg" >> "$LOG_FILE"
}

pause() { 
  echo ""
  read -rp "Press Enter to continue..." 
}

# -----------------------
# Rollback System
# -----------------------
declare -a ROLLBACK_CMDS=()
ROLLBACK_ENABLED=false

enable_rollback() {
  ROLLBACK_ENABLED=true
  trap 'handle_error' ERR
}

disable_rollback() {
  ROLLBACK_ENABLED=false
  trap - ERR
}

push_rollback() {
  local cmd=$1
  ROLLBACK_CMDS+=("$cmd")
}

handle_error() {
  local exit_code=$?
  if [ "$ROLLBACK_ENABLED" = true ]; then
    run_rollback
  fi
  exit "$exit_code"
}

run_rollback() {
  echo ""
  error "════════════════════════════════════════"
  error "  MIGRATION FAILED - STARTING ROLLBACK"
  error "════════════════════════════════════════"
  echo ""
  
  if [ ${#ROLLBACK_CMDS[@]} -eq 0 ]; then
    warn "No rollback actions registered"
    return 0
  fi
  
  for (( i=${#ROLLBACK_CMDS[@]}-1; i>=0; i-- )); do
    local cmd="${ROLLBACK_CMDS[i]}"
    log "Rollback [$((${#ROLLBACK_CMDS[@]} - i))/${#ROLLBACK_CMDS[@]}]: $cmd"
    
    if eval "$cmd"; then
      success "Rollback step succeeded"
    else
      warn "Rollback step failed (continuing...)"
    fi
  done
  
  echo ""
  success "Rollback completed - Pasarguard should be restored"
  pause
}

# -----------------------
# Validation Functions
# -----------------------
check_root() {
  if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (use sudo)"
    exit 1
  fi
}

check_dependencies() {
  local deps=("docker" "curl" "wget" "sqlite3")
  local missing=()
  
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing dependencies: ${missing[*]}"
    error "Install with: apt install -y ${missing[*]}"
    exit 1
  fi
  
  if ! docker compose version &> /dev/null; then
    error "Docker Compose V2 not found"
    exit 1
  fi
  
  success "All dependencies installed"
}

check_disk_space() {
  local min_space_kb=524288  # 512MB
  local available
  available=$(df /tmp | tail -1 | awk '{print $4}')
  
  if [ "$available" -lt "$min_space_kb" ]; then
    error "Insufficient disk space in /tmp"
    error "Required: $((min_space_kb / 1024))MB, Available: $((available / 1024))MB"
    return 1
  fi
  
  return 0
}

check_port_availability() {
  local ports=(8000 8080 443 80)
  local in_use=()
  
  for port in "${ports[@]}"; do
    if netstat -tuln 2>/dev/null | grep -q ":${port} " || \
       ss -tuln 2>/dev/null | grep -q ":${port} "; then
      # Check if it's Pasarguard (we'll stop it)
      if ! docker ps --format '{{.Ports}}' 2>/dev/null | grep -q "${port}"; then
        in_use+=("$port")
      fi
    fi
  done
  
  if [ ${#in_use[@]} -gt 0 ]; then
    warn "Ports in use by other services: ${in_use[*]}"
    warn "Rebecca installer might fail if it needs these ports"
    echo ""
    read -rp "Continue anyway? (yes/no): " answer
    if [ "$answer" != "yes" ]; then
      exit 0
    fi
  fi
}

validate_sqlite_file() {
  local file=$1
  
  if [ ! -f "$file" ]; then
    error "Database file not found: $file"
    return 1
  fi
  
  if ! head -c 16 "$file" 2>/dev/null | grep -q "SQLite format 3"; then
    error "Invalid SQLite database header: $file"
    return 1
  fi
  
  if ! sqlite3 "$file" "PRAGMA integrity_check;" &> /dev/null; then
    error "Database integrity check failed: $file"
    return 1
  fi
  
  local size
  size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
  if [ "$size" -lt 8192 ]; then
    error "Database file too small (${size} bytes), likely corrupted"
    return 1
  fi
  
  success "Database validation passed (size: $((size / 1024))KB)"
  return 0
}

# -----------------------
# Container Management
# -----------------------
find_pasarguard_container() {
  local compose_file="$PASARGUARD_DIR/docker-compose.yml"
  
  if [ ! -f "$compose_file" ]; then
    error "Docker compose file not found: $compose_file"
    return 1
  fi
  
  cd "$PASARGUARD_DIR" || return 1
  
  # Try to find marzban service
  local container_id
  container_id=$(docker compose ps -q marzban 2>/dev/null | head -1)
  
  if [ -z "$container_id" ]; then
    # Fallback: find any container excluding databases
    container_id=$(docker compose ps -q 2>/dev/null | \
      while read -r cid; do
        local image
        image=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null)
        if ! echo "$image" | grep -qE 'postgres|mysql|mariadb|redis|phpmyadmin'; then
          echo "$cid"
          break
        fi
      done)
  fi
  
  echo "$container_id"
}

wait_for_container_ready() {
  local container_id=$1
  local timeout=$2
  local counter=0
  
  log "Waiting for container to be ready (timeout: ${timeout}s)..."
  
  while [ $counter -lt "$timeout" ]; do
    if docker exec "$container_id" sh -c 'command -v marzban-cli' &> /dev/null; then
      # Try to run a simple command
      if docker exec "$container_id" marzban-cli --version &> /dev/null || \
         docker exec "$container_id" marzban-cli --help &> /dev/null; then
        success "Container is ready"
        return 0
      fi
    fi
    
    sleep 2
    counter=$((counter + 2))
    
    if [ $((counter % 10)) -eq 0 ]; then
      log "Still waiting... (${counter}s)"
    fi
  done
  
  error "Container did not become ready within ${timeout}s"
  return 1
}

# -----------------------
# Pasarguard Operations
# -----------------------
export_pasarguard_data() {
  log "═══ Step 1/6: Exporting Pasarguard Data ═══"
  
  if [ ! -d "$PASARGUARD_DIR" ]; then
    error "Pasarguard directory not found: $PASARGUARD_DIR"
    return 1
  fi
  
  cd "$PASARGUARD_DIR" || return 1
  
  # Find container
  local container_id
  container_id=$(find_pasarguard_container)
  
  if [ -z "$container_id" ]; then
    log "Pasarguard not running, starting temporarily..."
    docker compose up -d
    sleep 5
    
    container_id=$(find_pasarguard_container)
  fi
  
  if [ -z "$container_id" ]; then
    error "Could not find Pasarguard container"
    return 1
  fi
  
  success "Found container: $container_id"
  
  # Wait for readiness
  wait_for_container_ready "$container_id" "$DB_WAIT_TIMEOUT" || return 1
  
  # Sync database
  log "Syncing database..."
  docker exec "$container_id" marzban-cli sync 2>&1 | tee -a "$LOG_FILE" || {
    warn "Sync failed, continuing anyway..."
  }
  
  # Export database
  log "Exporting database (this may take a few minutes)..."
  if ! docker exec "$container_id" marzban-cli database dump --target "$EXPORT_IN_CONTAINER" 2>&1 | tee -a "$LOG_FILE"; then
    error "Database export command failed"
    return 1
  fi
  
  # Verify dump exists in container
  if ! docker exec "$container_id" sh -c "[ -f '$EXPORT_IN_CONTAINER' ]"; then
    error "Dump file was not created in container"
    return 1
  fi
  
  # Check dump size
  local dump_size
  dump_size=$(docker exec "$container_id" sh -c "stat -c%s '$EXPORT_IN_CONTAINER' 2>/dev/null || stat -f%z '$EXPORT_IN_CONTAINER' 2>/dev/null" || echo "0")
  
  if [ "$dump_size" -lt 8192 ]; then
    error "Dump file too small (${dump_size} bytes), export likely failed"
    return 1
  fi
  
  log "Database dump size: $((dump_size / 1024))KB"
  
  # Copy to host
  log "Copying database to host..."
  if ! docker cp "${container_id}:${EXPORT_IN_CONTAINER}" "$TEMP_DB"; then
    error "Failed to copy database from container"
    return 1
  fi
  
  # Validate
  validate_sqlite_file "$TEMP_DB" || return 1
  
  push_rollback "rm -f '$TEMP_DB'"
  success "Database exported successfully"
  return 0
}

create_backup() {
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="$BACKUP_ROOT/pre_migration_$timestamp"
  
  log "Creating backup at: $backup_dir"
  mkdir -p "$backup_dir"
  
  # Backup Pasarguard
  if [ -d "$PASARGUARD_DIR" ]; then
    cp -r "$PASARGUARD_DIR" "$backup_dir/pasarguard_dir"
  fi
  
  if [ -d "/var/lib/pasarguard" ]; then
    cp -r "/var/lib/pasarguard" "$backup_dir/pasarguard_data"
  fi
  
  # Backup exported database
  if [ -f "$TEMP_DB" ]; then
    cp "$TEMP_DB" "$backup_dir/exported_database.sqlite3"
  fi
  
  success "Backup created: $backup_dir"
  echo "$backup_dir"
}

# -----------------------
# Rebecca Installation
# -----------------------
download_rebecca_installer() {
  log "═══ Step 2/6: Downloading Rebecca Installer ═══"
  
  log "Downloading from: $REBECCA_INSTALL_URL"
  
  if ! wget -O "$TEMP_INSTALLER" "$REBECCA_INSTALL_URL" 2>&1 | tee -a "$LOG_FILE"; then
    error "Failed to download Rebecca installer"
    return 1
  fi
  
  if [ ! -f "$TEMP_INSTALLER" ] || [ ! -s "$TEMP_INSTALLER" ]; then
    error "Installer file is empty or missing"
    return 1
  fi
  
  # Basic validation
  if ! head -1 "$TEMP_INSTALLER" | grep -q '^#!/'; then
    error "Installer file doesn't look like a valid script"
    return 1
  fi
  
  chmod +x "$TEMP_INSTALLER"
  push_rollback "rm -f '$TEMP_INSTALLER'"
  
  success "Installer downloaded successfully"
  return 0
}

install_rebecca_official() {
  log "═══ Step 3/6: Installing Rebecca (Official Method) ═══"
  
  echo ""
  echo -e "${YELLOW}╔═══════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  IMPORTANT: Rebecca Installer Instructions   ║${NC}"
  echo -e "${YELLOW}╠═══════════════════════════════════════════════╣${NC}"
  echo -e "${YELLOW}║  1. Follow the installer prompts             ║${NC}"
  echo -e "${YELLOW}║  2. Choose your preferred installation       ║${NC}"
  echo -e "${YELLOW}║  3. When asked about admin user:             ║${NC}"
  echo -e "${YELLOW}║     → Skip it or create temporary one        ║${NC}"
  echo -e "${YELLOW}║     → Your old admin will be restored        ║${NC}"
  echo -e "${YELLOW}║  4. Wait for installation to complete        ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════╝${NC}"
  echo ""
  
  pause
  
  log "Running Rebecca installer..."
  
  # Run installer
  if ! bash "$TEMP_INSTALLER" install; then
    error "Rebecca installation failed"
    return 1
  fi
  
  # Verify installation
  if [ ! -d "$REBECCA_DIR" ]; then
    error "Rebecca directory not found after installation: $REBECCA_DIR"
    return 1
  fi
  
  if [ ! -f "$REBECCA_DIR/docker-compose.yml" ]; then
    error "Rebecca docker-compose.yml not found"
    return 1
  fi
  
  push_rollback "cd '$REBECCA_DIR' && docker compose down -v && rm -rf '$REBECCA_DIR'"
  success "Rebecca installed successfully"
  return 0
}

# -----------------------
# Data Migration
# -----------------------
stop_pasarguard() {
  log "═══ Step 4/6: Stopping Pasarguard ═══"
  
  cd "$PASARGUARD_DIR" || return 1
  
  log "Stopping Pasarguard services..."
  push_rollback "cd '$PASARGUARD_DIR' && docker compose up -d"
  
  docker compose down
  
  success "Pasarguard stopped"
  return 0
}

inject_database_to_rebecca() {
  log "═══ Step 5/6: Injecting Database into Rebecca ═══"
  
  cd "$REBECCA_DIR" || return 1
  
  # Stop Rebecca to prepare for injection
  log "Stopping Rebecca temporarily..."
  docker compose down
  
  # Create containers without starting
  log "Preparing Rebecca containers..."
  if ! docker compose up --no-start; then
    error "Failed to create Rebecca containers"
    return 1
  fi
  
  # Find Rebecca container
  local rebecca_container
  rebecca_container=$(docker compose ps -aq | head -1)
  
  if [ -z "$rebecca_container" ]; then
    error "Rebecca container not found"
    return 1
  fi
  
  success "Found Rebecca container: $rebecca_container"
  
  # Ensure data directory exists in container
  log "Preparing database location..."
  docker exec -u 0 "$rebecca_container" sh -c "mkdir -p /var/lib/marzban" 2>/dev/null || true
  
  # Inject database
  log "Injecting database..."
  if ! docker cp "$TEMP_DB" "${rebecca_container}:/var/lib/marzban/db.sqlite3"; then
    error "Failed to inject database"
    return 1
  fi
  
  # Fix permissions (marzban user is typically 1000:1000)
  log "Setting database permissions..."
  docker exec -u 0 "$rebecca_container" chown -R 1000:1000 /var/lib/marzban 2>/dev/null || {
    warn "Could not set permissions (might be OK)"
  }
  
  success "Database injected successfully"
  return 0
}

configure_rebecca_env() {
  log "Configuring Rebecca environment..."
  
  cd "$REBECCA_DIR" || return 1
  
  # Backup original .env
  if [ -f .env ]; then
    cp .env .env.backup
  fi
  
  # Force SQLite configuration (3 slashes for absolute path)
  log "Setting database to SQLite mode..."
  
  # Remove all database configs
  sed -i '/^SQLALCHEMY_DATABASE_URL=/d' .env 2>/dev/null || true
  sed -i '/^POSTGRES_/d' .env 2>/dev/null || true
  sed -i '/^MYSQL_/d' .env 2>/dev/null || true
  
  # Add SQLite config
  cat >> .env << 'EOF'

# Migrated from Pasarguard
SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/marzban/db.sqlite3
EOF
  
  # Migrate critical settings from Pasarguard
  if [ -f "$PASARGUARD_DIR/.env" ]; then
    log "Migrating environment variables..."
    
    # Extract and append critical vars
    grep -E '^(JWT_SECRET_KEY|UVICORN_PORT|UVICORN_HOST|XRAY_JSON|XRAY_SUBSCRIPTION_URL_PREFIX)=' \
      "$PASARGUARD_DIR/.env" 2>/dev/null >> .env || true
  fi
  
  # Migrate SSL certificates
  if [ -d "/var/lib/pasarguard/certs" ]; then
    log "Migrating SSL certificates..."
    mkdir -p "$REBECCA_DATA_DIR/certs"
    cp -r /var/lib/pasarguard/certs/. "$REBECCA_DATA_DIR/certs/" || warn "Certificate copy failed"
  fi
  
  # Migrate Xray configs
  if [ -d "/var/lib/pasarguard/xray" ]; then
    log "Migrating Xray configurations..."
    mkdir -p "$REBECCA_DATA_DIR/xray"
    cp -r /var/lib/pasarguard/xray/. "$REBECCA_DATA_DIR/xray/" || warn "Xray config copy failed"
  fi
  
  success "Rebecca configuration updated"
  return 0
}

start_rebecca() {
  log "Starting Rebecca services..."
  
  cd "$REBECCA_DIR" || return 1
  
  if ! docker compose start; then
    error "Failed to start Rebecca"
    return 1
  fi
  
  success "Rebecca services started"
  return 0
}

# -----------------------
# Verification
# -----------------------
verify_rebecca_running() {
  log "═══ Step 6/6: Verifying Installation ═══"
  
  cd "$REBECCA_DIR" || return 1
  
  local counter=0
  while [ $counter -lt "$VERIFY_TIMEOUT" ]; do
    local running_count
    running_count=$(docker compose ps --status running -q 2>/dev/null | wc -l)
    
    if [ "$running_count" -gt 0 ]; then
      if docker compose ps | grep -qi "up"; then
        success "Rebecca is running!"
        
        # Get panel URL
        local panel_port
        panel_port=$(grep '^UVICORN_PORT=' .env 2>/dev/null | cut -d= -f2 || echo "8000")
        
        local server_ip
        server_ip=$(hostname -I | awk '{print $1}' || echo "YOUR_SERVER_IP")
        
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                                ║${NC}"
        echo -e "${GREEN}║  ✓ MIGRATION COMPLETED SUCCESSFULLY            ║${NC}"
        echo -e "${GREEN}║                                                ║${NC}"
        echo -e "${GREEN}║  Panel URL: http://${server_ip}:${panel_port}${NC}"
        echo -e "${GREEN}║                                                ║${NC}"
        echo -e "${GREEN}║  Login with your OLD Pasarguard credentials    ║${NC}"
        echo -e "${GREEN}║                                                ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
        
        return 0
      fi
    fi
    
    sleep 2
    counter=$((counter + 2))
    
    if [ $((counter % 10)) -eq 0 ]; then
      log "Waiting for Rebecca... (${counter}s)"
    fi
  done
  
  error "Rebecca did not start properly within ${VERIFY_TIMEOUT}s"
  
  echo ""
  warn "Checking container status..."
  docker compose ps
  
  echo ""
  warn "Recent logs:"
  docker compose logs --tail=30
  
  return 1
}

# -----------------------
# Main Migration Flow
# -----------------------
migrate() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  
  clear
  echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  PASARGUARD → REBECCA MIGRATION (Official v2.0) ${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
  echo ""
  
  # Pre-checks
  log "Running pre-flight checks..."
  check_root
  check_dependencies
  check_disk_space || exit 1
  check_port_availability
  
  # Warning
  echo ""
  warn "This migration will:"
  echo "  1. Export your Pasarguard database"
  echo "  2. Download and run Rebecca's official installer"
  echo "  3. Stop Pasarguard services"
  echo "  4. Inject your data into Rebecca"
  echo "  5. Start Rebecca with your existing data"
  echo ""
  echo "A backup will be created before any destructive changes."
  echo ""
  
  read -rp "Type 'migrate' to confirm: " confirm
  if [ "$confirm" != "migrate" ]; then
    log "Migration cancelled by user"
    exit 0
  fi
  
  echo ""
  log "Starting migration process..."
  log "Log file: $LOG_FILE"
  echo ""
  
  # Enable rollback
  enable_rollback
  
  # Step 1: Export Pasarguard data
  export_pasarguard_data || exit 1
  
  # Create backup AFTER successful export
  local backup_dir
  backup_dir=$(create_backup)
  echo ""
  success "Backup location: $backup_dir"
  echo ""
  
  # Step 2: Download installer
  download_rebecca_installer || exit 1
  
  # Step 3: Install Rebecca
  install_rebecca_official || exit 1
  
  # Step 4: Stop Pasarguard
  stop_pasarguard || exit 1
  
  # Step 5: Inject database
  inject_database_to_rebecca || exit 1
  configure_rebecca_env || exit 1
  start_rebecca || exit 1
  
  # Step 6: Verify
  verify_rebecca_running || exit 1
  
  # Success - disable rollback
  disable_rollback
  
  # Cleanup
  log "Cleaning up temporary files..."
  rm -f "$TEMP_DB"
  rm -f "$TEMP_INSTALLER"
  
  # Cleanup container dump
  cd "$PASARGUARD_DIR" 2>/dev/null || true
  local old_container
  old_container=$(find_pasarguard_container 2>/dev/null || true)
  if [ -n "$old_container" ]; then
    docker exec "$old_container" rm -f "$EXPORT_IN_CONTAINER" 2>/dev/null || true
  fi
  
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  All done! Check the panel and verify:        ${NC}"
  echo -e "${GREEN}  • All users are present                       ${NC}"
  echo -e "${GREEN}  • Traffic data is correct                     ${NC}"
  echo -e "${GREEN}  • Inbounds are working                        ${NC}"
  echo -e "${GREEN}                                                ${NC}"
  echo -e "${GREEN}  Backup: $backup_dir${NC}"
  echo -e "${GREEN}  Logs: $LOG_FILE${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════${NC}"
  echo ""
  
  pause
}

# -----------------------
# Entry Point
# -----------------------
main() {
  migrate
}

main "$@"