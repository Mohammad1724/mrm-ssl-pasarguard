#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then source /opt/mrm-manager/ui.sh; fi

OFFLINE_BACKUP_ROOT="/opt/mrm-manager/offline-backups"
OFFLINE_UBUNTU_MIRRORS=(
    "http://mirror.arvancloud.ir/ubuntu"
    "http://ir.archive.ubuntu.com/ubuntu"
    "https://repo.iut.ac.ir/repo/ubuntu/ubuntu"
)
OFFLINE_DOCKER_MIRRORS=(
    "https://docker.arvancloud.ir"
    "https://hub.hamdocker.ir"
    "https://docker.iranserver.com"
)
OFFLINE_RECOMMENDED_APT_MIRROR="http://mirror.arvancloud.ir/ubuntu"
OFFLINE_RECOMMENDED_DOCKER_MIRROR="https://docker.arvancloud.ir"

offline_invalid_option() {
    if declare -f invalid_menu_option >/dev/null 2>&1; then
        invalid_menu_option
    else
        ui_error "Invalid option"
        sleep 1
    fi
}

offline_require_ubuntu() {
    local OS_ID=""

    if [ -f /etc/os-release ]; then
        OS_ID=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    fi

    [ "$OS_ID" = "ubuntu" ]
}

offline_get_codename() {
    awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null
}

offline_get_current_apt_mirror() {
    local SOURCE_FILE
    local MIRROR=""

    for SOURCE_FILE in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list /etc/apt/sources.list; do
        [ -f "$SOURCE_FILE" ] || continue

        case "$SOURCE_FILE" in
            *.sources)
                MIRROR=$(awk '/^URIs:/{print $2; exit}' "$SOURCE_FILE" 2>/dev/null)
                ;;
            *)
                MIRROR=$(awk '$1=="deb" && $2 !~ /^\[/ {print $2; exit} $1=="deb" && $2 ~ /^\[/ {print $3; exit}' "$SOURCE_FILE" 2>/dev/null)
                ;;
        esac

        if [ -n "$MIRROR" ]; then
            printf '%s\n' "$MIRROR"
            return 0
        fi
    done

    return 1
}

offline_get_current_docker_mirror() {
    local DAEMON_FILE="/etc/docker/daemon.json"

    [ -f "$DAEMON_FILE" ] || return 1

    python3 - <<'PYEOF' 2>/dev/null
import json
path = "/etc/docker/daemon.json"
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    mirrors = data.get("registry-mirrors") or []
    if mirrors:
        print(mirrors[0])
except Exception:
    pass
PYEOF
}

offline_is_known_apt_mirror() {
    local CURRENT="$1"
    local M
    for M in "${OFFLINE_UBUNTU_MIRRORS[@]}"; do
        [ "$CURRENT" = "$M" ] && return 0
    done
    return 1
}

offline_is_known_docker_mirror() {
    local CURRENT="$1"
    local M
    for M in "${OFFLINE_DOCKER_MIRRORS[@]}"; do
        [ "$CURRENT" = "$M" ] && return 0
    done
    return 1
}

offline_test_apt_mirror() {
    local MIRROR="$1"
    local CODENAME="$2"
    local HTTP_CODE

    HTTP_CODE=$(curl -L -o /dev/null -s --connect-timeout 5 --max-time 10 -w '%{http_code}' "${MIRROR}/dists/${CODENAME}/Release" 2>/dev/null || echo 000)
    [ "$HTTP_CODE" = "200" ]
}

offline_test_docker_mirror() {
    local MIRROR="$1"
    local HTTP_CODE

    HTTP_CODE=$(curl -L -o /dev/null -s --connect-timeout 5 --max-time 10 -w '%{http_code}' "${MIRROR}/v2/" 2>/dev/null || echo 000)
    [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]
}

