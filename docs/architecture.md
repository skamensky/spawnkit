# Spawnkit ownership and saved state

Spawnkit is a source-controlled machine recipe. Home Manager owns the user
session, Ansible owns privileged Ubuntu setup, mise/uv own language environments,
and each project keeps its own development recipe. No NixOS installation is
required. Native execution of the new host/VM automation is still a migration step.

| Responsibility | Source | Applied location |
| --- | --- | --- |
| User packages, aliases, dotfiles, user services | `nix/modules/home/` | Home Manager generation and home symlinks |
| Shared dependency pins | Root `flake.nix`, `flake.lock` | Nix store |
| Host selection | `hosts/registry.json` | Both `home-config` and `host-config` use it |
| User profile differences | `hosts/<profile>/home.nix` | Home Manager |
| Ubuntu host profile differences | `hosts/<profile>/system.yml` extending default | Generated local Ansible inventory |
| Ubuntu packages, kernel drivers, Docker/libvirt/Tailscale/SSH | `ansible/roles/` | Ubuntu packages and their supplied systemd units |
| GPU transfer policy | `ansible/roles/gpu_handoff/` | `/etc/libvirt/hooks/qemu.d/50-spawnkit` and root helper |
| Windows domain | `ansible/roles/windows_vm/templates/windows.xml.j2` | System libvirt, explicitly defined |
| VM GUI and launcher | `nix/modules/home/virtualization.nix` | virt-manager, Looking Glass, desktop entries |
| Personal instructions/settings/skills | `personal-agent-customizations` checkout | External Home Manager symlinks |
| Project compilers and native tools | Project flake and project lock | That project's Nix shell/build |
| Python/Node versions | Global or project mise files/locks | mise data directory |
| Application dependencies | Project `uv.lock`, Node lockfiles | `.venv`, `node_modules` |
| Secrets | Canonical personal-secrets workflow | Provider runtime state, never Git/store |

The native laptop uses Ubuntu's complete Docker and Tailscale packages, which
include their clients. Home Manager must not install duplicate clients there.
`personal.clients.{gcloud,docker,tailscale}` selects client packages for other
profiles. Headless profiles default to none of these clients; enabling a service
and selecting a client are separate decisions. `laptop-wsl` remains client-only.

## Apply boundaries

`home-config check/build` validates without changing the home. `home-config switch`
is explicit. `host-config check` validates playbooks; `host-config plan` previews;
`host-config apply` invokes privileged Ansible setup. No login hook, Home Manager
activation, scheduled pull or boot timer runs an Ansible apply.

Only a successful explicit host apply creates `/etc/spawnkit/enabled`. The NixOS
integration declares the same path when included in an activated NixOS system.
Home Manager alone does not enroll a machine. Agents check the root-owned sentinel
before treating Spawnkit as authoritative for persistent software changes. Editing
this repository does not enroll the computer doing the editing.

Unknown hostnames use `default`: ordinary user tools and shell configuration,
with native GPU/desktop/daemon features disabled. Known host profiles extend
shared defaults. Cloud instance creation stays with its infrastructure repository.
Ansible currently supports Ubuntu 24.04+; other distributions retain Home Manager
support and need an appropriate system configuration layer. NixOS uses the
separate NixOS modules, not the Ubuntu playbooks.

## System services

Ubuntu supplies `docker.service`, `tailscaled.service`, `ssh.service`, libvirt's
installed daemon/socket architecture and supporting swtpm/OVMF packages. Ansible
installs, enables and configures them rather than copying their vendor units.
Docker/Tailscale run at boot when enabled; libvirt sockets can activate daemons on
demand. IOMMU boot parameters enable kernel capabilities without reserving the GPU.
The dedicated `spawnkit` NAT network is defined without autostart and started on
VM request. A running default libvirt network is not adopted or overwritten.

The GPU hook is a root process invoked by libvirt around VM start/release. It
checks busy devices and IOMMU isolation, reserves the GPU and prepares shared
memory. Libvirt's `managed='yes'` PCI devices perform detach/reattach. The hook
never invokes libvirt recursively. No separate GPU daemon or privileged user
service is needed. Detailed lifecycle and failure behavior: [Windows VM](windows-vm.md).

## Files outside the repository

| Path | Meaning |
| --- | --- |
| `/etc/spawnkit/enabled` | Enrollment marker with selected profile and applied revision |
| `/usr/local/libexec/spawnkit/host-state.py` | Installed reviewed privileged host operations |
| `/usr/local/libexec/spawnkit/gpu-guard.py` | Installed reviewed lifecycle guard |
| `/etc/spawnkit/windows.json` | Applied GPU policy and launcher settings |
| `/etc/spawnkit/windows-definition.json` | Inputs used for explicit VM definition |
| `/etc/spawnkit/windows.xml`, `network.xml` | Rendered desired libvirt definitions |
| `/etc/default/grub.d/90-spawnkit-iommu.cfg` | IOMMU boot prerequisite |
| `/etc/ssh/sshd_config.d/00-spawnkit.conf` | Key-only SSH port and explicit listeners |
| `/etc/sysctl.d/60-spawnkit-ssh.conf`, `/etc/systemd/system/ssh.service.d/50-spawnkit.conf` | Let sshd bind tailnet listeners before tailscaled assigns them at boot |
| `/etc/tmpfiles.d/spawnkit-looking-glass.conf` | Shared-memory permissions |
| `/dev/shm/spawnkit-windows` | Volatile Looking Glass frame memory |
| `/run/spawnkit/gpu-owner.json` | Exclusive reservation; survives an unverified GPU return until `gpu-guard.py reclaim` verifies it, or reboot |
| `/var/lib/spawnkit/windows.xml`, `windows.resolved.xml` | Applied source and resolved definition used to detect manual drift |
| `/var/lib/libvirt/images/spawnkit-windows.qcow2` | Mutable Windows disk; default path |
| `/var/lib/libvirt/qemu/nvram/`, `/var/lib/libvirt/swtpm/` | Firmware/TPM state managed by libvirt |

Root-owned copies are installed by Ansible so a normal Git edit cannot silently
change privileged behavior. No symlink points a privileged hook at a user-writable
checkout. Changing source requires a new explicit apply.

The recipe is reproducible configuration, not a backup. Keep consistent offline
backups of the VM disk, definition, NVRAM and TPM state together; account logins,
application data and unpushed work have their own preservation workflows. Ansible
uses current Ubuntu/vendor APT repositories rather than a frozen OS snapshot.
