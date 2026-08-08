#!/bin/sh

set -u

TAG="podkop-vpn-failover"
BASE_URL="${PVF_BASE_URL:-https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main}"
WORKER_DST="/usr/bin/podkop-vpn-failover"
CONTROL_DST="/usr/bin/podkop-vpn-failover-control"
INIT_DST="/etc/init.d/podkop-vpn-failover"
INSTALL_LUCI_COMMANDS="${INSTALL_LUCI_COMMANDS:-1}"

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
command -v opkg >/dev/null 2>&1 || fail "This installer currently targets OpenWrt 24.10 and older systems using opkg."

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
    # OpenWrt/opkg may report either "install ok installed" or
    # "install user installed" depending on how a package was installed.
    opkg status "$1" 2>/dev/null | grep -q '^Status: install .* installed$'
}

need_opkg_update=0
pkg_installed curl || need_opkg_update=1
if [ "$INSTALL_LUCI_COMMANDS" = "1" ] && ! pkg_installed luci-app-commands; then
    need_opkg_update=1
fi

if [ "$need_opkg_update" -eq 1 ]; then
    info "Updating opkg package lists..."
    if ! opkg update; then
        warn "opkg update reported errors; continuing with any package lists that are available."
    fi
fi

if ! pkg_installed curl; then
    info "Installing curl..."
    opkg install curl || fail "curl installation failed."
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

TMP_WORKER="/tmp/${TAG}.worker.$$"
TMP_CONTROL="/tmp/${TAG}.control.$$"
TMP_INIT="/tmp/${TAG}.init.$$"
trap 'rm -f "$TMP_WORKER" "$TMP_CONTROL" "$TMP_INIT"' EXIT INT TERM

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

existing_install=0
was_running=0
was_enabled=0

if [ -x "$INIT_DST" ]; then
    existing_install=1
    "$INIT_DST" running >/dev/null 2>&1 && was_running=1
    "$INIT_DST" enabled >/dev/null 2>&1 && was_enabled=1
    info "Stopping existing failover service before update..."
    "$INIT_DST" stop >/dev/null 2>&1 || true
fi

cp "$TMP_WORKER" "$WORKER_DST" || fail "Failed to copy ${WORKER_DST}."
chmod 0755 "$WORKER_DST" || fail "Failed to set permissions on ${WORKER_DST}."
cp "$TMP_CONTROL" "$CONTROL_DST" || fail "Failed to copy ${CONTROL_DST}."
chmod 0755 "$CONTROL_DST" || fail "Failed to set permissions on ${CONTROL_DST}."
cp "$TMP_INIT" "$INIT_DST" || fail "Failed to copy ${INIT_DST}."
chmod 0755 "$INIT_DST" || fail "Failed to set permissions on ${INIT_DST}."

if [ "$INSTALL_LUCI_COMMANDS" = "1" ]; then
    if ! pkg_installed luci-app-commands; then
        info "Installing luci-app-commands..."
        if ! opkg install luci-app-commands; then
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
    configure_luci_command pvf_status  'VPN Failover: Status'          '/usr/bin/podkop-vpn-failover status'
    configure_luci_command pvf_test    'VPN Failover: Test all VPNs'   '/usr/bin/podkop-vpn-failover test'
    configure_luci_command pvf_logs    'VPN Failover: Logs'            '/usr/bin/podkop-vpn-failover logs'
    configure_luci_command pvf_config  'VPN Failover: Show settings'   '/usr/bin/podkop-vpn-failover config'
    configure_luci_command pvf_start   'VPN Failover: Enable + Start'  '/usr/bin/podkop-vpn-failover-control start'
    configure_luci_command pvf_restart 'VPN Failover: Restart'         '/usr/bin/podkop-vpn-failover-control restart'
    configure_luci_command pvf_stop    'VPN Failover: Stop + Disable'  '/usr/bin/podkop-vpn-failover-control stop'
    uci commit luci
fi

if [ "$existing_install" -eq 1 ]; then
    if [ "$was_enabled" -eq 1 ]; then
        "$INIT_DST" enable >/dev/null 2>&1 || fail "Failed to restore failover autostart state."
    else
        "$INIT_DST" disable >/dev/null 2>&1 || true
    fi

    if [ "$was_running" -eq 1 ]; then
        info "Restoring running failover service..."
        "$CONTROL_DST" restart >/dev/null 2>&1 || fail "Updated files were installed, but the failover service could not be restarted."
    else
        "$INIT_DST" stop >/dev/null 2>&1 || true
    fi
else
    # First installation is deliberately safe: no automatic switching until
    # interface discovery and health checks have been verified by the user.
    "$INIT_DST" disable >/dev/null 2>&1 || true
    "$INIT_DST" stop >/dev/null 2>&1 || true
fi

rm -f "$TMP_WORKER" "$TMP_CONTROL" "$TMP_INIT"
trap - EXIT INT TERM

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