offline_create_backup() {
    local BACKUP_DIR

    mkdir -p "$OFFLINE_BACKUP_ROOT" || return 1
    BACKUP_DIR="$OFFLINE_BACKUP_ROOT/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR/apt/sources.list.d" "$BACKUP_DIR/docker" || return 1

    [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$BACKUP_DIR/apt/sources.list" 2>/dev/null || true
    [ -d /etc/apt/sources.list.d ] && cp -a /etc/apt/sources.list.d/. "$BACKUP_DIR/apt/sources.list.d/" 2>/dev/null || true

    if [ -f /etc/docker/daemon.json ]; then
        cp -a /etc/docker/daemon.json "$BACKUP_DIR/docker/daemon.json" 2>/dev/null || true
    else
        touch "$BACKUP_DIR/docker/daemon.json.absent"
    fi

    printf '%s\n' "$BACKUP_DIR"
}

offline_restore_backup_dir() {
    local BACKUP_DIR="$1"

    [ -d "$BACKUP_DIR" ] || return 1

    mkdir -p /etc/apt/sources.list.d /etc/docker

    if [ -f "$BACKUP_DIR/apt/sources.list" ]; then
        cp "$BACKUP_DIR/apt/sources.list" /etc/apt/sources.list || return 1
    fi

    rm -rf /etc/apt/sources.list.d/* 2>/dev/null || true
    if [ -d "$BACKUP_DIR/apt/sources.list.d" ]; then
        cp -a "$BACKUP_DIR/apt/sources.list.d/." /etc/apt/sources.list.d/ 2>/dev/null || true
    fi

    if [ -f "$BACKUP_DIR/docker/daemon.json" ]; then
        cp "$BACKUP_DIR/docker/daemon.json" /etc/docker/daemon.json || return 1
    elif [ -f "$BACKUP_DIR/docker/daemon.json.absent" ]; then
        rm -f /etc/docker/daemon.json 2>/dev/null || true
    fi

    apt-get update >/dev/null 2>&1 || true
    if command -v docker >/dev/null 2>&1; then
        systemctl restart docker >/dev/null 2>&1 || true
    fi

    return 0
}

offline_latest_backup_dir() {
    ls -1dt "$OFFLINE_BACKUP_ROOT"/* 2>/dev/null | head -1
}

offline_apply_apt_mirror() {
    local MIRROR="$1"
    local BACKUP_DIR="$2"
    local CODENAME
    local UPDATE_OK=false

    CODENAME="$(offline_get_codename)"
    [ -n "$CODENAME" ] || return 1

    mkdir -p /etc/apt/sources.list.d
    rm -rf /etc/apt/sources.list.d/* 2>/dev/null || true

    cat > /etc/apt/sources.list <<EOF
# Managed by MRM Iran/Offline Mode
deb ${MIRROR} ${CODENAME} main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-backports main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-security main restricted universe multiverse
EOF

    if apt-get update >/dev/null 2>&1; then
        UPDATE_OK=true
    fi

    if [ "$UPDATE_OK" != true ]; then
        offline_restore_backup_dir "$BACKUP_DIR" >/dev/null 2>&1 || true
        return 1
    fi

    return 0
}

offline_apply_docker_mirror() {
    local MIRROR="$1"
    local BACKUP_DIR="$2"

    mkdir -p /etc/docker

    if ! python3 - <<PYEOF
import json
path = "/etc/docker/daemon.json"
mirror = ${MIRROR@Q}
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except Exception:
    raise SystemExit(1)
mirrors = data.get("registry-mirrors") or []
if mirror not in mirrors:
    mirrors.append(mirror)
data["registry-mirrors"] = mirrors
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    then
        offline_restore_backup_dir "$BACKUP_DIR" >/dev/null 2>&1 || true
        return 1
    fi

    if command -v docker >/dev/null 2>&1; then
        if ! systemctl restart docker >/dev/null 2>&1; then
            offline_restore_backup_dir "$BACKUP_DIR" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    return 0
}

offline_show_status() {
    local CODENAME
    local CURRENT_APT
    local CURRENT_DOCKER

    clear
    ui_header "IRAN / OFFLINE MODE"

    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        echo ""
        ui_info "Use Ubuntu servers for safe mirror automation in Phase 2."
        echo ""
        pause
        return
    fi

    CODENAME="$(offline_get_codename)"
    CURRENT_APT="$(offline_get_current_apt_mirror 2>/dev/null || echo Not")"
    CURRENT_DOCKER="$(offline_get_current_docker_mirror 2>/dev/null || echo Not)"

    ui_section "Environment"
    ui_kv "Ubuntu Codename" "${CODENAME:-Unknown}"
    ui_kv "Current APT Mirror" "$CURRENT_APT"
    ui_kv "Current Docker Mirror" "$CURRENT_DOCKER"
    echo ""

    ui_section "Current State"
    if offline_is_known_apt_mirror "$CURRENT_APT"; then
        ui_success "APT is using a known Iran/internal mirror"
    else
        ui_warning "APT is not using a known Iran/internal mirror"
    fi

    if [ "$CURRENT_DOCKER" != "Not" ] && offline_is_known_docker_mirror "$CURRENT_DOCKER"; then
        ui_success "Docker is using a known Iran/internal mirror"
    else
        ui_warning "Docker mirror is not configured to a known Iran/internal mirror"
    fi
    echo ""

    pause
}

offline_test_mirrors() {
    local CODENAME
    local MIRROR

    clear
    ui_header "TEST IRAN MIRRORS"

    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        pause
        return
    fi

    CODENAME="$(offline_get_codename)"
    [ -n "$CODENAME" ] || {
        ui_error "Could not detect Ubuntu codename"
        pause
        return
    }

    ui_section "APT Mirrors"
    for MIRROR in "${OFFLINE_UBUNTU_MIRRORS[@]}"; do
        if offline_test_apt_mirror "$MIRROR" "$CODENAME"; then
            ui_success "$MIRROR"
        else
            ui_warning "$MIRROR"
        fi
    done
    echo ""

    ui_section "Docker Mirrors"
    for MIRROR in "${OFFLINE_DOCKER_MIRRORS[@]}"; do
        if offline_test_docker_mirror "$MIRROR"; then
            ui_success "$MIRROR"
        else
            ui_warning "$MIRROR"
        fi
    done
    echo ""

    pause
}

offline_apply_recommended_apt() {
    local BACKUP_DIR

    clear
    ui_header "APPLY IRAN APT MIRROR"

    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        pause
        return
    fi

    echo -e "${YELLOW}Recommended Ubuntu mirror:${NC} $OFFLINE_RECOMMENDED_APT_MIRROR"
    echo -e "${CYAN}A full backup of APT and Docker configuration will be created first.${NC}"
    echo ""
    read -r -p "Apply this Ubuntu mirror now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi

    BACKUP_DIR="$(offline_create_backup)"
    if [ -z "$BACKUP_DIR" ]; then
        ui_error "Failed to create offline backup"
        pause
        return
    fi

    if offline_apply_apt_mirror "$OFFLINE_RECOMMENDED_APT_MIRROR" "$BACKUP_DIR"; then
        ui_success "Ubuntu APT mirror updated successfully"
        ui_info "Backup saved in: $BACKUP_DIR"
    else
        ui_error "Failed to apply Ubuntu APT mirror. Previous config restored."
    fi
    pause
}

offline_apply_recommended_docker() {
    local BACKUP_DIR

    clear
    ui_header "APPLY IRAN DOCKER MIRROR"

    echo -e "${YELLOW}Recommended Docker mirror:${NC} $OFFLINE_RECOMMENDED_DOCKER_MIRROR"
    echo -e "${CYAN}A full backup of APT and Docker configuration will be created first.${NC}"
    echo ""
    read -r -p "Apply this Docker mirror now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi

    BACKUP_DIR="$(offline_create_backup)"
    if [ -z "$BACKUP_DIR" ]; then
        ui_error "Failed to create offline backup"
        pause
        return
    fi

    if offline_apply_docker_mirror "$OFFLINE_RECOMMENDED_DOCKER_MIRROR" "$BACKUP_DIR"; then
        ui_success "Docker mirror updated successfully"
        ui_info "Backup saved in: $BACKUP_DIR"
    else
        ui_error "Failed to apply Docker mirror. Previous config restored."
    fi
    pause
}

offline_apply_both_recommended() {
    local BACKUP_DIR

    clear
    ui_header "APPLY IRAN MIRRORS"

    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        pause
        return
    fi

    echo -e "${YELLOW}APT Mirror:${NC} $OFFLINE_RECOMMENDED_APT_MIRROR"
    echo -e "${YELLOW}Docker Mirror:${NC} $OFFLINE_RECOMMENDED_DOCKER_MIRROR"
    echo -e "${CYAN}A full backup of current APT and Docker config will be created.${NC}"
    echo ""
    read -r -p "Apply both recommended mirrors now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi

    BACKUP_DIR="$(offline_create_backup)"
    if [ -z "$BACKUP_DIR" ]; then
        ui_error "Failed to create offline backup"
        pause
        return
    fi

    if ! offline_apply_apt_mirror "$OFFLINE_RECOMMENDED_APT_MIRROR" "$BACKUP_DIR"; then
        ui_error "Failed to apply Ubuntu APT mirror. Previous config restored."
        pause
        return
    fi

    if ! offline_apply_docker_mirror "$OFFLINE_RECOMMENDED_DOCKER_MIRROR" "$BACKUP_DIR"; then
        ui_error "Failed to apply Docker mirror. Previous config restored."
        pause
        return
    fi

    ui_success "APT and Docker mirrors updated successfully"
    ui_info "Backup saved in: $BACKUP_DIR"
    pause
}

offline_check_readiness() {
    local CMD
    local BUNDLE
    local FOUND_ANY=false
    local REQUIRED_COMMANDS=(curl tar unzip python3 jq docker nginx certbot)
    local BUNDLE_PATTERNS=(
        "/root/pasarguard-standalone*.tar.gz"
        "/root/pg-node-standalone*.tar.gz"
        "/root/mrm-ssl-pasarguard*.tar.gz"
    )

    clear
    ui_header "OFFLINE READINESS CHECK"

    if ! offline_require_ubuntu; then
        ui_warning "Ubuntu-only automation is available in this module"
    else
        ui_success "Ubuntu detected: $(offline_get_codename)"
    fi

    echo ""
    ui_section "Mirror Status"
    if offline_is_known_apt_mirror "$(offline_get_current_apt_mirror 2>/dev/null || true)"; then
        ui_success "APT uses an internal/Iran mirror"
    else
        ui_warning "APT is not configured with a known internal/Iran mirror"
    fi

    if offline_is_known_docker_mirror "$(offline_get_current_docker_mirror 2>/dev/null || true)"; then
        ui_success "Docker uses an internal/Iran mirror"
    else
        ui_warning "Docker mirror is not configured with a known internal/Iran mirror"
    fi

    echo ""
    ui_section "Required Commands"
    for CMD in "${REQUIRED_COMMANDS[@]}"; do
        if command -v "$CMD" >/dev/null 2>&1; then
            ui_success "$CMD"
        else
            ui_warning "$CMD"
        fi
    done

    echo ""
    ui_section "Local Bundles"
    for BUNDLE in "${BUNDLE_PATTERNS[@]}"; do
        set -- $BUNDLE
        if [ -e "$1" ]; then
            ui_success "$1"
            FOUND_ANY=true
        fi
    done

    if [ "$FOUND_ANY" != true ]; then
        ui_warning "No local tar.gz bundles found in /root"
    fi

    echo ""
    pause
}

offline_restore_latest_backup() {
    local BACKUP_DIR

    clear
    ui_header "RESTORE MIRROR BACKUP"

    BACKUP_DIR="$(offline_latest_backup_dir)"
    if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
        ui_warning "No offline backup found"
        pause
        return
    fi

    echo -e "${YELLOW}Latest backup:${NC} $BACKUP_DIR"
    echo ""
    read -r -p "Restore this backup now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi

    if offline_restore_backup_dir "$BACKUP_DIR"; then
        ui_success "Backup restored successfully"
    else
        ui_error "Failed to restore backup"
    fi
    pause
}

offline_menu() {
    while true; do
        clear
        ui_header "IRAN / OFFLINE MODE"
        echo "1) 🇮🇷 Show Current Mirror Status"
        echo "2) 🧪 Test Iran Mirrors"
        echo "3) 📦 Apply Recommended Ubuntu APT Mirror"
        echo "4) 🐳 Apply Recommended Docker Mirror"
        echo "5) 🚀 Apply Both Recommended Mirrors"
        echo "6) 🧰 Offline Readiness Check"
        echo "7) ♻️  Restore Last Mirror Backup"
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case "$OPT" in
            1) offline_show_status ;;
            2) offline_test_mirrors ;;
            3) offline_apply_recommended_apt ;;
            4) offline_apply_recommended_docker ;;
            5) offline_apply_both_recommended ;;
            6) offline_check_readiness ;;
            7) offline_restore_latest_backup ;;
            0) return ;;
            *) offline_invalid_option ;;
        esac
    done
}
