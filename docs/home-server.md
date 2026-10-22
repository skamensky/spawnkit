# Home server

Shmuel's old ThinkPad T460p is the home server. Its headless Spawnkit profile is
`server`, selected by `hosts/registry.json`. The registry recognizes its current
OS hostname, `shmuel-ThinkPad-T460p`, and the intended hostname `home-server`.
These represent the same machine; changing its Tailscale name does not change
its OS hostname.

| Setting | Value |
| --- | --- |
| Hardware | Lenovo ThinkPad T460p, formerly the owner's laptop |
| Role / intended Tailscale name | `home-server` |
| Tailscale device ID | `n4fDtMJMgv11CNTRL` |
| Enrollment | October 22, 2026 |
| Spawnkit profile | `server` |

Use the device ID to distinguish it from the expired 2023 ThinkPad enrollment
(`nNbstF7CNTRL`). Discover addresses through live Tailscale inventory. Do not
enroll the expired identity or pin an observed IP as its identity.

## Personal MCP discovery

Personal MCP's `list_tailnet_machines` reads agent-vm's live Tailscale inventory;
adding a device to Spawnkit is not required for network discovery. The new
ThinkPad already appeared online on October 22, 2026. Once renamed, select its
`home-server` DNS name from that tool's result. The inventory's `name` field may
still contain the OS hostname; use `dns_name` and the stable device ID to identify
it.

The initial SSH listener answered, but its host key is not enrolled on agent-vm.
Remote command access is therefore **pending verification**. The saved Tailscale
admin API credential returned HTTP 401. Complete the initial setup locally on
the ThinkPad:

```bash
sudo tailscale set --hostname=home-server --ssh
```

Then recheck discovery and test Personal MCP with the Linux account confirmed
on the ThinkPad, for example if it is `shmuel`:

```json
{"machine":"home-server","user":"shmuel","ssh_mode":"tailscale","command":"id -un; hostname"}
```

Use Tailscale's authenticated host-key verification. Do not disable OpenSSH host
checking or enroll a key obtained only from an unauthenticated network scan.
Verify a second connection before marking command access ready. Tailscale SSH
policy may require an owner authentication check.

This registration does not install or activate Spawnkit on the ThinkPad.
Determine whether `/etc/spawnkit/enabled` exists before changing its environment;
host activation remains an explicit operation. Further server services belong in
the appropriate Spawnkit subsystem when requested.
