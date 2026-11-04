# Using Spawnkit

Spawnkit recreates your development environment on an existing Linux machine.
Ubuntu runs the computer; Home Manager supplies your user packages and settings;
mise selects Python and Node versions; uv and the project's Node package manager
install language dependencies. Projects keep their own code, configuration and
lockfiles. Secrets and application data stay separate from all of these.

Home Manager, repository bootstrap, host Ansible roles, GPU lifecycle hooks and
VM launch commands are implemented and checked offline. Native Ubuntu driver
installation and Windows/GPU acceptance remain migration steps. The current WSL
machine has not been applied or enrolled.

For migration and data preservation, use the [complete Ubuntu migration
guide](ubuntu-migration.md). For file ownership and system services, see
[architecture](architecture.md). This guide describes the thirteen everyday
workflows and where each change belongs.

## 1 First startup on a new machine

First boot Ubuntu and establish the basic host: the `shmuel` account with home
`/home/shmuel`, Git, multi-user Nix and access to the private GitHub repositories.
Those are bootstrap prerequisites. Spawnkit does not install Ubuntu, provision a
cloud VM or recover your data from Git. On the existing laptop, preserve and copy
the data described in the migration guide before adopting its dotfiles.

Clone `git@github.com:skamensky/spawnkit.git` into
`~/repos/skamensky/spawnkit`. From that checkout, before RTK is available:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- select
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- check
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- build
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- repos --dry-run
```

Inspect the selected profile and preserve any unmanaged files that would
conflict. Then deliberately activate it:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- switch
```

Activation installs your packages and managed files, clones missing declared
repositories, links assistant instructions/settings, discovers personal skills,
and installs the locked mise runtimes. Existing repositories are preserved,
including local branches and unfinished work. Downloads and private repository
clones need network access and suitable authentication.

**Yes, first startup includes Ansible.** Before Home Manager activation, inspect
and explicitly apply the selected Ubuntu host profile from this checkout:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- select
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- inventory
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- check
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- plan --ask-become-pass
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- apply --ask-become-pass
```

Use `--host laptop-ubuntu` for the native laptop if renamed. This installs the
profile's Ubuntu packages/services, drivers and permissions, and creates
`/etc/spawnkit/enabled` only after success. It does not provision Windows or take
the GPU. Native NVIDIA/IOMMU changes require a reboot and possibly Secure Boot
MOK enrollment; log in again for groups. Then perform the explicit Home Manager
switch above and native graphics-bridge setup. See [host automation](../ansible/README.md)
for dry-run limits and [Windows setup](windows-vm.md) for its second stage.
Home Manager activation alone never runs Ansible or creates the sentinel.
Authenticate required applications separately; identities and sessions stay out
of Git and the Nix store.

## 2 Later startups and everyday packages

Boot Ubuntu and log in normally. Open a terminal, editor or application launcher.
Your activated package generation and managed settings persist across reboots.
You do not run a Nix build or reapply Spawnkit on every boot. Repositories are not
automatically pulled, and package versions are not silently upgraded.

Use commands such as `git`, `rg`, `uv`, `python` and `node` normally. Home Manager
puts tools on PATH; mise selects development runtimes for the current project.
GUI applications launch normally after the graphics setup is complete. No
per-application nixGL launch command is part of the current configuration.

Enabled user services follow their declared session/startup rules. Ubuntu host
services follow their own configuration. Opening the Windows VM is a separate
action, not a boot dependency.

For environment changes, edit the tracked source, check/build and explicitly
switch. New terminal sessions pick up shell settings; existing GUI processes may
need restarting or a fresh login to inherit changed environment variables.

## 3 Windows VM with the GPU

After completing the [native setup](windows-vm.md), use `host-config vm-view` or
the Windows desktop entry. The libvirt hook checks that the RTX is free, prepares the device
handoff, and starts the guest. If a Linux application, GPU container or service
holds it, startup should be refused with an explanation so you can finish or
close that work. There is no automatic transfer of a running CUDA job to Intel.

Ubuntu's desktop stays on Intel. Windows owns the RTX while running. Looking
Glass presents the Windows desktop in a Linux window or fullscreen, using shared
memory for captured frames. Linux can continue doing ordinary desktop and CPU
work. It cannot simultaneously run work on the passed-through RTX.

Shut Windows down to return the GPU to the Linux driver. Cleanup must verify that
the GPU is usable again before reporting success. Closing the Looking Glass
window alone does not shut down Windows or release the RTX. These transitions
run around VM start/stop, not as a custom GPU service at Linux boot.

Keep dual boot until repeated handoffs, Windows applications and required
peripherals work on this laptop. The VM disk, TPM state and UEFI variables are
backed-up mutable state outside Git/Nix. See [Windows VM design](windows-vm.md)
for hardware checks and limitations.

## 4 Another machine without a GPU such as a cloud VM

Treat it as another Linux host running Spawnkit. Create the VM through its cloud
infrastructure workflow first; provision the expected user, Git, Nix and private
repository access. The existing configuration assumes `shmuel` and
`/home/shmuel`; a cloud image's default `ubuntu` or OS Login username is not
automatically substituted.

Clone Spawnkit there. An unknown hostname gets the minimal `default` profile,
with CLI tools, mise/uv and assistants, without desktop graphics or GPU setup.
You can explicitly select the existing headless `agent-vm` profile:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- build --host agent-vm
nix --extra-experimental-features 'nix-command flakes' run .#home-config -- switch --host agent-vm
```

