# Disposable home CI

The home server runs repository jobs inside one-job KVM virtual machines.
[`hosts/server/ci-vms.json`](../hosts/server/ci-vms.json) declares the repository,
maximum slots, guest CPU/RAM/disk size, image and runner checksums, kernel baseline
and shared CPU quota. The controller scales to zero guests when its queue is empty.
Each guest accepts one job and its writable disk is destroyed afterward.

## Boundary

QEMU runs as libvirt's confined user with an enforcing per-domain AppArmor profile.
Guest disks have an immutable, root-owned base and private disposable overlays.
There are no host filesystem shares, host Docker/libvirt sockets, host SSH keys,
personal credentials, nested VMX, USB/PCI passthrough or Tailscale enrollment in the guests.
Docker and passwordless sudo exist inside the disposable guest. Guest root is
expected; it does not grant host root through the normal interfaces.

The dedicated bridge uses isolated guest ports and libvirt's `clean-traffic`
MAC/IP anti-spoofing filter. A separate nftables table rejects guest access to
the host, LAN, tailnet, link-local/metadata addresses, other guests and IPv6
forwarding. The only host service exposed to guests is the bridge DNS resolver.
Public IPv4 HTTP/HTTPS is allowed for GitHub, package registries and CI APIs.
No public listener is added for the controller.

This server is dedicated to CI virtualization. All libvirt guests and the
production controller share the host `machine.slice`, with 560% CPU time
across eight logical CPUs, equivalent to 70% of the host. MemoryHigh=24G requests
reclaim and MemoryMax=26G bounds that group. These CPU and memory limits protect
availability; they do not replace the VM security boundary. Jobs remain limited
by each guest's own memory and vCPU allocation.

Workflows and dependencies remain arbitrary code inside the guest. A job can
read any CI secret intentionally delivered to it and can send guest data to the
internet. Repository administrators retain that authority. Hypervisor and host
kernel security updates are part of maintaining the boundary; the production
controller refuses kernels older than the declared minimum.

## Host provisioning

This Mint host is not enrolled in full Spawnkit. The narrow playbook checks its
Tailscale device ID and does not create `/etc/spawnkit/enabled`:

```bash
python3 scripts/configure-ci-vms.py --syntax-check
python3 scripts/configure-ci-vms.py
```

The wrapper uses the root flake's pinned Ansible package and verified direct SSH.
The role installs native Ubuntu/Mint virtualization tools, stages the supported
`linux-generic` update, defines the resource slice, network, firewall and host
controller, and enables pool startup without starting it during provisioning.
For maintenance, drain and stop the pool before applying this role. Keep the
root-owned pause file present across the first kernel reboot; verify the new
kernel and guest network before removing it. Reboot into the staged kernel
before starting production jobs.
Do not apply the full Ubuntu 24.04 host playbook to this existing Mint system.

Build the base image through direct SSH:

```bash
sudo spawnkit-ci-vm build-image
```

The builder installs signed Ubuntu packages and the checksum-pinned official
runner, enables its guest agent and Docker, clears machine identity and SSH host
keys, and leaves a readiness marker. Once provisioning finishes:

```bash
sudo spawnkit-ci-vm finalize-image
```

Finalization verifies the readiness marker and services through the guest agent,
shuts down the builder, produces a standalone read-only base, records its hash
and removes the temporary builder. A native probe and real CI acceptance are
required before activating a newly built image. Installed packages follow the
signed APT repositories at build time; this is not a byte-for-byte pinned OS
snapshot. Rebuild during a drained maintenance window when updating it.

## GitHub authentication

`scripts/bootstrap-ci-github-app.py` prepares GitHub's interactive manifest flow
at localhost port 8739. Review and create the private organization app, then
install it on **SkylineCapital/supa-crm only**. Its permissions are:

- Repository Administration write, required by GitHub to register and retire
  repository runners.
- Actions read, to inspect queue metadata and create guests only on demand.
- GitHub's implicit repository Metadata read permission.

