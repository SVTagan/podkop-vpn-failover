#!/bin/sh

set -u

TAG="podkop-vpn-failover"
INSTALLER_VERSION="0.1.6-stage2"
DEFAULT_REF="v${INSTALLER_VERSION}"

# Normal installs are pinned to the matching release tag. PVF_BASE_URL is kept
# as an explicit override for development/testing from a branch or commit.
BASE_URL="${PVF_BASE_URL:-https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/${DEFAULT_REF}}"
WORKER_DST="/usr/bin/podkop-vpn-failover"
CONTROL_DST="/usr/bin/podkop-vpn-failover-control"
INIT_DST="/etc/init.d/podkop-vpn-failover"
INSTALL_LUCI_COMMANDS="${INSTALL_LUCI_COMMANDS:-1}"
PKG_MANAGER=""

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || fail "Run this installer as root."
[ -r /etc/openwrt_release ] || fail "This installer is intended for OpenWrt."
command -v uci >/dev/null 2>&1 || fail "uci is required."

# OpenWrt 25.12+ uses apk, while OpenWrt 24.10 and older use opkg.
# Detect the package manager by capability instead of parsing the release number,
# so custom builds and future releases follow the package manager they provide.
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
else
    fail "Neither apk nor opkg was found; unsupported OpenWrt package manager."
fi
info "Detected package manager: ${PKG_MANAGER}"

fetch() {
    local url="$1" dst="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dst"
        return $?
    fi

    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$dst" "$url"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$dst" "$url"
        return $?
    fi

    return 127
}

pkg_installed() {
    local package="$1"

    if [ "$PKG_MANAGER" = "apk" ]; then
        # OpenWrt 25.12 uses apk v3. "apk info -e" is the direct installed
        # package check (-e is the short form of --exists) and returns success
        # only when the named package is installed.
        apk info -e "$package" >/dev/null 2>&1
    else
        # OpenWrt/opkg may report either "install ok installed" or
        # "install user installed" depending on how a package was installed.
        opkg status "$package" 2>/dev/null | grep -q '^Status: install .* installed$'
    fi
}

pkg_update() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk update
    else
        opkg update
    fi
}

pkg_install() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add "$1"
    else
        opkg install "$1"
    fi
}

need_pkg_update=0
pkg_installed curl || need_pkg_update=1
if [ "$INSTALL_LUCI_COMMANDS" = "1" ] && ! pkg_installed luci-app-commands; then
    need_pkg_update=1
fi

if [ "$need_pkg_update" -eq 1 ]; then
    info "Updating ${PKG_MANAGER} package lists..."
    if ! pkg_update; then
        warn "${PKG_MANAGER} package list update reported errors; continuing with any package lists that are available."
    fi
fi

if ! pkg_installed curl; then
    info "Installing curl..."
    pkg_install curl || fail "curl installation failed."
fi

command -v logger >/dev/null 2>&1 || fail "logger is required."
command -v awk >/dev/null 2>&1 || fail "awk is required."
command -v sort >/dev/null 2>&1 || fail "sort is required."
command -v cut >/dev/null 2>&1 || fail "cut is required."
command -v sed >/dev/null 2>&1 || fail "sed is required."
command -v grep >/dev/null 2>&1 || fail "grep is required."

if ! command -v podkop >/dev/null 2>&1 && [ ! -x /usr/bin/podkop ]; then
    fail "Podkop is not installed."
fi

[ -x /etc/init.d/podkop ] || fail "Podkop init service was not found at /etc/init.d/podkop."

connection_type="$(uci -q get podkop.main.connection_type 2>/dev/null)"
if [ "$connection_type" != "vpn" ]; then
    warn "podkop.main.connection_type is '${connection_type:-unset}', not 'vpn'. The failover daemon will stay idle until Podkop main uses VPN mode."
fi

STATE_DIR="/tmp/${TAG}"
PID_FILE="${STATE_DIR}/pid"

