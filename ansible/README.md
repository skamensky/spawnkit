# Ubuntu host automation

Implemented roles configure native Ubuntu 24.04+ using Ubuntu packages and systemd.
The controller is packaged by the root Nix flake; it does not install host daemons
through Nix. The current WSL machine has not been applied or enrolled.

The existing Mint home server has a separate, explicit
[`ci-vms.yml`](ci-vms.yml) playbook for disposable repository-only CI virtual
machines. Run it through `scripts/configure-ci-vms.py`, as
documented in [the CI VM guide](../docs/ci-vms.md). It validates the
Tailscale device identity and does not enroll the host into the full Ubuntu
configuration below.

## First installation

Create the existing `shmuel` account, install Git and multi-user Nix, establish
private GitHub access, and clone this repository. From its checkout:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- select
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- inventory
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- check
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- plan --ask-become-pass
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- apply --ask-become-pass
```

Use `--host laptop-ubuntu` explicitly if detection selects a minimal default on
a renamed native laptop. Selection shares `hosts/registry.json` with Home Manager.
Host settings are shared defaults in `hosts/default/system.yml`, extended by
`hosts/<profile>/system.yml`. Add only real hardware values to machine overrides.
`--vars-file` accepts local non-secret installation settings; permanent settings
belong in Git. The inventory is generated, not separately maintained.

`check` is syntax-only and unprivileged. `plan` is Ansible check/diff mode and
needs sudo for host inspection; it never writes the enrollment sentinel. A fresh
host's unavailable packages/services cannot all be simulated: package installation,
daemon operations and privileged helpers are skipped with explanatory previews.
Run `check` and read the inventory as well; a dry run does not prove native setup.
`apply` explicitly invokes `ansible/site.yml` with become; Home Manager never calls
it. Successful completion writes the root-owned `/etc/spawnkit/enabled` sentinel.
A failed first apply can leave partially installed packages, but does not mark
the host enrolled. Reapplying is the supported convergence path.

Reboot after NVIDIA/IOMMU changes and enroll the Ubuntu driver signing key if
Secure Boot requests it. Log in again for Docker/libvirt/kvm group membership.
Tailscale authentication is a separate deliberate login; no auth key enters Git.
On authenticated hosts the Tailscale role also enables Tailscale SSH. If login
happens after host apply, rerun apply or run `sudo tailscale set --ssh` after login.
First-time enablement reroutes tailnet port 22 and can interrupt an OpenSSH
session; apply locally or use an authenticated LAN/IAP/alternate-port recovery
route. The role accepts that rerouting during explicit apply. Verify a fresh
`tailscale ssh` command; browser reauthentication is controlled separately by the
tailnet SSH policy. Host verification stays enabled.
OpenSSH is off by default and requires explicit listen addresses before enabling; the
laptop profile listens only on its tailnet address. Because that address appears
only after tailscaled starts (and Ubuntu's unit does not restart sshd after a bind
failure), the role enables `ip_nonlocal_bind` and orders sshd after tailscaled.
It disables `ssh.socket` before touching listeners: rewriting a live socket makes
systemd lose the inherited sshd, whose old listener then survives restarts until
reboot. After the restart it fails if sshd listens anywhere undeclared. Playbooks
use `force_handlers`, so a later failure cannot drop a notified restart.
Existing cloud access is not replaced by an assumed configuration.

## Roles and state

| Role | Managed state |
| --- | --- |
| `base` | Ubuntu build prerequisites plus profile `host_packages`, optional GDM `desktop_session` pin, Plasma session and the user's `default_session`, `/etc/spawnkit`, installed root helper |
| `docker` | Ubuntu Engine, Compose/Buildx, membership, declared daemon settings |
| `tailscale` | Signed repository/key, package, `tailscaled` service, Tailscale SSH after login |
| `ssh` | Key-only explicit listener drop-in, full listener verification, boot-safe tailnet bind, Ubuntu unit |
| `nvidia` | Ubuntu recommended or pinned driver, optional PRIME profile, signed Container Toolkit repo/runtime |
| `virtualization` | Ubuntu QEMU/libvirt/OVMF/swtpm, groups, IOMMU GRUB drop-in, dedicated NAT network |
| `gpu_handoff` | Separate libvirt lifecycle hook, GPU policy, Looking Glass tmpfiles rule |
| `webex` | Cisco's rolling Webex .deb when absent (unpinned; it self-updates), AppArmor profile for its sandbox user namespace |
| `citrix` | Citrix Workspace app from the pinned, hash-checked .deb in `~/Downloads` (Citrix gates downloads behind its EULA) |
| `windows_vm` | Explicit `vm-define` playbook; managed domain and new disk, no automatic start |

Ubuntu supplies the system service units. This repository stores settings and
Ansible tasks that enable/configure them; it does not symlink checkout files into
root's systemd paths. User services are Home Manager declarations. There is no
custom boot-time GPU-transfer unit. `/etc/tmpfiles.d/spawnkit-looking-glass.conf`
only creates a shared-memory file at boot; ownership transfer occurs at VM start.

Docker configuration merges preserve unrelated keys and save the original once;
changes refuse a restart when containers are running. No disk, volume, token,
Tailscale identity, VM TPM or UEFI state is deleted. Changing package declarations
to false does not automatically purge existing software or state: service removal
requires a deliberate reviewed teardown. This avoids treating disappearance from
a config as permission to destroy a working machine.

APT installation is declarative and repeatable but uses Ubuntu/vendor repositories,
not a byte-for-byte archive of the OS. `flake.lock` pins the controller, user tools
and tests. Exact OS rebuilds would additionally need APT snapshots and image pins.
Pinned public signing-key hashes deliberately fail when upstream rotates a key;
review the new public key and update its hash in Git.

See [architecture](../docs/architecture.md), [Windows setup](../docs/windows-vm.md)
and the [full migration guide](../docs/ubuntu-migration.md). Native driver install,
GPU reset behavior, guest provisioning and physical display routing still need
verification on the actual laptop; offline checks are not hardware validation.
