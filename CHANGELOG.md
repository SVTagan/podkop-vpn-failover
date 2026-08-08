# Changelog

## 0.1.0 - 2026-08-08

Initial development release.

- Automatic discovery of `awg*` AmneziaWG interfaces from OpenWrt UCI.
- Natural reserve ordering without a manually maintained interface list.
- HTTPS health-check bound to each VPN interface.
- Consecutive-failure threshold before failover.
- Candidate confirmation checks and temporary quarantine for failed interfaces.
- Podkop switching through `podkop.main.interface` and normal Podkop reload.
- Post-switch binding and health verification.
- procd service integration.
- Status, test, log and configuration CLI commands.
- Installer with optional `luci-app-commands` integration.
- Safe installation state: service stopped and autostart disabled until manually verified.
