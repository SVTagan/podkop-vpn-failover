# podkop-vpn-failover

[Русский](README.md)

A small OpenWrt shell script I made for my own setup with [Podkop](https://github.com/itdoginfo/podkop).

The idea is simple: Podkop can use `urltest` for multiple proxies, but there is no equivalent failover for several VPN interfaces. This script checks whether the active AmneziaWG tunnel can actually pass HTTPS traffic and, after repeated failures, switches Podkop to a healthy reserve `awg*` interface.

This is an independent project. It is not part of Podkop and is not affiliated with its developers. For Podkop itself, use the [Podkop repository](https://github.com/itdoginfo/podkop) and [podkop.net](https://podkop.net/).

## Status

Current version: **0.1.6**.

### OpenWrt 25.12 / apk

Starting with 0.1.4, the installer supports both OpenWrt package managers: `opkg` on 24.10 and older compatible releases, and `apk` on 25.12 and newer. The available package manager is detected automatically and used to check/install `curl` and `luci-app-commands`.

The `opkg` path has been tested on real OpenWrt 24.10.x systems. `apk` support follows the current OpenWrt 25.12 CLI model, but has not yet been personally verified on real 25.12 hardware.

### 0.1.6 reliability hardening

Version 0.1.6 strengthens the existing failover path without adding new operating modes: after a switch, the script now separately confirms that the Podkop/sing-box runtime is actually ready and remains ready before recording a successful failover.

The installer is also transactional for the project's three files: the new version is prepared and validated in advance, running/autostart state is preserved, and a partial replacement or failed updated-service start automatically restores the previous files and service state.

## What it does

- automatically discovers `awg*` interfaces using the `amneziawg` protocol;
- checks real HTTPS traffic instead of relying on an AWG handshake;
- tries independent Google → Apple → Mozilla health targets in order and stops after the first successful response;
- requires 3 consecutive failures before failover;
- confirms a reserve with 2 successful checks;
- changes `podkop.main.interface` and reloads Podkop normally;
- after switching, verifies the Podkop/sing-box runtime, new `main-out.bind_interface`, and tunnel;
- temporarily quarantines recently failed VPNs;
- does not automatically switch back while the current VPN remains healthy;
- avoids continuously scanning the whole pool when every VPN is down;
- uses a 120-second startup grace period;
- can be operated from LuCI through `System → Custom Commands`.

## VPN discovery and order

There is no manual reserve list. The script finds UCI interfaces whose names begin with `awg` and whose protocol is `amneziawg`.

The VPN currently selected in:

```text
podkop.main.interface
```

is treated as active. Other matching interfaces are reserves and are tested in natural name order, for example:

```text
awg0
awg0_2
awg1
awg2
awg2_2
awg9
awg10
```

The script does not switch back just because a lower-numbered VPN has recovered. A new switch happens only if the current VPN fails.

## Tunnel health check

The check uses real HTTPS traffic bound to a specific interface through `curl --interface <awg*> -4`.

Starting with 0.1.5, a small ordered set of independent health targets is used:

1. `https://www.gstatic.com/generate_204` — expects HTTP `204`;
2. `https://captive.apple.com/hotspot-detect.html` — expects HTTP `200` and a response body containing `Success`;
3. `https://detectportal.firefox.com/success.txt` — expects HTTP `200` and a response body containing `success`.

Targets are tried sequentially and probing stops at the first success. In the normal case, when `gstatic` works, each cycle still sends only one request. Only failure of all three targets counts as one failed health-check attempt toward the existing `FAIL_THRESHOLD`.

Redirects are intentionally not followed and TLS certificate verification remains enabled. The existing `CONNECT_TIMEOUT=5` and `MAX_TIME=10` apply to every target.

Important: `CHECK_INTERVAL=30` is a pause after a completed check, not a guaranteed start-to-start interval. When a tunnel is completely unreachable, targets are tried sequentially and each may consume its own timeout, so confirmed failure can take noticeably longer. In the real full-outage test, the three targets added about 15 seconds to a cycle and failure warnings appeared roughly every 45 seconds. This is an intentional reliability-over-speed tradeoff to reduce false failovers.

## Requirements

- OpenWrt 24.10.x with `opkg` is the tested baseline; starting with 0.1.4 the installer also supports OpenWrt 25.12+ with `apk`, although real 25.12 hardware has not yet been personally verified;
- Podkop in `vpn` mode;
- AmneziaWG UCI interfaces named `awg*`;
- `curl`, which the installer can install automatically when needed;
- IPv4 for health checks: probes are forced through `-4`.

The working setup has been tested with Podkop 0.7.x, sing-box 1.12.x and AmneziaWG. These are reference versions rather than strict minor-version requirements.

## Installation

Normal installation is pinned to the current stable Release `v0.1.6`. The `main` branch is used for further development and is not the recommended source for normal installation.

Using `uclient-fetch`:

```sh
PVF_RELEASE='v0.1.6'

uclient-fetch -q -O /tmp/pvf-install.sh \
  "https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/${PVF_RELEASE}/install.sh" && \
sh /tmp/pvf-install.sh
```

Using `curl`:

```sh
PVF_RELEASE='v0.1.6'

curl -fsSL \
  "https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/${PVF_RELEASE}/install.sh" \
  -o /tmp/pvf-install.sh && \
sh /tmp/pvf-install.sh
```

Using `wget`:

```sh
PVF_RELEASE='v0.1.6'

wget -q -O /tmp/pvf-install.sh \
  "https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/${PVF_RELEASE}/install.sh" && \
sh /tmp/pvf-install.sh
```

Starting with 0.1.6, the installer is pinned to its own release tag by default and fetches worker/control/init from that same tag. Normal installation therefore does not depend on the current state of `main`.

The installer can install `curl` when needed, installs/configures `luci-app-commands` by default, and adds the procd service. When downloading its own files it can use `curl`, `uclient-fetch`, or `wget`.

`PVF_BASE_URL` remains an explicit override only for development/testing from a specific branch or commit.

### First install

For safety, automatic failover is left stopped and disabled. Check discovery and tunnel health first:

```sh
podkop-vpn-failover test
podkop-vpn-failover status
```

Then enable it:

```sh
podkop-vpn-failover-control start
```

Updates preserve the previous service and autostart state.

## LuCI

With `luci-app-commands`, the following actions are available under `System → Custom Commands`:

- `VPN Failover: Status`
- `VPN Failover: Test all VPNs`
- `VPN Failover: Logs`
- `VPN Failover: Show settings`
- `VPN Failover: Enable + Start`
- `VPN Failover: Restart`
- `VPN Failover: Stop + Disable`

Reserve VPNs can be added or removed normally under `Network → Interfaces`; the pool is discovered automatically.

## Default behavior

- pause after each completed active-VPN check: 30 seconds;
- health targets: `gstatic` → `apple` → `mozilla`, short-circuiting after the first success;
- failure threshold: 3 failed checks;
- reserve confirmation: 2 successful checks;
- quarantine: 180 seconds;
- startup grace: 120 seconds;
- full-pool retry after no healthy reserve: 300 seconds;
- no latency-based selection.

Current values:

```sh
podkop-vpn-failover config
```

## CLI

```text
podkop-vpn-failover status
podkop-vpn-failover test
podkop-vpn-failover check awg0
podkop-vpn-failover logs
podkop-vpn-failover config
podkop-vpn-failover version

podkop-vpn-failover-control start
podkop-vpn-failover-control restart
podkop-vpn-failover-control stop
```

## Logs and runtime state

Events are written to the normal OpenWrt system log with the `podkop-vpn-failover` tag:

```sh
logread | grep podkop-vpn-failover
```

No persistent log file is written to flash. Runtime state is kept under `/tmp` and starts fresh after reboot.

## Uninstall

Use `uninstall.sh` from the same stable Release `v0.1.6`.

Using `uclient-fetch`:

```sh
PVF_RELEASE='v0.1.6'

uclient-fetch -q -O /tmp/pvf-uninstall.sh \
  "https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/${PVF_RELEASE}/uninstall.sh" && \
sh /tmp/pvf-uninstall.sh
```

Using `curl`:

```sh
PVF_RELEASE='v0.1.6'

curl -fsSL \
  "https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/${PVF_RELEASE}/uninstall.sh" \
  -o /tmp/pvf-uninstall.sh && \
sh /tmp/pvf-uninstall.sh
```

Using `wget`:

```sh
PVF_RELEASE='v0.1.6'

wget -q -O /tmp/pvf-uninstall.sh \
  "https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/${PVF_RELEASE}/uninstall.sh" && \
sh /tmp/pvf-uninstall.sh
```

`luci-app-commands` is intentionally left installed because other scripts may use it.

## Current limitations

This project currently targets the original use case:

- Podkop VPN mode via `podkop.main.interface`;
- `awg*` AmneziaWG interfaces;
- IPv4 health checks;
- health-check targets are currently built into the shell script and are not configurable from LuCI;
- failover settings are built into the shell script;
- installer support through `apk` on OpenWrt 25.12 is implemented but has not yet been personally verified on a real router.

## Tested on real routers

The full failover test was performed on a Cudy TR3000 v1 / OpenWrt 24.10.5 by blocking the UDP transport of the active tunnel while leaving the AWG interface itself up. Failover was verified in both directions (`awg0 → awg0_2` and back).

A second Cudy TR3000 running OpenWrt 24.10.4 additionally confirmed clean installation/startup, procd/autostart, startup grace and real HTTPS health checks.

On Xiaomi Redmi AX6000 / OpenWrt 24.10.5, version 0.1.5 was additionally tested with all three health targets, Apple and Mozilla fallback paths, complete failure of all targets, a real `awg0 → awg0_2` failover by blocking the active tunnel's UDP transport, and recovery of `awg0` without an automatic switch-back.

For 0.1.6 on the same router, additional tests covered post-switch runtime validation during a real failover, updates preserving RUNNING+ENABLED and STOPPED+DISABLED states, automatic rollback after partial file replacement and after a failed updated-service start, a real first install, LuCI commands, uninstall/reinstall, and verification that rollback left no mixed or stale temporary project files.

See [CHANGELOG.md](CHANGELOG.md) for version history.

## License

MIT — see [LICENSE](LICENSE).