The bootstrap callback delivers the generated private key directly through SSH
to root-only `/etc/spawnkit-ci/github-app.pem`, with public app metadata in
`github-app.json`. This is a provider runtime credential, not a tracked config
value. No personal GitHub OAuth token is copied to the server. The app belongs
to SkylineCapital and its company credential is not added to the personal
credential bundle.

After installation:

```bash
sudo spawnkit-ci-vm bind-app
sudo systemctl enable --now spawnkit-ci-pool
```

The controller mints short-lived installation tokens restricted to the declared
repository ID and permissions. Only one-job JIT runner configuration enters a
guest, on its private seed disk. The app private key and installation token never
enter the VM. Runner names are host-generated UUIDs, and job-provided names,
commands and outputs are never interpreted as host commands.

The pool polls queued/in-progress workflow metadata and matches the normal
`home-server` labels. The temporary VM capacity branch uses `home-server-vm-benchmark`; existing
workflow revisions use `home-server-benchmark`. Neither label consumes this pool. New guests are rejected unless every QEMU thread is inside the capped machine
slice and its effective CPU/memory limits match configuration. XML placement
alone was insufficient on this host. New guests have a cold-boot delay; no
guest is kept warm indefinitely when there is no work.

## Maintenance and retirement

Create `/etc/spawnkit-ci/paused` to stop new guest creation and drain idle guests.
The controller removes an idle runner's intake label and waits at least one
poll interval before retirement, allowing a concurrent assignment to become
visible. Busy one-job guests finish normally. SIGTERM drains before exit;
the systemd stop timeout accommodates the configured two-hour maximum lifetime.

Stop the pool after draining before changing its controller or base image.
Configuration changes affect newly created guests. Drain completely before
changing guest disk size, controller code or the base image. A reduced slot count drains
surplus idle guests. A failed API operation stops provisioning and retries through
systemd. Each loop enforces VM lifetime locally before contacting GitHub. Expired guests
are destroyed even if GitHub deregistration fails; their
root-owned registration receipt is retained until revocation succeeds.

Only controller-generated `ci-<UUID>` paths are eligible for disk removal.
Retirement refuses to remove a live VM's disks and retains exact paths, hashes,
allocated bytes and reasons in `/var/log/spawnkit-ci/lifecycle.jsonl`. The base
image and active guest dependencies remain protected. VM disks are explicitly
disposable job state; publish build deliverables through GitHub artifacts before
the job exits.

The original two host-account runners were drained, disabled and deregistered
on October 22. Their account, workspaces and caches were retired with a root-only
hash audit. Never leave a second normal pool running directly on the host.
The existing repository variable `CI_RUNNER=github-hosted` remains the explicitly
requested manual failover; current billing eligibility must be checked before
relying on it. Changing the variable does not move already queued assignments.

Native acceptance must include real frontend/browser and Go/Docker jobs, guest
file/network isolation, successful one-job recycling, controller restart, queue
scale-up and return to zero. Ansible syntax and Python regression tests alone do
not establish hardware, firewall or full-reboot behavior. Record what was actually
tested alongside the capacity measurements.

## Verified deployment, October 22, 2026

The production configuration is three 8 GiB guests with four virtual CPUs each,
sharing the effective 70% host CPU-time budget. Seven jobs passed through the
App-owned controller: three frontend/browser controls, three Gmail-panel jobs and
one Go/Docker/Terraform acceptance job. The test verified automatic provisioning,
one-job recycling, return to zero, recovery after forced controller termination,
file/network isolation and separate guest Docker. A full closed-lid reboot into
kernel `5.15.0-198-generic` and fresh Tailscale SSH passed before that batch.
Earlier custom-slice tests had inconsistent QEMU placement; only the final batch
establishes operation under the corrected effective cap. All future libvirt VMs
on this dedicated CI server share the machine slice. Hardware thermal throttling
and 100 C CPU temperature remain observed limits.
