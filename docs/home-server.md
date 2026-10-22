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
A full reboot has not been tested.

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

The machine has an x86-64 CPU, VT-x and `/dev/kvm`. The CPU uses the
`intel_pstate` driver with the `powersave` governor. CPU capacity remains
available for jobs; no CPU frequency cap was introduced.

The repository-only runner is `home-server-supa-crm` for `SkylineCapital/supa-crm`,
with labels `self-hosted`, `Linux`, `X64`, `home-server`, and `supa-crm`. Each runner
process accepts one job at a time. The normal pool has two processes. Its first
boot-enabled systemd unit is
`actions.runner.SkylineCapital-supa-crm.home-server-supa-crm.service`.

Provision it explicitly from this checkout on the controller:

```bash
python3 scripts/configure-github-runner.py --syntax-check
python3 scripts/configure-github-runner.py
```

The wrapper uses the current pinned Nixpkgs Ansible package, the authenticated
`gh` CLI, and strict direct SSH. It gets an expiring repository registration
token into memory, passes it through the environment to a `no_log` registration
task, and keeps it out of arguments, Git and inventory files. GitHub's resulting
provider-managed credential files live only in the runner directory with mode
0600. The initial official archive version and SHA256 are pinned in
[`hosts/server/github-runner.json`](../hosts/server/github-runner.json); the
provider's normal runner auto-updater remains enabled.

[`ansible/github-runner.yml`](../ansible/github-runner.yml) is a narrow playbook
for this enrolled Tailscale device ID. It does not run the full Ubuntu host
configuration or create `/etc/spawnkit/enabled`. It provisions the existing Mint
host, the non-sudo `github-runner` account, and the official service. The account
belongs to the Docker group because validation workflows build containers;
Docker access permits privileged host operations. Jobs run from
`/opt/actions-runner/supa-crm`, with tool downloads in
`/var/cache/github-actions/toolcache` and account state in
`/var/lib/github-runner`.

Chromium's system libraries are installed through APT so browser jobs do not need
sudo. The role also refreshes Google's official signing key, whose newer Chrome
subkey was absent from this old installation. Timeshift scheduling is
disabled at the owner's request, and existing snapshots were deleted. The runner
workspace, cache and account state are excluded if snapshots are created manually.

Validation workflow routing is merged separately into `dev` through
[Supa-CRM PR 953](https://github.com/SkylineCapital/supa-crm/pull/953) and `master`
through [PR 956](https://github.com/SkylineCapital/supa-crm/pull/956). The repository
Actions variable `CI_RUNNER=github-hosted` switches new
validation runs to GitHub-hosted Ubuntu if the home server is unavailable;
`CI_RUNNER=home-server` restores the default home runner. Cancel and rerun jobs
that were already queued before changing the variable. This is manual failover,
not an automatic health check. Deployments, publishing, infrastructure apply and
authenticated remote smoke workflows retain their GitHub-hosted routing.

The manual switch passed acceptance in both directions earlier on October 22.
Later that day GitHub rejected hosted jobs because account payments had failed
or the spending limit needed increasing. Hosted failover currently depends on
resolving that account billing restriction; changing the routing variable alone
cannot bypass it. The final live setting is `CI_RUNNER=home-server`.

October 22 live acceptance: the runner is online and boot-enabled. Its first
[status-monitor validation job](https://github.com/SkylineCapital/supa-crm/actions/runs/39776879722/job/119817960145)
completed successfully on `home-server-supa-crm`, including Go setup/tests/vet,
a Docker image build, Terraform setup/validation and runtime Terraform tests.
A full physical reboot has not been exercised. Provider credentials are mode
0600, and the CI account cannot use sudo.

The desktop still starts through `graphical.target` and LightDM. Its clipboard
monitor and Xorg are the largest persistent CPU consumers observed. Headless
operation is the next useful reduction, but stopping LightDM logs out the
existing desktop session. NFS has configured exports; inspect their purpose before disabling them.
The NVIDIA driver's runtime D3 status is disabled on this older GPU, so do not
claim it automatically powers off at idle.

## Concurrent CI and resource budget

The October 22 capacity test configured ten temporary workers and observed nine
simultaneous jobs, near-full CPU use and CPU thermal throttling at 97-99 C, with
more than 22 GiB of memory still available and no OOM events. Four heavy frontend
jobs can already use most of the CPU. The conservative normal pool is two workers
(rounding down 70% of a practical four-heavy-job ceiling), rather than treating
available memory as permission to keep adding workers.

`hosts/server/github-runner.json` declares the worker count and aggregate CPU
quota. Each worker has a separate installation/workspace and `PLAYWRIGHT_PORT`
(52001, 52002). The shared `githubrunner.slice` caps worker and Docker workload CPU
time at 560%, equivalent to 70% of the host's eight logical CPUs. This is one
aggregate budget, not 560% per worker. A 24 GiB memory high-water mark requests
reclaim under pressure; it is not a hard per-job memory allocation.

Docker's daemon and new containers share that slice. The role preserves existing
Docker settings and requires running containers to be drained before restarting
the daemon to move its cgroup. Apply worker service changes during an idle
maintenance window. The worker-count limit bounds GitHub job intake; the kernel
CPU quota throttles execution inside that budget. This is not a scheduler that
predicts each job's future resource needs.

Temporary workers use the distinct `home-server-benchmark` label. The manual
frontend workflow can check any selected PR head without changing its branch;
its CI harness comes from the workflow revision. The capacity test found and
fixed a shared-port assumption in Playwright, so concurrent browser suites now
bind separate loopback ports. See the task's capacity report for per-PR outcomes,
raw metrics, and limits of the measurement. A full physical reboot remains untested.

The provisioning wrapper temporarily removes the normal intake label, waits for
active jobs to finish, applies the playbook, then restores intake. It also restores
labels on ordinary errors. This drain was added after an initial live update
restored intake too early and interrupted one check; that check was rerun. The
drain's wait, error recovery, timeout and surplus-worker guard have regression
coverage. When reducing an existing pool, retire surplus workers first; the
wrapper refuses to leave extra workers running silently.