WORK_DIR=""
TMP_WORKER=""
TMP_CONTROL=""
TMP_INIT=""
STAGE_WORKER=""
STAGE_CONTROL=""
STAGE_INIT=""
BACKUP_WORKER=""
BACKUP_CONTROL=""
BACKUP_INIT=""
HAD_WORKER=0
HAD_CONTROL=0
HAD_INIT=0
KEEP_RECOVERY_FILES=0
TRANSACTION_ACTIVE=0
TRANSACTION_COMMITTED=0
ROLLBACK_IN_PROGRESS=0

read_pid() {
    [ -r "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null
}

pid_is_failover() {
    local pid="$1" cmdline=""

    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac

    [ -d "/proc/${pid}" ] || return 1
    [ -r "/proc/${pid}/cmdline" ] || return 1

    cmdline="$(tr '\000' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
    case "$cmdline" in
        *"${WORKER_DST}"*"daemon"*) return 0 ;;
    esac

    return 1
}

wait_stopped() {
    local old_pid="$1" attempt=0

    while [ "$attempt" -lt 50 ]; do
        if { [ ! -x "$INIT_DST" ] || ! "$INIT_DST" running >/dev/null 2>&1; } \
            && ! pid_is_failover "$old_pid"; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    return 1
}

wait_running_stable() {
    local attempt=0

    while [ "$attempt" -lt 5 ]; do
        if "$INIT_DST" running >/dev/null 2>&1; then
            sleep 2
            "$INIT_DST" running >/dev/null 2>&1 && return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    return 1
}

service_enabled_now() {
    [ -x "$INIT_DST" ] && "$INIT_DST" enabled >/dev/null 2>&1
}

service_running_now() {
    [ -x "$INIT_DST" ] && "$INIT_DST" running >/dev/null 2>&1
}

stop_installed_service() {
    local old_pid=""

    old_pid="$(read_pid)"

    if [ -x "$INIT_DST" ]; then
        "$INIT_DST" stop >/dev/null 2>&1 || return 1
    elif pid_is_failover "$old_pid"; then
        return 1
    fi

    wait_stopped "$old_pid"
}

apply_service_state() {
    local want_running="$1" want_enabled="$2" old_pid=""

    if [ ! -x "$INIT_DST" ]; then
        [ "$want_running" -eq 0 ] && [ "$want_enabled" -eq 0 ]
        return $?
    fi

    if [ "$want_enabled" -eq 1 ]; then
        "$INIT_DST" enable >/dev/null 2>&1 || return 1
    else
        "$INIT_DST" disable >/dev/null 2>&1 || return 1
    fi

    if [ "$want_running" -eq 1 ]; then
        "$INIT_DST" start >/dev/null 2>&1 || return 1
        wait_running_stable || return 1
    else
        old_pid="$(read_pid)"
        "$INIT_DST" stop >/dev/null 2>&1 || return 1
        wait_stopped "$old_pid" || return 1
    fi

    if [ "$want_enabled" -eq 1 ]; then
        service_enabled_now || return 1
    else
        service_enabled_now && return 1
    fi

    if [ "$want_running" -eq 1 ]; then
        service_running_now || return 1
    else
        service_running_now && return 1
    fi

    return 0
}

restore_file() {
    local dst="$1" backup="$2" had_file="$3"

    if [ "$had_file" -eq 1 ]; then
        [ -n "$backup" ] && [ -f "$backup" ] || return 1
        mv -f "$backup" "$dst" || return 1
        chmod 0755 "$dst" || return 1
    else
        rm -f "$dst" || return 1
    fi

    return 0
}

