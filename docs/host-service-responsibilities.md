# Ubuntu host services and Windows VM configuration

Home Manager manages Shmuel's user environment and user services. Ansible will
manage the remaining privileged Ubuntu setup. Both live in this repository;
Ubuntu continues to supply the system packages, kernel drivers and system service
definitions. Windows GPU handoff runs when the VM starts and stops, not at boot.

This is the agreed responsibility split and proposed implementation layout. The
Home Manager infrastructure already exists. The Ansible layer, virtualization
module, VM definition and GPU hooks described below are planned, not installed.
No VM or GPU binding is changed by this document.

## Ownership

| Responsibility | Owner | Tracked source |
| --- | --- | --- |
| Shared user packages, shell, dotfiles and repository bootstrap | Home Manager | Existing `modules/home/` and `users/shmuel.nix` |
| User daemons, timers and their environment | Home Manager | Existing relevant modules; a new `modules/home/services.nix` when shared custom user services are needed |
| virt-manager, virt-viewer, libvirt CLI, Looking Glass client and VM launcher | Home Manager | Planned `modules/home/virtualization.nix` |
| User configuration and desktop entry for Windows/Looking Glass | Home Manager | Planned virtualization module and its referenced source files |
| Ansible command and its dependencies | Nix | Root flake's shared Nixpkgs input; no separate infrastructure flake or lock |
| Ubuntu system package installation | Ansible using APT | Planned `ansible/roles/` |
| QEMU backend, libvirt, OVMF and swtpm configuration | Ansible with Ubuntu packages | Planned `ansible/roles/virtualization/` |
| Docker Engine and NVIDIA Container Toolkit | Ansible with host packages | Planned `ansible/roles/docker/` |
| NVIDIA driver installation and host device permissions | Ansible with Ubuntu-supported setup | Planned `ansible/roles/nvidia/` and host parameters |
| IOMMU boot settings, GPU handoff configuration and libvirt hooks | Ansible | Planned `ansible/roles/gpu_handoff/` |
| Hostname and environment to profile selection | Existing registry and selector | `hosts/registry.json` and `scripts/home-config.py` |
| Profile-specific privileged setup and hardware parameters | Ansible consuming the selected profile | Planned `hosts/<profile>/system.yml` |
| Optional NixOS system configuration | NixOS modules | Existing `modules/nixos/`; Ubuntu roles do not run on NixOS |
| Skills, assistant instructions and private assistant settings | Separate canonical repository | `personal-agent-customizations`; this flake retains external links |

The Ansible roles manage package dependencies, root-owned files, group/device
permissions, service enablement and reload/restart handlers. They are not used to
install user tools or manage home files already owned by Home Manager.

## Repository layout

Paths marked planned below do not exist yet. Role names identify responsibilities;
we will add a role when implementing its corresponding host feature.

```text
nix-config/
├── flake.nix                        # Existing shared inputs and tool packaging
├── flake.lock                       # Existing single infrastructure lock
├── hosts/
│   ├── registry.json                # Existing hostname/environment mapping
│   ├── default.nix                  # Existing minimal Home Manager defaults
│   ├── default-system.yml           # Planned minimal privileged defaults
│   ├── laptop-ubuntu/
│   │   ├── default.nix              # Existing Home Manager host additions
│   │   └── system.yml               # Planned role enablement and hardware values
│   └── <other-profile>/
│       ├── default.nix
│       └── system.yml               # Planned only where host setup is needed
├── modules/
│   ├── home/
│   │   ├── virtualization.nix       # Planned VM clients, launcher, user config
│   │   └── services.nix             # Planned if shared custom user units are needed
│   └── nixos/                       # Existing optional NixOS system integration
├── ansible/                         # Planned privileged Ubuntu automation
│   ├── ansible.cfg
│   ├── inventory.py                 # Uses the existing profile selection logic
│   ├── site.yml
│   └── roles/
│       ├── base/
│       ├── docker/
│       ├── nvidia/
│       ├── virtualization/
│       │   ├── tasks/main.yml
│       │   ├── handlers/main.yml
│       │   └── templates/
│       │       ├── qemu.conf.j2
│       │       └── windows.xml.j2
│       └── gpu_handoff/
│           ├── tasks/main.yml
│           ├── files/               # Auditable helpers and hook dispatcher
│           └── templates/           # Host parameters and any required overrides
├── scripts/
│   ├── home-config.py               # Existing user-environment wrapper
│   └── host-config.py               # Planned explicit Ansible entry point
└── docs/
    ├── host-service-responsibilities.md
    └── windows-vm.md                # Planned native setup and recovery procedure
```

Each feature's templates, scripts and any custom unit definitions stay with its
role rather than in a second central copy. The user launcher source stays with
the Home Manager virtualization module. Exact filenames can be refined during
implementation without changing ownership.

## Systemd files and when they run

We do not need a new systemd unit merely because a step needs root. In particular,
GPU handoff uses libvirt's VM lifecycle hooks; there is no planned always-running
custom GPU handoff daemon or boot-time GPU transfer service.

