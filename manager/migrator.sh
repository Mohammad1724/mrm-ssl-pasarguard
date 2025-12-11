#!/usr/bin/env bash
# Pasarguard -> Rebecca Enterprise Migrator (MySQL Edition)
# Features: Dry-Run, Rollback, MySQL Injection, Safe Backup

set -euo pipefail -o errtrace

### -------------------------
### Configuration
### -------------------------
PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA_DIR="${REBECCA_DATA_DIR:-/var/lib/rebecca}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/migration}"
TEMP_DB="${TEMP_DB:-/tmp/pasarguard_export_$$.sqlite3}"
TEMP_INSTALLER="${TEMP_INSTALLER:-/tmp/rebecca_installer_$$.sh}"
LOG_FILE="${LOG_FILE:-/var/log/mrm_migration.log}"
EXPORT_IN_CONTAINER="/tmp/dump_migration"

# Official Rebecca Installer
INSTALL_SCRIPT_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"

DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-90}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-60}"
READ_TIMEOUT="${READ_TIMEOUT:-300}"

# Colors
CYAN="$(tput setaf 6 2>/dev/null || echo '')"
YELLOW="$(tput setaf 3 2>/dev/null || echo '')"
GREEN="$(tput setaf 2 2>/dev/null || echo '')"
RED="$(tput setaf 1 2>/dev/null || echo '')"
BLUE="$(tput setaf 4 2>/dev/null || echo '')"
NC="$(tput sgr0 2>/dev/null || echo '')"

### -------------------------
### CLI args
### -------------------------
DRY_RUN="${DRY_RUN:-false}"
CONFIRM=false
VERBOSE=false

usage(){
  cat <<EOF
Usage: $0 [options]
Options:
  --pasarguard-dir PATH   (default: $PASARGUARD_DIR)
  --rebecca-dir PATH      (default: $REBECCA_DIR)
  --dry-run               simulate execution
  --confirm               execute real migration
  --verbose               verbose logging
  -h|--help               show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pasarguard-dir) PASARGUARD_DIR="$2"; shift 2;;
    --rebecca-dir) REBECCA_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --confirm) CONFIRM=true; shift;;
    --verbose) VERBOSE=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [ "$CONFIRM" = true ]; then DRY_RUN=false; elif [ "$DRY_RUN" = false ]; then
  echo "Error: Use --confirm for real execution or --dry-run for preview."; exit 2;
fi

### -------------------------
### Logging helpers
### -------------------------
ensure_logfile(){
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || { LOG_FILE="/tmp/mrm_migration.log"; touch "$LOG_FILE"; }
}
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"; }
info(){ echo -e "${BLUE}→${NC} $*"; log "$*"; }
ok(){ echo -e "${GREEN}✓${NC} $*"; log "$*"; }
warn(){ echo -e "${YELLOW}⚠${NC} $*"; log "$*"; }
err(){ echo -e "${RED}✗${NC} $*" >&2; log "[ERROR] $*"; }