rollback_update() {
    local rollback_ok=1 partial_pid=""

    [ "$ROLLBACK_IN_PROGRESS" -eq 0 ] || return 1
    ROLLBACK_IN_PROGRESS=1

    warn "Update failed; attempting to restore the previous installation."

    partial_pid="$(read_pid)"
    if [ -x "$INIT_DST" ]; then
        "$INIT_DST" stop >/dev/null 2>&1 || rollback_ok=0
        wait_stopped "$partial_pid" >/dev/null 2>&1 || rollback_ok=0
    elif pid_is_failover "$partial_pid"; then
        rollback_ok=0
    fi

    restore_file "$WORKER_DST" "$BACKUP_WORKER" "$HAD_WORKER" || rollback_ok=0
    restore_file "$CONTROL_DST" "$BACKUP_CONTROL" "$HAD_CONTROL" || rollback_ok=0
    restore_file "$INIT_DST" "$BACKUP_INIT" "$HAD_INIT" || rollback_ok=0

    if ! apply_service_state "$was_running" "$was_enabled"; then
        rollback_ok=0
    fi

    ROLLBACK_IN_PROGRESS=0

    if [ "$rollback_ok" -eq 1 ]; then
        TRANSACTION_ACTIVE=0
        warn "Previous installation and service state were restored."
        return 0
    fi

    KEEP_RECOVERY_FILES=1
    warn "Automatic rollback could not be completed. Recovery files were kept for manual inspection."
    warn "Work directory: ${WORK_DIR}"
    [ -n "$BACKUP_WORKER" ] && [ -e "$BACKUP_WORKER" ] && warn "Worker backup: ${BACKUP_WORKER}"
    [ -n "$BACKUP_CONTROL" ] && [ -e "$BACKUP_CONTROL" ] && warn "Control backup: ${BACKUP_CONTROL}"
    [ -n "$BACKUP_INIT" ] && [ -e "$BACKUP_INIT" ] && warn "Init backup: ${BACKUP_INIT}"
    return 1
}

cleanup_artifacts() {
    if [ "$KEEP_RECOVERY_FILES" -eq 0 ]; then
        [ -n "$STAGE_WORKER" ] && rm -f "$STAGE_WORKER"
        [ -n "$STAGE_CONTROL" ] && rm -f "$STAGE_CONTROL"
        [ -n "$STAGE_INIT" ] && rm -f "$STAGE_INIT"
        [ -n "$BACKUP_WORKER" ] && rm -f "$BACKUP_WORKER"
        [ -n "$BACKUP_CONTROL" ] && rm -f "$BACKUP_CONTROL"
        [ -n "$BACKUP_INIT" ] && rm -f "$BACKUP_INIT"
        [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    fi
}

on_exit() {
    local rc="$?"

    trap - EXIT INT TERM HUP

    if [ "$TRANSACTION_ACTIVE" -eq 1 ] \
        && [ "$TRANSACTION_COMMITTED" -eq 0 ] \
        && [ "$ROLLBACK_IN_PROGRESS" -eq 0 ]; then
        rollback_update || true
    fi

    cleanup_artifacts
    exit "$rc"
}

command -v mktemp >/dev/null 2>&1 || fail "mktemp is required."
command -v mv >/dev/null 2>&1 || fail "mv is required."
command -v tr >/dev/null 2>&1 || fail "tr is required."

WORK_DIR="$(mktemp -d "/tmp/${TAG}.install.XXXXXX")" || fail "Failed to create private installer work directory."
chmod 0700 "$WORK_DIR" || fail "Failed to secure installer work directory."

TMP_WORKER="${WORK_DIR}/worker"
TMP_CONTROL="${WORK_DIR}/control"
TMP_INIT="${WORK_DIR}/init"

trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'on_exit' EXIT

info "Downloading worker..."
fetch "${BASE_URL}/podkop-vpn-failover" "$TMP_WORKER" || fail "Failed to download worker from ${BASE_URL}."

info "Downloading service control wrapper..."
fetch "${BASE_URL}/podkop-vpn-failover-control" "$TMP_CONTROL" || fail "Failed to download control wrapper from ${BASE_URL}."

info "Downloading procd init script..."
fetch "${BASE_URL}/podkop-vpn-failover.init" "$TMP_INIT" || fail "Failed to download init script from ${BASE_URL}."

[ -s "$TMP_WORKER" ] || fail "Downloaded worker is empty."
[ -s "$TMP_CONTROL" ] || fail "Downloaded control wrapper is empty."
[ -s "$TMP_INIT" ] || fail "Downloaded init script is empty."

# Refuse to replace working files with syntactically invalid shell scripts.
/bin/sh -n "$TMP_WORKER" || fail "Downloaded worker failed shell syntax validation."
/bin/sh -n "$TMP_CONTROL" || fail "Downloaded control wrapper failed shell syntax validation."
/bin/sh -n "$TMP_INIT" || fail "Downloaded init script failed shell syntax validation."

grep -q '^# podkop-vpn-failover$' "$TMP_WORKER" || fail "Downloaded worker does not look like podkop-vpn-failover."

downloaded_version="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$TMP_WORKER" | head -n 1)"
[ -n "$downloaded_version" ] || fail "Could not determine downloaded worker version."
[ "$downloaded_version" = "$INSTALLER_VERSION" ] \
    || fail "Downloaded worker version ${downloaded_version} does not match installer version ${INSTALLER_VERSION}."

