# Changelog

## 0.1.5 - unreleased

Health-check fallback hardening for issue #3.

- Replaced the single external health-check dependency with three ordered HTTPS targets: Google gstatic, Cloudflare and Apple.
- Added short-circuit probing: later targets are contacted only when all earlier targets fail.
- Kept Google and Cloudflare checks on HTTP 204; Apple requires HTTP 200 plus a response body containing `Success`.
- A composite health-check fails only when all three targets fail; the existing 3-failure debounce threshold remains unchanged.
- Applied the same composite check to the active VPN, reserve confirmation, post-switch verification and recovery checks.
- Added the successful target name to `status`, `test` and `check` output, with compact per-target failure details when all targets fail.
- Kept interface binding, IPv4-only probing, TLS verification, redirect behavior and existing timeout values unchanged.

## 0.1.4 - 2026-10-14

OpenWrt 25.12 installer compatibility update. Failover runtime behavior is unchanged.

- Added automatic package-manager detection: `apk` when available, otherwise `opkg`.
- Added package-manager wrappers for installed-package checks, package index updates and package installation.
- Added OpenWrt 25.12/`apk` support for the installer while preserving the existing OpenWrt 24.10/`opkg` path.
- Kept first-install safety behavior unchanged: service stopped and autostart disabled until manually verified.
- Kept update behavior unchanged: existing running/stopped and autostart state is preserved.
- Regression-tested the `0.1.3 -> 0.1.4` update path on Xiaomi Redmi AX6000 / OpenWrt 24.10.5: `opkg` detection, service/autostart preservation, restart and AWG HTTPS health checks remained normal.
- OpenWrt 25.12 / `apk` support is implemented against the current package-manager CLI, but has not yet been personally verified on a real 25.12 router.

## 0.1.3 - 2026-08-08

Correct runtime readiness detection for Podkop.

- Replaced `/etc/init.d/podkop running` as a readiness check because Podkop uses a one-shot init action and may report `stopped` after a successful start.
- Podkop runtime is now considered ready when the sing-box init service is running and `/etc/sing-box/config.json` exists.
- Updated status output from `Podkop service: running/stopped` to `Podkop runtime: ready/not ready`.
- Preserved the v0.1.2 startup grace and no-reserve retry behavior unchanged.

## 0.1.2 - 2026-08-08

Final boot and full-outage hardening for the current OpenWrt/Podkop implementation.

- Added a 120-second startup grace period before automatic failover is allowed.
- Added an explicit Podkop readiness guard so failover stays idle while the Podkop runtime is unavailable.
- Added a 300-second interval between full VPN-pool scans after no healthy reserve is found.
- During the no-reserve interval, the currently selected VPN is still probed at the normal 30-second cadence so a quick self-recovery is detected without waiting five minutes.
- Added status output for Podkop readiness and an active no-reserve retry countdown.
- Added the new startup/recovery timings to the built-in configuration display.

## 0.1.1 - 2026-08-08

Hardening release after live failover testing on the target router.

- Verified automatic failover in both directions (`awg0 -> awg0_2` and `awg0_2 -> awg0`) while the failed interface remained administratively up.
- Added a LuCI-safe service control wrapper for compound start/stop actions and explicit post-start running-state verification.
- Fixed duplicate procd log capture and false `daemon.err` entries.
- Added a procd termination timeout so restart can shut the sleeping worker down cleanly.
- Added stale daemon-lock recovery after abnormal termination.
- Reset the failure counter when Podkop's active VPN is changed externally.
- Abort an in-progress automatic switch if Podkop's interface is changed externally.
- Treat a deleted or no-longer-AmneziaWG active `awg*` interface as a failover condition instead of remaining idle forever.
- Keep failover idle when Podkop is not in `vpn` connection mode.
- Clear quarantine when the currently active interface proves healthy again.
- Improved status output with Podkop connection mode and empty-pool reporting.
- Hardened the installer with shell syntax validation, an explicit `cut` dependency check, and best-effort handling of partial `opkg update` feed failures.
- Preserve running/stopped and autostart state when updating an existing installation; first installation remains stopped and disabled by default.
- Fixed package-state detection for both `install ok installed` and `install user installed` opkg states.
- Updated uninstall handling for the control wrapper.
- Expanded README with tested behavior, update semantics, runtime-state details and current limitations.
- Added GitHub Actions shell syntax validation.

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
