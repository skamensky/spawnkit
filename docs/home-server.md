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
| CPU | Intel Core i7-6820HQ, 4 cores / 8 threads, 2.7 GHz base / 3.6 GHz maximum |
| RAM | 32 GB DDR4-2133, 2 × 16 GB Samsung modules |
| Storage | SanDisk SSD PLUS 480 GB SATA SSD |
| Graphics | Intel HD 530 and NVIDIA GeForce 940MX, 2 GB VRAM |
| Network hardware | Intel I219-LM Ethernet and Wireless 8260 |
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

When working from the laptop, use direct SSH in preference to the MCP bridge:

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes shmuel@home-server 'id -un; hostname'
```

The laptop's known hosts now pins the verified ThinkPad key for the Tailscale
name, full DNS name and currently discovered address. The intended CI workload is
`SkylineCapital/supa-crm`; its old checkout under the server's `~/repos/supa-crm`
points to a personal fork and is not the authoritative current codebase.

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

## Closed-lid server operation

On October 22, 2026, the installed systemd and MATE settings were changed and
read back successfully. All three logind lid policies and its idle action report
`ignore`; MATE's AC and battery lid actions report `nothing`, with computer idle
sleep disabled. SSH and MCP reconnection passed after restarting logind. Physical
lid closure was verified later that day: both the ACPI lid sensor and logind
reported closed, and fresh direct SSH commands succeeded without a reboot or
uptime reset. A full reboot has not been tested.

The systemd source is [`hosts/server/logind.conf`](../hosts/server/logind.conf).
Install it independently of full host enrollment, from this checkout on the
server:

```bash
sudo install -D -m 0644 hosts/server/logind.conf /etc/systemd/logind.conf.d/90-home-server.conf
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
gsettings set org.mate.power-manager button-lid-ac 'nothing'
gsettings set org.mate.power-manager button-lid-battery 'nothing'
gsettings set org.mate.power-manager sleep-computer-ac 0
gsettings set org.mate.power-manager sleep-computer-battery 0
sudo systemctl restart systemd-logind
```

Run the `gsettings` commands as `shmuel` against the existing user session.
Both layers matter because MATE takes the lid-switch inhibitor and handles
events itself while its desktop session runs. See the
[systemd 249 logind reference](https://www.freedesktop.org/software/systemd/man/249/logind.conf.html).
The full Spawnkit Ansible playbook currently targets Ubuntu 24.04+, so it must
not be applied to this Mint 21.3 host as part of this narrow setting change.

## Runner preparation

The machine has an x86-64 CPU, VT-x and `/dev/kvm`, Docker installed, and no
running containers or GitHub Actions runner at inspection. The CPU uses the
`intel_pstate` driver with the `powersave` governor. CPU capacity remains
available for jobs; no CPU frequency cap was introduced.

The desktop still starts through `graphical.target` and LightDM. Its clipboard
monitor and Xorg are the largest persistent CPU consumers observed. Headless
operation is the next useful reduction, but stopping LightDM logs out the
existing desktop session. NFS has configured exports, and Timeshift has an
existing scheduled backup policy; inspect their purpose before disabling them.
The NVIDIA driver's runtime D3 status is disabled on this older GPU, so do not
claim it automatically powers off at idle.
