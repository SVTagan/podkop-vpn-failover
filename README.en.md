# podkop-vpn-failover

[Русский](README.md)

A small OpenWrt shell script I made for my own setup with [Podkop](https://github.com/itdoginfo/podkop).

The idea is simple: Podkop can use `urltest` for multiple proxies, but there is no equivalent failover for several VPN interfaces. This script checks whether the active AmneziaWG tunnel can actually pass HTTPS traffic and, after repeated failures, switches Podkop to a healthy reserve `awg*` interface.

This is an independent project. It is not part of Podkop and is not affiliated with its developers. For Podkop itself, use the [Podkop repository](https://github.com/itdoginfo/podkop) and [podkop.net](https://podkop.net/).

## What it does

- automatically discovers `awg*` interfaces using the `amneziawg` protocol;
- checks real HTTPS traffic instead of relying on an AWG handshake;
- requires 3 consecutive failures before failover;
- confirms a reserve with 2 successful checks;
- changes `podkop.main.interface` and reloads Podkop normally;
- verifies the new `main-out.bind_interface` and tunnel after switching;
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

The check uses a real HTTP request bound to one interface:

```sh
curl --interface awg0 -4 https://www.gstatic.com/generate_204
```

A tunnel is healthy when the request succeeds and returns HTTP `204`.

## Requirements

Tested on:

- Cudy TR3000 v1;
- OpenWrt 24.10.5;
- Podkop 0.7.21;
- sing-box 1.12.22;
- AmneziaWG.

The current installer is intended for OpenWrt systems using `opkg`. Podkop must use VPN mode and the AmneziaWG interfaces must be named `awg*`.

## Installation

If `uclient-fetch` is available on the router:

```sh
uclient-fetch -q -O /tmp/pvf-install.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh && \
sh /tmp/pvf-install.sh
```

Or, if `curl` is already installed:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh \
  -o /tmp/pvf-install.sh && sh /tmp/pvf-install.sh
```

The installer can install `curl` when needed, installs/configures `luci-app-commands` by default, and adds the procd service.

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

- active VPN check: every 30 seconds;
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

```sh
uclient-fetch -q -O /tmp/pvf-uninstall.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/uninstall.sh && \
sh /tmp/pvf-uninstall.sh
```

`luci-app-commands` is intentionally left installed because other scripts may use it.

## Current limitations

This project currently targets the original use case:

- Podkop VPN mode via `podkop.main.interface`;
- `awg*` AmneziaWG interfaces;
- IPv4 health checks;
- one external health-check URL: `www.gstatic.com/generate_204`;
- settings are built into the shell script;
- installer targets `opkg`.

Support for multiple independent health-check endpoints is tracked as a [possible future improvement](https://github.com/SVTagan/podkop-vpn-failover/issues/3).

## Tested behavior

The main failover path was tested on a Cudy TR3000 v1 by blocking the UDP transport of the active tunnel while leaving the AWG interface itself up. Failover was verified in both directions (`awg0 → awg0_2` and back), together with debounce, reserve confirmation, quarantine, no automatic switch-back, procd/autostart, LuCI controls and reboot startup.

See [CHANGELOG.md](CHANGELOG.md) for version history.

## License

MIT — see [LICENSE](LICENSE).