_run(){
  local desc="$1"; shift
  local cmd="$*"
  log "[RUN] $desc -> $cmd"
  if [ "$DRY_RUN" = true ]; then
    [ "$VERBOSE" = true ] && echo "[DRY-RUN] $cmd"
    return 0
  fi
  bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

pause(){ read -t "$READ_TIMEOUT" -rp "Press Enter to continue..." || true; }

### -------------------------
### Rollback stack
### -------------------------
declare -a ROLLBACK_CMDS=()
push_rollback(){ ROLLBACK_CMDS+=("$*"); }
run_rollback(){
  err "Migration failed — running rollback"
  for ((i=${#ROLLBACK_CMDS[@]}-1;i>=0;i--)); do
    cmd="${ROLLBACK_CMDS[i]}"
    log "ROLLBACK: $cmd"
    if [ "$DRY_RUN" = false ]; then
      bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE" || log "Rollback step failed (ignored)"
    fi
  done
  ok "Rollback finished"
  pause
}
trap 'rc=$?; if [ $rc -ne 0 ]; then run_rollback; fi; exit $rc' ERR

enable_rollback(){
  push_rollback "cd '$PASARGUARD_DIR' && docker compose up -d || true"
  info "Rollback enabled (Safety Net)"
}

### -------------------------
### Utilities
### -------------------------
check_command_exists(){ command -v "$1" >/dev/null 2>&1; }
check_dependencies(){
  local missing=()
  for c in docker wget tar sqlite3 awk sed grep head curl; do
    check_command_exists "$c" || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then err "Missing: ${missing[*]}"; return 1; fi
  ok "Dependencies OK"
}

get_file_size_bytes(){
  local f="$1"; [ -f "$f" ] || { echo 0; return; }
  stat -c%s "$f" 2>/dev/null || wc -c < "$f" | tr -d ' '
}

safe_cd(){ cd "$1" 2>/dev/null || return 1; }

### -------------------------
### Container detection
### -------------------------
find_container_by_image_or_name(){
  local dir="$1" keyword="$2"
  safe_cd "$dir" || return 1
  local ids=$(docker compose ps -q 2>/dev/null || true)
  for cid in $ids; do
    local img=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null)
    local name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null)
    if echo "$img $name" | grep -qiE "$keyword"; then echo "$cid"; return 0; fi
  done
  echo "$ids" | head -1
}

find_pasarguard_container(){ find_container_by_image_or_name "$PASARGUARD_DIR" "marzban|pasarguard|panel|backend|node"; }
find_rebecca_container(){ find_container_by_image_or_name "$REBECCA_DIR" "marzban|rebecka|rebecca|rebeka|backend|panel"; }

detect_marzban_cli(){
  local cid="$1"
  if docker exec "$cid" sh -c 'command -v marzban-cli >/dev/null 2>&1'; then echo "marzban-cli"; return 0; fi
  echo "python3 -m marzban.cli"; return 0
}

wait_for_cli_ready(){
  local cid="$1" timeout="${2:-$DB_WAIT_TIMEOUT}" elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if docker exec "$cid" sh -c 'command -v marzban-cli >/dev/null 2>&1 || python3 -c "import marzban" >/dev/null 2>&1' >/dev/null 2>&1; then
      ok "CLI ready in $cid"
      return 0
    fi
    sleep 2; elapsed=$((elapsed+2))
  done
  warn "CLI not available after ${timeout}s"
  return 1
}

### -------------------------
### Safe .env updater
### -------------------------
update_env_key(){
  local key="$1"; local val="$2"; local file="$3"
  [ -z "$key" ] && return 0
  [ ! -f "$file" ] && { echo "${key}=${val}" > "$file"; return 0; }
  if grep -q "^${key}=" "$file"; then
    tmp=$(mktemp)
    awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k{$2=v; print; next} {print}' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

### -------------------------
### Step 1: Export DB
### -------------------------
export_pasarguard_db(){
  info "STEP 1: Exporting Pasarguard Data"
  safe_cd "$PASARGUARD_DIR" || { err "Dir missing"; return 1; }

  cid=$(find_pasarguard_container) || true
  if [ -z "${cid:-}" ]; then
    info "Starting Pasarguard..."
    _run "start" "docker compose up -d"
    push_rollback "cd '$PASARGUARD_DIR' && docker compose down || true"
    sleep 10
    cid=$(find_pasarguard_container) || true
  fi
  [ -z "${cid:-}" ] && { err "Container not found"; return 1; }
  ok "Container: $cid"

  wait_for_cli_ready "$cid" || warn "CLI check timeout"
  inv=$(detect_marzban_cli "$cid")

  _run "sync" "docker exec '$cid' sh -c '$inv sync || true'"
  _run "dump" "docker exec '$cid' sh -c '$inv database dump --target \"$EXPORT_IN_CONTAINER\"'"

  if [ "$DRY_RUN" = false ]; then
    docker exec "$cid" sh -c "[ -f '$EXPORT_IN_CONTAINER' ]" || { err "Dump failed"; return 1; }
  fi

  _run "copy" "docker cp '$cid:$EXPORT_IN_CONTAINER' '$TEMP_DB'"
  
  if [ "$DRY_RUN" = false ]; then
    size=$(get_file_size_bytes "$TEMP_DB")
    [ "$size" -ge 8192 ] || { err "Export too small"; return 1; }
  fi

  push_rollback "rm -f '$TEMP_DB' || true"
  return 0
}

### -------------------------
### Step 2: Backup
### -------------------------
create_backup(){
  info "Creating Backup"
  mkdir -p "$BACKUP_ROOT"
  ts=$(date +%Y%m%d_%H%M%S)
  bdir="$BACKUP_ROOT/pre_migration_$ts"
  mkdir -p "$bdir"
  [ -d "$PASARGUARD_DIR" ] && _run "tar configs" "tar --exclude='*/node_modules' -C '$(dirname "$PASARGUARD_DIR")' -czf '$bdir/pasarguard_dir.tar.gz' '$(basename "$PASARGUARD_DIR")'"
  [ -f "$TEMP_DB" ] && _run "copy db" "cp -f '$TEMP_DB' '$bdir/exported_db.sqlite3'"
  ok "Backup: $bdir"
  push_rollback "rm -rf '$bdir' || true"
  echo "$bdir"
}

### -------------------------
### Step 3: Install Rebecca (MySQL)
### -------------------------
install_rebecca(){
  info "Downloading Rebecca Installer"
  _run "wget" "wget -q -O '$TEMP_INSTALLER' '$INSTALL_SCRIPT_URL'"
  [ "$DRY_RUN" = false ] && chmod +x "$TEMP_INSTALLER" && push_rollback "rm -f '$TEMP_INSTALLER' || true"

  info "Installing Rebecca (MySQL Mode)"
  if [ "$DRY_RUN" = false ]; then
    # --database mysql ensures docker-compose.yml is generated for MySQL
    bash "$TEMP_INSTALLER" install --database mysql 2>&1 | tee -a "$LOG_FILE" || { err "Install failed"; return 1; }
    [ -d "$REBECCA_DIR" ] || { err "Install dir missing"; return 1; }
    push_rollback "cd '$REBECCA_DIR' && docker compose down -v; rm -rf '$REBECCA_DIR'"
  fi
  ok "Rebecca Installed"
}

### -------------------------
### Step 4: Stop Old
### -------------------------
stop_pasarguard(){
  info "Stopping Pasarguard"
  safe_cd "$PASARGUARD_DIR"
  push_rollback "cd '$PASARGUARD_DIR' && docker compose up -d"
  _run "stop" "docker compose down"
  ok "Pasarguard Stopped"
}

### -------------------------
### Step 5: Migrate Configs
### -------------------------
migrate_configs(){
  info "Migrating Configs"
  [ -f "$PASARGUARD_DIR/.env" ] || return 0
  
  # Merge keys (Do NOT overwrite DB URL)
  while IFS= read -r line; do
    [[ "$line" =~ ^(JWT_|UVICORN_|XRAY_|SUDO_) ]] || continue
    key=$(echo "$line" | cut -d= -f1)
    val=$(echo "$line" | cut -d= -f2-)
    update_env_key "$key" "$val" "$REBECCA_DIR/.env"
  done < "$PASARGUARD_DIR/.env"

  # Certs
  if [ -d "/var/lib/pasarguard/certs" ]; then
    target="$REBECCA_DATA_DIR/certs"
    mkdir -p "$target"
    _run "copy certs" "cp -a /var/lib/pasarguard/certs/. '$target/'"
  fi
  ok "Configs Migrated"
}

### -------------------------
### Step 6: Inject Data (MySQL Restore)
### -------------------------
inject_into_rebecca(){
  info "Injecting Data into Rebecca (MySQL)"
  safe_cd "$REBECCA_DIR"
  
  _run "start" "docker compose up -d"
  
  if [ "$DRY_RUN" = false ]; then
    info "Waiting for MySQL init (20s)..."
    sleep 20
    
    rcid=$(find_rebecca_container)
    [ -n "$rcid" ] || { err "Rebecca container missing"; return 1; }
    
    # 1. Copy dump file into container
    _run "copy dump" "docker cp '$TEMP_DB' '$rcid:/tmp/restore_source'"
    
    # 2. Run Restore Command (imports SQLite dump into MySQL)
    inv=$(detect_marzban_cli "$rcid")
    info "Restoring data..."
    if docker exec "$rcid" sh -c "$inv database restore --source /tmp/restore_source"; then
      ok "Database Restored Successfully"
    else
      err "Restore failed. Check logs."
      return 1
    fi
    
    _run "restart" "docker compose restart"
  fi
  
  push_rollback "cd '$REBECCA_DIR' && docker compose down -v"
}

### -------------------------
### Step 7: Verify
### -------------------------
verify_rebecca(){
  info "Verifying..."
  safe_cd "$REBECCA_DIR"
  local elapsed=0
  while [ $elapsed -lt "$VERIFY_TIMEOUT" ]; do
    if docker compose ps | grep -qi "Up"; then
      ok "Rebecca Running"
      return 0
    fi
    sleep 2; elapsed=$((elapsed+2))
  done
  err "Verification failed"
  return 1
}

### -------------------------
### Main
### -------------------------
main(){
  ensure_logfile
  info "MIGRATION STARTED (Target: Rebecca MySQL)"
  check_dependencies || exit 1
  [ -d "$PASARGUARD_DIR" ] || { err "Pasarguard not found"; exit 1; }

  echo ""
  warn "This will stop Pasarguard, install Rebecca (MySQL), and migrate data."
  read -t "$READ_TIMEOUT" -rp "Type 'migrate' to confirm: " c || c=""
  [ "$c" != "migrate" ] && exit 0
  
  enable_rollback
  
  export_pasarguard_db || exit 1
  create_backup || exit 1
  download_rebeka_installer || exit 1
  install_rebecca_official || exit 1 # Installs with MySQL
  stop_pasarguard || exit 1
  migrate_configs || exit 1
  inject_into_rebecca || exit 1      # Imports data into MySQL
  verify_rebecca || exit 1
  
  trap - ERR
  _run "cleanup" "rm -f '$TEMP_DB' '$TEMP_INSTALLER'"
  
  echo ""
  ok "MIGRATION COMPLETE"
  echo "Rebecca is running on MySQL."
  echo "Login with your OLD credentials."
  pause
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi