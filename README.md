# Spawnkit

Shmuel's reproducible development environment: user packages and dotfiles,
machine profiles, Ubuntu host services, repository bootstrap and migration
procedures. Supports Ubuntu, WSL and other Linux hosts, with optional NixOS
integration. Nix is the user-environment subsystem; Ubuntu remains the host OS.

**Start with the [complete Ubuntu migration guide](docs/ubuntu-migration.md).**
It covers Windows/WSL preparation, data preservation, native Ubuntu setup and
verification. Migration inventories, private exports and execution logs stay in
the separate local migration bundle described there.

For first startup and everyday development, read the [twelve practical
workflows](docs/workflows.md), covering packages, VMs, language projects, Docker,
secrets and gcloud.

## Responsibilities and current status

| Area | Source | Status |
| --- | --- | --- |
| User packages, shell, dotfiles, assistants and user services | `nix/` with shared `config/` and machine `hosts/` | Implemented and build-tested; live activation is a migration step |
| Repository cloning and preservation | `config/repositories.json`, `scripts/bootstrap-repos.py` | Implemented |
| Ubuntu packages, system services, permissions and GPU hooks | `ansible/` | Implemented; native apply pending |
| Windows VM and Looking Glass | [VM design](docs/windows-vm.md) | Definition/hooks/launcher implemented; native acceptance pending |
| Optional NixOS system configuration | `nix/modules/nixos/` | Implemented module integration; not required for Ubuntu |

Read the [architecture and service ownership](docs/architecture.md) for the
systemd, Ansible and Home Manager boundary. User services belong in Home Manager.
Ubuntu supplies privileged daemons; GPU handoff uses libvirt hooks on VM start
and stop rather than a custom boot-time daemon.

## Repository map

```text
flake.nix, flake.lock       One shared Nix entry point and pinned inputs
nix/                       Home Manager modules, optional NixOS modules and Nix tests
hosts/                     Shared defaults, machine overrides and hostname registry
config/                    Repository catalog, runtime pins and shell sources
scripts/                   Environment selection and repository bootstrap commands
ansible/                   Ubuntu host roles, lifecycle hooks and VM templates
tests/                     Bootstrap safety and isolated Home Manager activation
docs/ubuntu-migration.md   Complete Windows/WSL to Ubuntu migration guide
docs/architecture.md       Responsibility split, installed paths and host automation
docs/windows-vm.md         GPU passthrough, Looking Glass and native validation
```

The flake remains at the root so every subsystem can share its pinned toolchain.
Its Home Manager and NixOS outputs are composed in `nix/outputs.nix`. Project
development flakes and dependency locks stay in their own repositories.

## Shared configuration and discovery

Personal skills have no manifest in this repository. At Home Manager activation,
`scripts/link-assistant-skills.py` discovers directories containing `SKILL.md` in
`~/repos/skamensky/personal-agent-customizations/skills/`. It links them into
Claude Code and Codex, preserves assistant-provided/plugin skills, and removes
only stale links owned by that canonical source. Private contents stay outside
the Nix store. Instructions and assistant settings remain canonical there too.

[`config/repositories.json`](config/repositories.json) is a catalog of repositories
that a machine may need. Each entry declares its `owner/repository` destination,
SSH clone URL, branch and exact starting commit. Home Manager profiles select
which entries to bootstrap. Missing repositories are cloned at the declared
revision; existing checkouts, dirty work and worktrees are preserved. This is
neither a project dependency lock nor a backup of local changes.

[`hosts/registry.json`](hosts/registry.json) maps hostname plus environment to a
machine profile. Unknown hostnames receive functional defaults. It is the only
hostname map; host automation uses it too.

The old ThinkPad T460p is assigned to the `server` profile as
[`home-server`](docs/home-server.md), with its Tailscale identity and MCP access
verification documented there.

## Build the user environment

From this repository's root:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- select
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- check
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- build
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- repos --dry-run
```

See the [Nix subsystem guide](nix/README.md) for installation, host overrides,
activation and maintenance. Do not activate over unmanaged files merely to test
a build. Host automation remains a separate explicit operation; Home Manager
activation does not install privileged Ubuntu services.

## Machine state and secrets

Only configuration and reusable code belong here. VM disks, virtual TPM state,
UEFI variables, migration inventories, clipboard history, browser profiles,
credentials and execution logs stay outside Git and the Nix store. The migration
guide describes data preservation; a successful flake build is not a data backup.

Nix pins the user toolchain. Ubuntu APT packages remain separately maintained;
the repository does not promise exact historical APT versions without a
separately configured package snapshot.
