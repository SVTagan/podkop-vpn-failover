#!/bin/sh

set -u

TAG="podkop-vpn-failover"
INIT="/etc/init.d/podkop-vpn-failover"
WORKER="/usr/bin/podkop-vpn-failover"
CONTROL="/usr/bin/podkop-vpn-failover-control"
STATE_DIR="/tmp/podkop-vpn-failover"
LOCK_DIR="/tmp/podkop-vpn-failover.lock"

info() {
    printf '[INFO] %s\n' "$*"
}

[ "$(id -u)" = "0" ] || {
    printf '[ERROR] Run this script as root.\n' >&2
    exit 1
}

if [ -x "$INIT" ]; then
    info "Stopping and disabling service..."
    "$INIT" stop >/dev/null 2>&1 || true
    "$INIT" disable >/dev/null 2>&1 || true
fi

rm -f "$WORKER" "$CONTROL" "$INIT"
rm -rf "$STATE_DIR" "$LOCK_DIR"

for section in pvf_status pvf_test pvf_logs pvf_config pvf_start pvf_restart pvf_stop; do
    uci -q delete "luci.${section}" >/dev/null 2>&1 || true
done
uci commit luci >/dev/null 2>&1 || true

info "Removed ${TAG}."
info "luci-app-commands was left installed because it may be used by other tools."