For a permanent mapping, add the real hostname to the appropriate entry in
`hosts/registry.json`. For different requirements, add a new profile's
`hosts/<profile>/home.nix` and registry entry. Shared defaults are imported
automatically. Privileged Ubuntu settings belong in that profile's `system.yml`; inspect and
apply them with `host-config` separately from Home Manager.

The default and current headless profiles deliberately omit gcloud, Docker and
Tailscale clients. Enable required client tools explicitly in the profile:

```nix
personal.clients.gcloud = true;
personal.clients.docker = true;  # client only, e.g. a remote Docker Engine
```

For a local Docker Engine instead, set `docker: true` in `system.yml` and leave
`personal.clients.docker = false`: Ubuntu's Engine package already includes its
CLI and plugins. The same ownership rule applies to Ubuntu Tailscale. A cloud
host needs neither desktop graphics nor Looking Glass. Existing authorized SSH
and cloud access remain separate; no GPU role is implied by using Spawnkit.
Workload identity does not automatically satisfy the current personal-secrets
helper's owner-login requirement.

For a configuration change, run the required checks on the development machine
and build the affected profile on its target architecture. On a small VM merely
installing an already validated configuration, build its selected profile;
`home-config check` builds all native profiles, including the laptop, so it is a
broader and heavier operation. ARM profiles are evaluated in the current matrix,
but require an ARM host or builder for an actual build.

## 5 Add a package

Choose the right scope before installing anything:

| What you are adding | Where it belongs |
| --- | --- |
| General user command | `nix/modules/home/tools.nix` |
| Shared laptop command | `nix/modules/home/laptop.nix` |
| Desktop application | `nix/modules/home/desktop.nix` |
| Tool for one machine profile | `hosts/<profile>/home.nix` |
| Python or Node runtime version | Project `mise.toml`, or Spawnkit's `config/runtimes/` for global defaults |
| Python or JavaScript project dependency | That project's package manifest and lockfile |
| Project compiler, native library or build utility | That project's development flake |
| Privileged Ubuntu daemon or driver | `ansible/roles/` and `hosts/<profile>/system.yml` |

For example, add `tree` to the existing `home.packages` list in `tools.nix`.
From Spawnkit, stage new files if any, then:

```bash
rtk proxy home-config check
rtk proxy home-config build
```

Build the affected profiles, commit and push the validated change. Apply with
`home-config switch` on machines that should adopt it. Builds alone do not
activate the package. Use the full `nix run .#home-config -- ...` form if the
wrapper has not yet been installed.

## 6 Edit a package

Changing settings, updating a version and changing source code are separate tasks:

| Change | Procedure |
| --- | --- |
| Settings, aliases, environment or service behavior | Edit the owning Home Manager module or tracked configuration; validate and switch. Never edit generated home files. |
| Claude Code or Codex version | Automatic: a scheduled workflow bumps the `llm-agents` input. Immediately: `home-config update-agents`, switch, commit flake.lock. |
| Version of a Nix package | Update the relevant input or package expression, then check/build and review the lockfile diff. Updating Nixpkgs can change many packages together. |
| Default Python or Node version | Edit `config/runtimes/mise.toml`, refresh its `mise.lock`, validate and commit both; activate to install the declared versions. |
| Runtime version for one project | Edit its `mise.toml` and lockfile; install and test there. |
| Actual package source or a patch | Track the source change/patch and use an explicit Nix override or package expression. Build/test that package and affected profiles. |
| Dependency inside an application | Use uv/npm/pnpm in that application repository and commit its dependency lock changes. |

