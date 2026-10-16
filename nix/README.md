# Nix user environment and optional NixOS integration

This is the Nix subsystem of spawnkit. Run the commands below
from the repository root, not this directory. It supports Ubuntu, WSL, other
Linux hosts and optional NixOS integration. Home Manager owns the user environment; Ubuntu keeps its
kernel, drivers and system services. All Nixpkgs consumers share the root input
and flake.lock. Project development flakes remain independent.

## Start on a new machine

Prerequisites: Linux on x86_64 or ARM64, user `shmuel` with home `/home/shmuel`,
Nix with flakes, and GitHub SSH access to the declared private repositories.
Follow the [official multi-user Nix installation instructions](https://nix.dev/manual/nix/stable/installation/installing-binary.html).
Nix installation and initial GitHub authentication are host bootstrap steps.

```bash
mkdir -p ~/repos/skamensky
git clone git@github.com:skamensky/spawnkit.git ~/repos/skamensky/spawnkit
cd ~/repos/skamensky/spawnkit
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- select
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- check
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- build
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- repos --dry-run
```

Inspect and preserve existing dotfiles before activation. Home Manager refuses
unmanaged-file collisions. On a fresh home, or after deliberately adopting those
files, activate:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- switch
```

Activation clones missing declared repositories, installs external assistant
symlinks, and installs the locked mise runtimes. It requires network access and
GitHub SSH authentication. Failed repository cloning stops before installing
home-file links. Existing checkouts are validated and never pulled, reset,
checked out, stashed or overwritten. A fresh checkout starts at its declared
commit on its declared branch; upstream updates are an explicit developer action.

After activation, log out/in so desktop processes inherit the session environment.
`home-config` is then available directly. `home-config build` builds without
activation; `home-config check` builds all five native profiles and safety tests,
evaluates both supported architectures and checks optional NixOS module composition.

## Host selection

`hosts/registry.json` is the selection source of truth. The wrapper normalizes
the short hostname, detects WSL versus ordinary Linux versus NixOS, and detects
CPU architecture. Unknown names automatically select `default`, including on
WSL and NixOS; no new output or host entry is required.

| Profile | Automatic hostname | Additions to shared defaults |
| --- | --- | --- |
| default | Any unrecognized hostname | CLI tools, Git, shell, tmux, mise/uv, core repositories and assistant links |
| laptop-wsl | TopLap123 running WSL | Laptop tools/repos; Windows clipboard and PowerShell integration |
| laptop-ubuntu | TopLap123 running native Linux | Laptop tools/repos, GUI applications, CopyQ service and graphics integration |
| agent-vm | safe-phone-controller | Safe Phone, personal Supabase and Google automation source repos |
| server | Explicit selection until a real hostname is registered | Headless profile with Safe Phone repo |

For inspection or a host override:

```bash
home-config select --hostname new-machine --environment linux
home-config build --host laptop-ubuntu
home-config build --host default --system aarch64-linux
```

The last command requires an ARM64 machine or a configured ARM64 builder to build;
all architecture/profile combinations are evaluated on every `check`.
Explicit unknown profile names are errors. Profile selection is implemented by
the wrapper, because Nix flake attribute selection has no wildcard default.
Flake outputs are named `homeConfigurations."shmuel@PROFILE-SYSTEM"`, with a
`-nixos` suffix for standalone Home Manager on NixOS.

## Modules and ownership

- `hosts/default/home.nix` imports the shared home module collection.
- `nix/users/shmuel.nix` declares identity and the two core bootstrap repositories.
- `nix/modules/home/laptop.nix` shares laptop tools/repos across native and WSL.
- `nix/modules/home/git.nix`, `shell.nix`, `tools.nix`, `runtimes.nix`,
  `repositories.nix`, `assistants.nix` and `desktop.nix` own their respective areas.
- `nix/modules/nixos/ssh.nix` and `docker.nix` are opt-in system modules. They do
  not reconfigure Ubuntu services or expose ports on non-NixOS hosts.

The shell translates the useful old `.mybashrc.sh` behavior into Home Manager:
editor settings, history, completions, explicit dangerous-agent aliases, the
Corteza tunnel shortcut, the CRM tmux launcher and the fzf window selector.
Credentials, old nvm initialization and WSL display paths are not sourced.
The old global HTTPS-to-SSH rewrite is deliberately omitted; bootstrap uses
explicit SSH URLs and GitHub CLI is configured to use SSH.

## mise and uv

Nix installs mise and uv. Development Python and Node come from mise, not
Nixpkgs. `config/runtimes/mise.toml` declares exact versions; `config/runtimes/mise.lock` records
download URLs and checksums for Linux x64/ARM64. Home Manager installs both files
and runs `mise install --locked` during activation. Language dependencies stay
in the project's existing package manager and lockfile.

The session PATH includes mise's executable dispatchers so GUI applications and
noninteractive agents can find runtimes. `UV_PYTHON` points to the Python
dispatcher; an activated mise environment supplies its selected interpreter
directly. uv will not download a competing Python installation.

```bash
mise exec -- python --version
mise exec -- node --version
uv sync --locked       # in an existing uv project
uv run python script.py
```

Projects can declare their runtime requirements in their own `mise.toml` or
existing `.python-version`/`.nvmrc` files. They are not automatically converted to
Nix development flakes. Missing project runtimes must be installed with mise;
the infrastructure lock covers global defaults, not every project's toolchain.

To update the global defaults, edit exact versions in `config/runtimes/mise.toml`, then
run `mise -C config/runtimes lock --platform linux-x64,linux-arm64` from this repo. Trust
the reviewed config with mise when prompted. Build, test, commit and push both
files. Native C build dependencies for downloaded Python/Node runtimes normally
come from Ubuntu (`build-essential`, relevant development libraries); a project
can independently declare a Nix build environment when it needs one.

## Repositories and assistant content

`config/repositories.json` contains verified remote URLs, branch names and bootstrap
commit pins. Laptop profiles include the important personal repositories and
SkylineCapital/supa-crm. Repositories without an upstream remote in the migration
inventory still require copying from the old disk; this flake cannot clone them.

Home Manager discovers personal skill directories containing `SKILL.md` from the
canonical cloned personal-agent-customizations checkout during activation. There
is no duplicate skill inventory here. It links each skill for both assistants,
preserves assistant-managed `.system` directories and plugins, and removes only
stale links pointing to that canonical skill directory. Instructions and settings
also resolve to the canonical checkout. Private contents stay out of the Nix store.

Fresh clones use the pinned content revision. Existing developer checkouts remain
mutable and may deliberately contain newer skills or preferences; that state
must be committed/pushed in its own repository. This flake recreates the declared
baseline, rather than silently resetting active work to a historical revision.

Secrets remain in the personal-secrets GCP store and provider session stores.
Follow that skill to obtain credentials. None of the legacy plaintext export
values are imported into this flake. SSH keys, browser profiles, application data,
agent history and credentials are separate migration items.

## Ubuntu graphics and host services

The native laptop profile uses Home Manager's `targets.genericLinux.gpu`
integration. It exposes graphics libraries through `/run/opengl-driver`; GUI
packages need no per-app nixGL wrapper. Home Manager prints the exact
`non-nixos-gpu-setup` command to run with sudo when the host link needs updating.
WSL and headless profiles do not enable this native graphics setup.

The Intel/Mesa path is configured. Before NVIDIA offloading on native Ubuntu,
read the running driver version and prefetch the matching upstream installer:

```bash
cat /proc/driver/nvidia/version
nix store prefetch-file https://download.nvidia.com/XFree86/Linux-x86_64/VERSION/NVIDIA-Linux-x86_64-VERSION.run
```

Declare the real values in `hosts/laptop-ubuntu/home.nix`:

```nix
personal.desktop.nvidia = {
  version = "EXACT_HOST_DRIVER_VERSION";
  sha256 = "UPSTREAM_INSTALLER_HASH";
};
```

These placeholders are documentation, not an active configuration. Do not guess
them from the Windows driver or from WSL. Keep them synchronized with Ubuntu
driver changes. The configuration can build before those hardware facts are
known, but NVIDIA acceleration has not thereby been verified.

Ubuntu owns NVIDIA kernel drivers, Docker Engine, NVIDIA Container Toolkit,
Tailscale/SSH daemons and libvirt. Home Manager supplies relevant client tools.
Solaar also needs the appropriate host udev permissions. Review the migration
runbook before changing services. Windows GPU passthrough remains a separate
native hardware investigation; no VFIO bindings or VM are created here.

The [host service responsibility plan](../docs/architecture.md)
records the agreed Home Manager/Ubuntu boundary and proposed Ansible layout,
including machine selection, systemd units, on-demand libvirt hooks and VM state.
The Ansible and Windows VM components in that plan are not implemented yet.

## Optional NixOS integration

Import this flake's `nixosModules.default` into an independently configured NixOS
host and make that host's nixpkgs input follow this flake's nixpkgs. It integrates
Home Manager for `shmuel` using the same registry and shared modules. Import the
`ssh` or `docker` system modules where needed; define users, disks, bootloader,
authorized keys and hardware in the actual NixOS host configuration.
The default system module enables nix-ld with common runtime libraries so mise's
downloaded Python/Node binaries can run on NixOS. Standalone Home Manager on
NixOS requires this host setup too; Home Manager cannot install a system loader.

## Validation and maintenance

```bash
home-config check
home-config build
bash tests/home-activation.sh
```

The integration test uses a temporary home, proves an unmanaged `.bashrc` causes
activation to fail without replacement, then activates twice. It never activates
against the real home. Bootstrap tests cover unknown hosts, pinned fresh clones,
dirty branches, worktrees, failed clones, incorrect origins and path validation.
GitHub Actions runs the build/evaluation checks and isolated activation on pushes
and pull requests. ARM64 is evaluated, not built on the x86_64 CI runner.

Before adding new files to a flake, stage them in Git so ordinary `nix run .#...`
can see them. Review input updates explicitly with `nix flake update`; build all
affected profiles before committing flake.lock. Agents follow this repository's
AGENTS.md and the canonical shared Home Manager policy.
