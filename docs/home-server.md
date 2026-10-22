# Home server

Shmuel's old ThinkPad T460p is the home server. Its headless Spawnkit profile is
`server`, selected by `hosts/registry.json`. The registry recognizes its current
OS hostname, `shmuel-ThinkPad-T460p`, and its Tailscale name `home-server`.
These represent the same machine; changing its Tailscale name does not change
its OS hostname.

| Setting | Value |
| --- | --- |
| Hardware | Lenovo ThinkPad T460p, formerly the owner's laptop |
| Role / Tailscale name | `home-server` |
| Tailscale device ID | `n4fDtMJMgv11CNTRL` |
| Enrollment | October 22, 2026 |
| Spawnkit profile | `server` |
| OS | Linux Mint 21.3 (Ubuntu-based) |
| SSH | OpenSSH over Tailscale, user `shmuel`, port 22 |
| SSH host key (ED25519) | `SHA256:KOpbs59QJziYeIRAFtuoSxalXRkrVra5qCddNLnyOjw` |

Use the device ID to distinguish it from the expired 2023 ThinkPad enrollment
(`nNbstF7CNTRL`). Discover addresses through live Tailscale inventory. Do not
enroll the expired identity or pin an observed IP as its identity.

## Personal MCP discovery

Personal MCP's `list_tailnet_machines` reads agent-vm's live Tailscale inventory;
adding a device to Spawnkit is not required for network discovery. The new
ThinkPad appeared online on October 22, 2026 and was renamed through its existing
authenticated SSH connection. Both `name` and `dns_name` now identify
`home-server` (`home-server.tail64d65.ts.net`).

Remote command access is **verified** through the deployed Personal MCP:

```json
{"machine":"home-server","user":"shmuel","ssh_mode":"openssh","command":"id -un; hostname"}
```

The host key matched the laptop's pre-existing trusted `thinkpad` SSH entry at
its former LAN address. A strict connection using that existing trust succeeded;
the host's public key was then read through that authenticated session and pinned
in agent-vm's known hosts for the new name, full DNS name and discovered address.
Agent-vm's existing owner key authenticated without copying or adding a private
key. Direct SSH and two separate MCP connections passed, including reconnection
and verification of the device ID and DNS name.

Use OpenSSH host verification; do not disable checking. Tailscale SSH was not
enabled: it would replace the working port-22 SSH route. The rename required only
`sudo tailscale set --hostname=home-server`. A full reboot has not been tested.

This registration does not install or activate Spawnkit on the ThinkPad. Its
`/etc/spawnkit/enabled` sentinel was absent during inspection. Recheck before changing its environment;
host activation remains an explicit operation. Further server services belong in
the appropriate Spawnkit subsystem when requested.
