# podkop-vpn-failover

Lightweight health-check and automatic failover service for **Podkop VPN mode** on OpenWrt.

The service watches the AmneziaWG interface currently selected in Podkop. If real HTTPS traffic through that tunnel fails repeatedly, it tests reserve `awg*` interfaces and switches Podkop to the first healthy reserve.

> Development release. The current implementation has been tested on a Cudy TR3000 v1 running OpenWrt 24.10.5 with Podkop 0.7.21, sing-box 1.12.22 and AmneziaWG. Bidirectional failover (`awg0 -> awg0_2` and `awg0_2 -> awg0`) was verified on the router by blocking the active tunnel transport while leaving the interface itself up.

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

The service does **not** automatically switch back to a lower-numbered interface while the current VPN remains healthy. If the current VPN later fails, all eligible reserves are considered again in natural order.

## Failure handling

Default behavior:

- health-check every 30 seconds;
- 3 consecutive failures before declaring the current VPN failed;
- 2 successful checks before a reserve is accepted;
- recently failed interfaces are quarantined for 180 seconds;
- quarantined interfaces may still be tested as a last resort when no other reserve is healthy;
- no switching based on latency;
- Podkop `main-out` binding and VPN health are verified after a switch.

Additional safeguards in v0.1.1:

- if Podkop is changed from `vpn` mode to another connection type, failover becomes idle and does not modify Podkop;
- a manual change of `podkop.main.interface` resets the accumulated failure counter;
- if the active `awg*` interface is deleted or stops being an AmneziaWG interface, that condition is treated as a failure and reserves are tried after the normal failure threshold;
- a manual Podkop interface change during an in-progress failover aborts the automatic switch instead of overwriting the external choice;
- stale daemon locks left by an abnormal process termination are recovered automatically;
- service restart has a procd termination timeout long enough for the worker to leave its health-check sleep and clean up normally.

Current built-in settings can be displayed with:

```sh
podkop-vpn-failover config
```

## Installation

The current installer targets OpenWrt 24.10.x and older releases using `opkg`.

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh \
  -o /tmp/pvf-install.sh && sh /tmp/pvf-install.sh
```

The installer:

- checks required utilities;
- installs `curl` if necessary;
- optionally installs `luci-app-commands`;
- downloads and syntax-checks the worker, control wrapper and procd init script before replacing installed files;
- configures LuCI Custom Commands.

### First-install safety

On the **first installation**, automatic failover is deliberately left **stopped and disabled**.

First verify discovery and health checks:

```sh
podkop-vpn-failover test
podkop-vpn-failover status
```

Then enable it:

```sh
podkop-vpn-failover-control start
```

### Updating an existing installation

When the installer detects an existing installation, it preserves the previous service state:

- a running service is restarted with the new files;
- a stopped service remains stopped;
- the previous autostart state is preserved.

For testing a specific source snapshot, the installer also accepts an alternate base URL through `PVF_BASE_URL`.

## LuCI

When `luci-app-commands` is installed/configured, the following actions are available under **System → Custom Commands**:

- VPN Failover: Status
- VPN Failover: Test all VPNs
- VPN Failover: Logs
- VPN Failover: Show settings
- VPN Failover: Enable + Start
- VPN Failover: Restart
- VPN Failover: Stop + Disable

Routine operation therefore does not require SSH. Adding and removing reserve VPNs is done normally through **Network → Interfaces** in LuCI.

## CLI

```text
podkop-vpn-failover daemon
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

## Logs and state

Events are written to the OpenWrt system log using the tag `podkop-vpn-failover`:

```sh
podkop-vpn-failover logs
```

or:

```sh
logread | grep podkop-vpn-failover
```

No persistent log file is written to flash. Runtime state, quarantine information and the last-switch record live under `/tmp`, so they are intentionally lost on reboot.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/uninstall.sh \
  -o /tmp/pvf-uninstall.sh && sh /tmp/pvf-uninstall.sh
```

The uninstall script removes the worker, control wrapper, service, runtime state and its LuCI Custom Commands entries. It does not remove `luci-app-commands`, because that package may be used by other tools.

## Current scope and limitations

The current version targets:

- OpenWrt 24.10.x / `opkg`;
- Podkop VPN mode using `podkop.main.interface`;
- AmneziaWG interfaces named `awg*`;
- IPv4 application-level health checks.

Known limitations:

- health currently depends on one external HTTP 204 endpoint (`www.gstatic.com`); an outage or policy block affecting that endpoint through every VPN could look like tunnel failure;
- settings are built into the worker rather than exposed through a dedicated LuCI form;
- runtime history is intentionally non-persistent;
- newer OpenWrt releases using `apk`, other tunnel types and notification integrations are not yet supported.

## Validation performed

The core failover path has been exercised on the target Cudy router with both VPNs left administratively up while their UDP transport was selectively blocked. Verified behavior includes:

- detection of a tunnel that still exists but cannot pass HTTPS traffic;
- 3-failure debounce;
- reserve confirmation with two successful checks;
- Podkop UCI switch and reload;
- generated sing-box `main-out.bind_interface` verification;
- post-switch health verification;
- quarantine;
- no automatic switch-back after the failed VPN recovers;
- failover in both directions;
- procd autostart and restart behavior;
- LuCI Custom Commands operation.

A small GitHub Actions workflow also performs shell syntax validation for project scripts on pushes and pull requests.

## License

MIT.
