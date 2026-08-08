# podkop-vpn-failover

Lightweight health-check and failover service for **Podkop VPN mode** on OpenWrt.

The service watches the AmneziaWG interface currently selected in Podkop. If real HTTPS traffic through that tunnel fails repeatedly, it automatically tests reserve `awg*` interfaces and switches Podkop to the first healthy reserve.

> Experimental software. The first release is being developed and tested on a Cudy TR3000 v1 running OpenWrt 24.10.5 with Podkop 0.7.21, sing-box 1.12.22 and AmneziaWG.

## Design

The project intentionally stays outside Podkop and uses its normal UCI configuration:

```text
podkop.main.interface
        ↓
Podkop reload
        ↓
sing-box main-out
bind_interface = awgX
```

VPN health is checked with a real HTTPS request bound to a specific interface:

```sh
curl --interface awg0 -4 https://www.gstatic.com/generate_204
```

A tunnel is healthy only when curl succeeds and the test endpoint returns HTTP `204`. A WireGuard/AmneziaWG handshake alone is not considered sufficient.

## Interface discovery and reserve order

There is no manual VPN list.

The service automatically discovers UCI network interfaces that:

- have a name beginning with `awg`;
- use the `amneziawg` protocol.

Adding or deleting an `awg*` interface in LuCI therefore automatically changes the failover pool.

The interface currently selected in Podkop is always treated as the active VPN. All other discovered `awg*` interfaces are reserves.

When failover is required, reserves are tested in natural name order, for example:

```text
awg0
awg0_2
awg1
awg2
awg2_2
awg9
awg10
```

The service does **not** automatically switch back to a lower-numbered interface while the current VPN remains healthy.

## Anti-flapping protection

Default behavior:

- health-check every 30 seconds;
- 3 consecutive failures before declaring the current VPN failed;
- 2 successful checks before a reserve is accepted;
- recently failed interfaces are quarantined for 180 seconds;
- quarantined interfaces may still be tested as a last resort when no other reserve is healthy;
- no switching based on latency;
- Podkop binding and VPN health are verified after a switch.

Current built-in settings can be displayed with:

```sh
podkop-vpn-failover config
```

## Installation

OpenWrt 24.10 and older use `opkg`. The installer checks dependencies, installs the worker and procd service, and optionally installs/configures `luci-app-commands`.

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh)"
```

### Safety behavior

The installer deliberately leaves automatic failover **stopped and disabled**.

After installation, first run:

```sh
podkop-vpn-failover test
podkop-vpn-failover status
```

Only after confirming that the expected interfaces are discovered and healthy, enable the service:

```sh
/etc/init.d/podkop-vpn-failover enable
/etc/init.d/podkop-vpn-failover start
```

## LuCI

When `luci-app-commands` is installed by the installer, the following actions are added under **System → Custom Commands**:

- VPN Failover: Status
- VPN Failover: Test all VPNs
- VPN Failover: Logs
- VPN Failover: Show settings
- VPN Failover: Enable + Start
- VPN Failover: Restart
- VPN Failover: Stop + Disable

This means routine operation does not require SSH.

Adding and removing reserve VPNs is done normally through **Network → Interfaces** in LuCI.

## CLI

```text
podkop-vpn-failover daemon
podkop-vpn-failover status
podkop-vpn-failover test
podkop-vpn-failover check awg0
podkop-vpn-failover logs
podkop-vpn-failover config
podkop-vpn-failover version
```

## Logs

Events are written to the OpenWrt system log using the tag `podkop-vpn-failover`.

```sh
podkop-vpn-failover logs
```

or:

```sh
logread | grep podkop-vpn-failover
```

No persistent log file is written to flash.

## Uninstall

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/uninstall.sh)"
```

The uninstall script removes the worker, service and its LuCI Custom Commands entries. It does not remove `luci-app-commands`, because that package may be used by other tools.

## Current scope

The initial version targets:

- OpenWrt 24.10.x / `opkg`;
- Podkop VPN mode using `podkop.main.interface`;
- AmneziaWG interfaces named `awg*`;
- IPv4 application-level health checks.

Support for newer OpenWrt releases, other tunnel types, configurable settings through a dedicated LuCI page, packaging as an `.ipk`, and notifications may be considered later.