| Item | Definition source | Runtime behavior |
| --- | --- | --- |
| Existing CopyQ user service | Home Manager desktop module | Follows the user desktop session |
| Future personal watchers or timers | Home Manager `systemd.user` declarations | User login, timer or explicit start, according to the feature |
| Looking Glass | Home Manager desktop entry/launcher | Opened for the VM; no separate daemon is required |
| Libvirt service and sockets | Ubuntu packages | Configure on-demand activation appropriate to the installed Ubuntu version; no guest autostart |
| GPU prepare and cleanup | Our libvirt hooks installed by Ansible | VM startup and shutdown; reject startup if the GPU is busy |
| Docker Engine | Ubuntu/vendor packages | Enable only on opted-in hosts; startup policy declared in its role |
| NVIDIA host services | Installed driver package | Keep only services actually required by the chosen driver and configuration |

Ubuntu may supply monolithic libvirtd or modular daemon units depending on the
installed release and packages. Inspect that package set and configure the units
it actually supplies rather than enabling both architectures.

For a packaged daemon, keep its vendor unit and add a tracked drop-in under
`/etc/systemd/system/<unit>.d/` only when a change is required. Do not copy the
whole vendor unit into Git. If we later need a genuinely custom privileged
daemon, keep its full unit with that feature's Ansible role and install it under
`/etc/systemd/system/`.

Home Manager generates and links user units under `~/.config/systemd/user/`.
Ansible installs privileged files as root-owned copies at stable system paths;
they do not link into a mutable checkout under the home directory. User services
that must survive logout may need explicitly configured lingering; this is a
host setting and is not a reason to turn all user services into system services.

## Machine selection

Retain `hosts/registry.json` as the only hostname mapping. The planned inventory
uses the existing selector to determine the host profile and loads privileged
defaults plus that profile's explicit `system.yml` additions. Do not independently
maintain another hostname inventory.

Unknown hosts retain the functional Home Manager default. Their privileged
default is minimal and does not install virtualization, change GPU bindings,
enable network daemons or change boot parameters. Hardware-dependent roles are
explicitly enabled on known profiles, with environment checks that exclude WSL
and NixOS from native Ubuntu GPU operations.

The laptop profile will declare GPU PCI addresses, all required related functions,
the Windows domain name and other hardware-specific inputs only after discovery
in native Ubuntu. The same hostname under WSL must not select those operations.

## Installed locations and VM state

| Content | Installed or runtime location |
| --- | --- |
| Home Manager clients and launcher | Nix store, exposed through the user profile |
| User service definitions and application configuration | Home Manager links under `~/.config/` |
| Ubuntu QEMU backend and helpers | Distribution package locations |
| Libvirt configuration | `/etc/libvirt/` |
| Hook dispatcher and lifecycle integration | `/etc/libvirt/hooks/` |
| Privileged helper executables | `/usr/local/libexec/nix-config/` |
| Host-specific GPU handoff parameters | `/etc/nix-config/gpu-handoff.conf` |
| Service overrides we actually require | `/etc/systemd/system/<unit>.d/` |
| Windows domain definition | Rendered from Git and registered with system libvirt |
| Windows disk | Planned `/var/lib/libvirt/images/windows.qcow2` |
| UEFI variables, virtual TPM state and other libvirt state | Libvirt-managed locations under `/var/lib/libvirt/` |

VM images, TPM state, UEFI variables, logs and user data are mutable state, not
Git content or Nix derivation inputs. Back them up together using a procedure
that preserves consistency. Never recreate the disk, TPM or UEFI state merely
because a configuration is reapplied. Domain XML changes must be reviewed and
applied at an appropriate VM shutdown boundary.

Credentials remain in the established personal secrets workflow. Tracked files
contain references only; neither Ansible templates nor Nix outputs contain secret
values. Ansible is an application mechanism, not a new credential store.

## Deployment and validation

User and host activation remain separate explicit operations. `home-config
switch` does not invoke sudo or silently apply Ansible changes.

The planned `host-config` entry point selects the profile, previews Ansible
changes with check/diff mode, and applies them only through an explicit apply
operation. Ansible check mode is a preview, not evidence that GPU passthrough
works. No automatic host-configuration timer is planned.

For implementation, pin the Ansible runtime through the shared Nixpkgs input.
Validate role syntax and inventory selection, inspect the preview, and verify
that a second application makes no unintended changes. Any Home Manager changes
still require the repository's `home-config check`, `home-config build` and
affected-profile builds before commit and push. No Home Manager activation is
used merely to test a build.

Native validation must establish IOMMU isolation, display routing, successful
Windows GPU initialization and repeated return to Linux. The pre-start guard
must reject a busy GPU before attempting driver removal. Coordinate known GPU
services and containers, inspect device users, and verify actual driver state.
Hooks must not call back into libvirt. Preserve dual boot until the required
Windows workflows and the return to Linux are verified.

The lockfile pins Nix tools and user packages. Ordinary APT package declarations
recreate intended host setup but do not provide exact historical versions unless
we separately adopt repository snapshots. Source control also does not make
hardware identifiers portable or roll back mutable Windows state.

## References

- [Home Manager systemd module](https://github.com/nix-community/home-manager/blob/master/modules/systemd.nix)
- [Ansible systemd service management](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/systemd_service_module.html)
- [Ansible APT management](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/apt_module.html)
- [Systemd unit files and drop-ins](https://github.com/systemd/systemd/blob/main/man/systemd.unit.xml)
- [Libvirt daemon activation](https://www.libvirt.org/daemons.html)
- [Libvirt lifecycle hooks and restrictions](https://www.libvirt.org/hooks.html)
- [Libvirt system and session instances](https://libvirt.org/drvqemu.html)