# Prepare complete replacement files in the same directories as their final
# destinations. The final mv(1) therefore stays on one filesystem and replaces
# each individual pathname atomically.
STAGE_WORKER="$(mktemp "${WORKER_DST}.new.XXXXXX")" || fail "Failed to stage ${WORKER_DST}."
cp "$TMP_WORKER" "$STAGE_WORKER" || fail "Failed to prepare ${WORKER_DST}."
chmod 0755 "$STAGE_WORKER" || fail "Failed to set staged worker permissions."

STAGE_CONTROL="$(mktemp "${CONTROL_DST}.new.XXXXXX")" || fail "Failed to stage ${CONTROL_DST}."
cp "$TMP_CONTROL" "$STAGE_CONTROL" || fail "Failed to prepare ${CONTROL_DST}."
chmod 0755 "$STAGE_CONTROL" || fail "Failed to set staged control-wrapper permissions."

STAGE_INIT="$(mktemp "${INIT_DST}.new.XXXXXX")" || fail "Failed to stage ${INIT_DST}."
cp "$TMP_INIT" "$STAGE_INIT" || fail "Failed to prepare ${INIT_DST}."
chmod 0755 "$STAGE_INIT" || fail "Failed to set staged init-script permissions."

existing_install=0
was_running=0
was_enabled=0

[ -e "$WORKER_DST" ] && HAD_WORKER=1
[ -e "$CONTROL_DST" ] && HAD_CONTROL=1
[ -e "$INIT_DST" ] && HAD_INIT=1

if [ "$HAD_WORKER" -eq 1 ] || [ "$HAD_CONTROL" -eq 1 ] || [ "$HAD_INIT" -eq 1 ]; then
    existing_install=1
fi

if [ -x "$INIT_DST" ]; then
    "$INIT_DST" running >/dev/null 2>&1 && was_running=1
    "$INIT_DST" enabled >/dev/null 2>&1 && was_enabled=1
fi

# Backups are also kept on the destination filesystem so rollback can replace
# each file with a same-filesystem rename.
if [ "$HAD_WORKER" -eq 1 ]; then
    BACKUP_WORKER="$(mktemp "${WORKER_DST}.bak.XXXXXX")" || fail "Failed to prepare worker backup."
    cp "$WORKER_DST" "$BACKUP_WORKER" || fail "Failed to back up ${WORKER_DST}."
    chmod 0755 "$BACKUP_WORKER" || fail "Failed to secure worker backup permissions."
fi

if [ "$HAD_CONTROL" -eq 1 ]; then
    BACKUP_CONTROL="$(mktemp "${CONTROL_DST}.bak.XXXXXX")" || fail "Failed to prepare control-wrapper backup."
    cp "$CONTROL_DST" "$BACKUP_CONTROL" || fail "Failed to back up ${CONTROL_DST}."
    chmod 0755 "$BACKUP_CONTROL" || fail "Failed to secure control-wrapper backup permissions."
fi

if [ "$HAD_INIT" -eq 1 ]; then
    BACKUP_INIT="$(mktemp "${INIT_DST}.bak.XXXXXX")" || fail "Failed to prepare init-script backup."
    cp "$INIT_DST" "$BACKUP_INIT" || fail "Failed to back up ${INIT_DST}."
    chmod 0755 "$BACKUP_INIT" || fail "Failed to secure init-script backup permissions."
fi

TRANSACTION_ACTIVE=1

if [ "$existing_install" -eq 1 ]; then
    info "Stopping existing failover service before update..."
else
    info "Ensuring failover service is stopped before first installation..."
fi

stop_installed_service || fail "Existing failover daemon could not be confirmed stopped; no files were committed."

