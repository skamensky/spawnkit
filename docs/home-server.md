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
| SSH | Tailscale SSH, user `shmuel`, port 22 |
| Underlying OpenSSH host key (ED25519), historical LAN route | `SHA256:KOpbs59QJziYeIRAFtuoSxalXRkrVra5qCddNLnyOjw` |

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
tailscale ssh shmuel@home-server 'id -un; hostname'
```

The laptop's known hosts now pins the verified ThinkPad key for the Tailscale
name, full DNS name and currently discovered address. The intended CI workload is
`SkylineCapital/supa-crm`; its old checkout under the server's `~/repos/supa-crm`
pointed to a personal fork and was purged with the owner-authorized old dev files.

The host key matched the laptop's pre-existing trusted `thinkpad` SSH entry at
its former LAN address. A strict connection using that existing trust succeeded;
the host's public key was then read through that authenticated session and pinned
in agent-vm's known hosts for the new name, full DNS name and discovered address.
Agent-vm's existing owner key authenticated without copying or adding a private
key. Direct SSH and two separate MCP connections passed, including reconnection
and verification of the device ID and DNS name.

Use host verification; do not disable checking. The initial setup used OpenSSH
on the Tailscale address. Later on October 22, Tailscale SSH was observed enabled
(`RunSSH: true`), and a fresh direct connection passed after the owner completed
the tailnet policy browser check. Tailscale SSH now handles port 22 on that
address. The rename itself used only `sudo tailscale set --hostname=home-server`.
A full reboot into kernel `5.15.0-198-generic` and fresh Tailscale SSH passed on October 22.

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
uptime reset. A full reboot into kernel `5.15.0-198-generic` and fresh Tailscale SSH passed on October 22.

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

## Disposable CI VM pool

The server has an x86-64 CPU, VT-x and `/dev/kvm`. The CPU uses `intel_pstate`
with the `powersave` governor; job capacity remains available without a frequency
cap. Its intended CI workload is `SkylineCapital/supa-crm`.

The target pool uses disposable one-job KVM guests, with guest-local Docker and
no host filesystem or Docker socket access. Source and operations are documented
in [the CI VM runbook](ci-vms.md), with host values in
[`hosts/server/ci-vms.json`](../hosts/server/ci-vms.json). Use the narrow
`python3 scripts/configure-ci-vms.py` wrapper, not the full host playbook.

Production status, October 22: the App-owned pool is active for the normal
`home-server` queue, with **three slots, 8 GiB RAM and four virtual CPUs each**.
The 24 GiB total guest allocation leaves nominal host memory headroom. All guests
and the controller share the effective `machine.slice` CPUQuota=560% budget,
equivalent to 70% of eight logical CPUs, with MemoryHigh=24G and MemoryMax=26G.
This dedicated CI server's other libvirt guests would share that budget too.
The controller checks actual QEMU thread placement and effective limits at launch.

The final App-controlled acceptance batch passed seven jobs: three full frontend
controls including browser contracts, three Gmail-panel jobs and one Go, Docker
and Terraform job. It exercised three concurrent VMs, one-job recycling, automatic
return to zero, forced controller restart recovery and guest file/network isolation.
The supported host kernel was booted successfully with the lid closed. The original
two host-account runners were disabled and deregistered; their dedicated account,
workspaces and caches were removed with a root-only hash audit. No host runner
with root-equivalent Docker access remains from this setup.

Earlier exploration passed twelve jobs at two 8 GiB guests and eight jobs at four
6 GiB guests. Four 4 GiB guests failed all six heavy frontend controls. Recycled
QEMU scopes in those earlier batches bypassed the intended custom slice, so those
results cannot establish throughput under a consistent 70% CPU cap. The corrected
three-VM batch passed under the verified effective parent-slice limit. It is a
practical tested limit, not proof of an absolute optimum. No further sizing tests
were run after the owner's final two-test allowance.

Corrected-batch total host CPU peaked at about 76%, including overhead outside
the VM group. Temperature reached 100 C and hardware thermal throttling was
observed. CPU quota does not establish cool operation. At an empty queue there
are zero guest VMs, with the lightweight polling controller remaining active.

Validation workflow routing was promoted separately to dev through
[PR 953](https://github.com/SkylineCapital/supa-crm/pull/953) and
[PR 955](https://github.com/SkylineCapital/supa-crm/pull/955), and master through
[PR 956](https://github.com/SkylineCapital/supa-crm/pull/956) and
[PR 959](https://github.com/SkylineCapital/supa-crm/pull/959). Existing workflow
labels let the VM pool serve both branches without merging unrelated dev changes.

`CI_RUNNER=github-hosted` is the manual failover for new validation runs;
`CI_RUNNER=home-server` restores the normal home pool. Already queued assignments
need cancellation and rerun. This switch passed in both directions earlier that
day, but GitHub later rejected hosted jobs because payments had failed or spending
limits needed increasing. Hosted failover depends on resolving that billing
restriction. No billing settings were changed. Deployments, publishing and remote
smoke workflows retain their existing hosted routing.

The desktop still starts through `graphical.target` and LightDM. Clipboard
monitoring and Xorg were the largest persistent CPU consumers observed. Stopping
LightDM logs out the desktop session; full headless conversion has not been done.
NFS exports are preserved. The older NVIDIA GPU's runtime D3 status was disabled,
so automatic GPU power-off at idle has not been established.