Do not edit `/nix/store`, installed binaries or a Home Manager-generated global
mise file. For a deliberate Nixpkgs refresh, run `nix flake update nixpkgs` in
Spawnkit, then validate; it updates the pin rather than your running environment.
[Nix input updates](https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake-update.html).

## 7 Run a Python codebase

For an existing uv project, open its checkout. Install the runtime declared by
the project; use locked mode when it has a complete `mise.lock`. Then sync the
Python environment and run its entry point:

```bash
rtk proxy mise install --locked
rtk proxy mise exec -- uv sync --locked
rtk proxy mise exec -- uv run --locked python -m your_app
```

`your_app` is an example module name; use the repository's documented entry point.
For a project without a mise lock yet, `mise install` installs the declared
runtime; create and commit the project lock as part of making it reproducible.
Do not assume Spawnkit's global lock covers every project's different versions.
[mise locked installs](https://mise.jdx.dev/dev-tools/mise-lock.html).

mise supplies Python. uv creates the project's `.venv` and installs dependencies
from `uv.lock`. Spawnkit disables uv's competing Python downloads. `--locked`
fails if the Python dependency lock needs changing, rather than silently changing
it. No manual virtualenv activation is needed for `uv run`.
[uv locking and synchronization](https://docs.astral.sh/uv/concepts/projects/sync/).

For deliberate dependency changes use `uv add`, `uv remove` or the project's
update workflow and commit `pyproject.toml` with `uv.lock`. Existing non-uv
projects retain their own documented dependency workflow until intentionally
converted. Native dependencies require compatible libraries and a toolchain; follow the
project's tested setup. Nix-built libraries are not automatically compatible with
mise Python. See the mixed-project boundary below.

## 8 Run a Node codebase

mise supplies the project's Node version. For an npm project with an existing
`package-lock.json` and a `dev` script:

```bash
rtk proxy mise install --locked
rtk proxy mise exec -- npm ci
rtk proxy mise exec -- npm run dev
```

`npm ci` installs the locked dependencies into `node_modules`; it rejects a
manifest/lock mismatch instead of updating the lock. Use the actual scripts from
that project's `package.json`. [npm clean installs](https://docs.npmjs.com/cli/v11/commands/npm-ci/).

If the project uses pnpm or Yarn, use its pinned package manager and corresponding
lockfile/frozen-install workflow. Declare a missing manager through the project's
tool setup rather than silently introducing another global installer. Runtime
selection works from the project configuration; `mise exec` also makes it
explicit for scripts and noninteractive agents. [mise command execution](https://mise.jdx.dev/cli/exec.html).

For deliberate dependency edits, use the project's package manager and commit
both manifest and lockfile. Do not commit `node_modules` or install application
libraries as global machine tools.

## 9 Mixed Node Python and Nix codebase

Keep each owner explicit. The project's independent `flake.nix` and `flake.lock`
provide its native tools/libraries or Nix-built components. Its `mise.toml` and
`mise.lock` select development runtimes. uv and the Node package manager own their
respective application dependencies. Spawnkit is not the project's development
flake.

A tested shell can supply **tools** while mise supplies Python/Node. This is not
a blanket guarantee that their native libraries can be mixed. `nix develop` does
not universally set `LD_LIBRARY_PATH`; package hooks or the project shell may set
it, and a normal `mkShell` can also export Nix compiler/linker flags. Injecting
Nix glibc can break an ordinary Linux interpreter. Even without injecting glibc,
a Nix library or Python extension may require a newer glibc than Ubuntu provides.

Use a project `mkShellNoCC` with selected tools and no global Nix runtime-library
path as a starting point. Scope compilers to the component they build. Keep
Python/Node out of its packages when mise owns those runtimes. Test native Python
imports, real extension builds and Node native addons in that actual shell.
Do not solve a failed import by exporting every Nix library into the whole shell.

The practical choices are:

| Need | Coherent setup |
| --- | --- |
| Go/Rust/CLI build tools plus Python/Node apps | Nix tools with scoped compiler environment; mise/uv/npm for the apps |
| mise Python with native extensions | Ubuntu-compatible compiler/libraries or compatible binary wheels; test in that environment |
| A component must link Nix native libraries | Build/package that complete component with Nix, or isolate it in a container; communicate over CLI/HTTP/files |
| Native Node addons | Build against the selected Node and a compatible host toolchain, or isolate the component |

Only after testing a project's shell use, for example:

```bash
rtk proxy nix develop --command mise exec -- uv sync --locked
rtk proxy nix develop --command mise exec -- npm ci
```

`google-automation` now has its **own** flake/lock. It packages the Go CLI and its
CGO SQLite dependency coherently with Nix. Its development shell wraps `go` with
the Nix compiler only for that child process and leaves the parent shell's `CC`
and `LD_LIBRARY_PATH` unset. It provides neither Python nor Node. That specific
shell was tested with Spawnkit's pinned mise Python/Node: Python retained Ubuntu
glibc 2.39, native stdlib imports passed, and Node ran. Deliberately injecting
Nix glibc 2.44 into the same Python's `LD_LIBRARY_PATH` failed with a
`GLIBC_PRIVATE` symbol error; this does not certify
other projects' arbitrary native dependencies. See its README for `nix build`,
`nix run` and `nix develop` commands. No credentials enter the build.

The installed `google-automation` command on the laptop and agent-VM profiles is
that flake's package, consumed as a Spawnkit flake input
(`personal.tools.googleAutomation`). Its revision in `flake.lock` must equal the
`config/repositories.json` pin; the `tool-pins` check enforces this, so update both
together (`nix flake update google-automation` plus the JSON revision). A binary
built inside the dev shell uses a `/nix/store` interpreter and RUNPATH, so it
breaks after garbage collection if copied elsewhere: use `go run .` or the
dev-shell build for development only, and never copy it into `~/.local/bin`.

[Nix development environments](https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-develop.html),
[Python standalone portability](https://gregoryszorc.com/docs/python-build-standalone/main/running.html).

## 10 Build and run Docker containers

Once the Ubuntu Docker Engine, access permissions and required Compose/Buildx
plugins are configured by the native laptop Ansible profile, use Docker normally.
Ubuntu supplies that profile's complete Engine/client/plugins. WSL and remote-only
client profiles do not acquire an Engine just by installing the Nix client.

For a project with a Compose file:

```bash
rtk proxy docker compose up -d --build
rtk proxy docker compose logs -f
rtk proxy docker compose down
```

Compose builds/creates/starts services and detached mode leaves them running.
Keep named volumes and their backups as application state; this example does not
request volume deletion. [Docker Compose startup](https://docs.docker.com/reference/cli/docker/compose/up/).

Dockerfiles and Compose definitions live in the application repository. A normal
Dockerfile gets its runtime/tools from its image and build instructions, not from
the host's mise installation or Nix shell. A Nix-generated container image is an
explicit project build alternative, not the default consequence of using Spawnkit.

Linux GPU containers require the Ubuntu NVIDIA driver and NVIDIA Container
Toolkit. They can use the RTX only while Linux owns it. Stop GPU users before
starting the Windows GPU VM; CPU-only containers may continue running.
[Docker GPU requirements](https://docs.docker.com/compose/how-tos/gpu-support/).

## 11 Manage secrets

The canonical personal credential bundle remains in GCP Secret Manager:
`projects/shmuel-personal/secrets/personal-credentials`, using alias `current`.
The canonical `personal-secrets` skill and `personal-gcp` repository own access
and update behavior. Spawnkit stores references, not secret values.

On a machine with the required owner gcloud login, inspect record names without
printing values:

```bash
rtk proxy python3 ~/repos/skamensky/personal-gcp/scripts/personal-secrets.py inspect
```

Use the helper to select the record an integration needs and consume its values
inside the process or a private temporary export. Clean up temporary files.
Record paths organize the bundle; they are not separate IAM permissions. A
workload needing only a subset should receive it through the approved backend or
deployment mechanism. Updates go through the helper's guarded per-path update,
not a whole-bundle overwrite. Provider runtime copies remain outside Git and the
Nix store, with an explicit refresh/writeback workflow.

There is no implemented universal command that automatically injects all secrets
into every shell or project. Provider logins, browser sessions and OS keychains
retain their own workflows. Follow a domain's skill for its specific integration.
Company credentials are outside this personal store.

The current helper requires `shmuelkamensky@gmail.com` in gcloud's owner login.
It does not yet support ADC, VM metadata credentials or workload federation.
A cloud VM's attached service account therefore does not automatically enable
this personal-secrets workflow. Its CLI also needs to be declared on that host.

## 12 Use gcloud

The laptop profile installs `google-cloud-sdk` through Nix. Add it explicitly to
a headless profile with `personal.clients.gcloud = true` if needed. Run it normally; login and active account/project
state are separate from the package installation.

For personal interactive work:

```bash
rtk proxy gcloud auth list
rtk proxy gcloud auth login shmuelkamensky@gmail.com
rtk proxy gcloud projects list --account=shmuelkamensky@gmail.com
```

Log in only when needed. Commands can specify `--account` and `--project` to
avoid relying on unrelated active defaults. Named gcloud configurations can
separate work contexts. Authentication persists in the provider's local state;
it is not committed or baked into Nix. On a headless machine, use gcloud's
documented browser-on-another-machine flow. General unattended cloud workloads
can use attached service accounts or workload identity where appropriate.
[gcloud authentication](https://docs.cloud.google.com/sdk/docs/authenticate).

Python/Node Google client libraries may need Application Default Credentials
separately from the gcloud CLI login. For local interactive development that
requires ADC, use `gcloud auth application-default login` with the intended
account. This still does not replace the personal-secrets helper's owner-login
requirement. [Application Default Credentials login](https://docs.cloud.google.com/sdk/gcloud/reference/auth/application-default/login).

Update the Nix-owned SDK through Spawnkit's package/input configuration. Declare
extra SDK components through its Nix package configuration when needed, rather
than using the SDK's mutable component updater on a Nix-owned installation.

## 13 Upgrade Ubuntu to a new release

Ubuntu release upgrades are run by Shmuel, not by Spawnkit: `do-release-upgrade`
is interactive, needs sudo and replaces most system packages. Spawnkit only has
to keep working on the new release. Its Ansible roles read the running codename
(`ansible_facts.distribution_release`) for vendor repositories and name real
packages rather than virtual ones, which apt refuses to resolve.

Before upgrading, check that every package Spawnkit installs exists in the new
release: download its `Packages.xz` indexes from `archive.ubuntu.com` (release,
`-updates` and `-security`) and look up the base, host, Docker, virtualization
and pinned NVIDIA driver packages. For the 24.04 → 26.04 (`resolute`) upgrade on
2026-11-04, all were present; `nvidia-driver-580` is the same 580.178.04 as on
24.04, so the laptop pin and Home Manager's driver hash stay valid. Tailscale
publishes `resolute` with the same signing key.

26.04 ships GNOME 50, which has no Xorg session, so the laptop profile moved
from `desktop_session: x11` to `wayland`. Keep your `/etc/gdm3/custom.conf` when
the upgrade asks (it holds the autologin), then delete its
`WaylandEnable=false` line before rebooting; otherwise GDM has no GNOME session
it may start. The host apply below keeps the line removed.

The upgrade disables third-party APT sources. Afterwards:

```bash
sudo do-release-upgrade
sudo sed -i '/^WaylandEnable=false/d' /etc/gdm3/custom.conf
# reboot, then from the checkout:
rtk home-config switch
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- apply --host laptop-ubuntu --ask-become-pass
```

The host apply rewrites Spawnkit's own sources (Tailscale, NVIDIA Container
Toolkit) for the new codename. Chrome and VS Code come from Home Manager, so the
laptop has no APT sources for them. Re-enable any other source Spawnkit does not
own (Claude desktop, PPAs) in Software & Updates, or remove the ones whose PPA
has no build for the new release. Then confirm `nvidia-smi`, a Wayland session
(`echo $XDG_SESSION_TYPE`), `virsh net-list --all` and a Windows VM start with GPU handoff and Looking
Glass, Citrix and Webex; the vendor `.deb` packages are the most likely to break.
On Wayland, also check that `vm-start` does not name `gnome-shell` as an RTX
holder, that Looking Glass still releases input on ungrab (its patch and
`lg-watchdog` are X11 code, so the client must run on XWayland) and that CopyQ
records copies.