mv -f "$STAGE_WORKER" "$WORKER_DST" || fail "Failed to activate ${WORKER_DST}."
STAGE_WORKER=""
mv -f "$STAGE_CONTROL" "$CONTROL_DST" || fail "Failed to activate ${CONTROL_DST}."
STAGE_CONTROL=""
mv -f "$STAGE_INIT" "$INIT_DST" || fail "Failed to activate ${INIT_DST}."
STAGE_INIT=""

if [ "$existing_install" -eq 1 ]; then
    info "Restoring previous failover service state..."
    apply_service_state "$was_running" "$was_enabled" \
        || fail "Updated files were installed, but the previous service state could not be restored."
else
    # First installation is deliberately safe: no automatic switching until
    # interface discovery and health checks have been verified by the user.
    apply_service_state 0 0 \
        || fail "First installation could not be left safely stopped and disabled."
fi

TRANSACTION_COMMITTED=1
TRANSACTION_ACTIVE=0

# LuCI integration is intentionally outside the core file/service transaction.
# A package/UCI failure here must not roll back an otherwise healthy failover.
if [ "$INSTALL_LUCI_COMMANDS" = "1" ]; then
    if ! pkg_installed luci-app-commands; then
        info "Installing luci-app-commands..."
        if ! pkg_install luci-app-commands; then
            warn "luci-app-commands installation failed. Core failover files are installed; LuCI buttons were skipped."
            INSTALL_LUCI_COMMANDS=0
        fi
    fi
fi

configure_luci_command() {
    local section="$1" name="$2" command="$3"
    uci -q delete "luci.${section}" >/dev/null 2>&1 || true
    uci set "luci.${section}=command"
    uci set "luci.${section}.name=${name}"
    uci set "luci.${section}.command=${command}"
}

if [ "$INSTALL_LUCI_COMMANDS" = "1" ]; then
    info "Adding LuCI Custom Commands entries..."
    if configure_luci_command pvf_status  'VPN Failover: Status'          '/usr/bin/podkop-vpn-failover status' \
        && configure_luci_command pvf_test    'VPN Failover: Test all VPNs'   '/usr/bin/podkop-vpn-failover test' \
        && configure_luci_command pvf_logs    'VPN Failover: Logs'            '/usr/bin/podkop-vpn-failover logs' \
        && configure_luci_command pvf_config  'VPN Failover: Show settings'   '/usr/bin/podkop-vpn-failover config' \
        && configure_luci_command pvf_start   'VPN Failover: Enable + Start'  '/usr/bin/podkop-vpn-failover-control start' \
        && configure_luci_command pvf_restart 'VPN Failover: Restart'         '/usr/bin/podkop-vpn-failover-control restart' \
        && configure_luci_command pvf_stop    'VPN Failover: Stop + Disable'  '/usr/bin/podkop-vpn-failover-control stop' \
        && uci commit luci; then
        :
    else
        warn "Failed to configure one or more LuCI Custom Commands. Core failover installation is unaffected."
    fi
fi

cleanup_artifacts
trap - EXIT INT TERM HUP

info "Installed ${TAG}."
printf '\n'

if [ "$existing_install" -eq 1 ]; then
    printf 'Update state preserved:\n'
    if [ "$was_running" -eq 1 ]; then
        printf '  Service:   RUNNING\n'
    else
        printf '  Service:   STOPPED\n'
    fi
    if [ "$was_enabled" -eq 1 ]; then
        printf '  Autostart: ENABLED\n'
    else
        printf '  Autostart: DISABLED\n'
    fi
else
    printf 'Safety state after first installation:\n'
    printf '  Service:   STOPPED\n'
    printf '  Autostart: DISABLED\n'
    printf '\n'
    printf 'Verify before enabling failover:\n'
    printf '  /usr/bin/podkop-vpn-failover test\n'
    printf '  /usr/bin/podkop-vpn-failover status\n'
    printf '\n'
    printf 'When verification is complete:\n'
    printf '  /usr/bin/podkop-vpn-failover-control start\n'
fi

printf '\n'
if [ "$INSTALL_LUCI_COMMANDS" = "1" ]; then
    printf 'The same actions are available in LuCI -> System -> Custom Commands.\n'
fi
