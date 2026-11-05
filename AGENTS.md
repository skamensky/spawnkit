# Spawnkit

This repository owns Shmuel's reproducible development machine configuration,
including the user environment, host setup and migration procedures. The shared personal
instructions live in ~/repos/skamensky/personal-agent-customizations/AGENTS.md.
Read them before changing this repository. Follow the RTK shell convention.

Use `nix/modules/home/` Home Manager modules for user packages, shell configuration, dotfiles,
repository bootstrap and user services. Use `nix/modules/nixos/` only on
NixOS. Ubuntu kernel drivers and system services stay with Ubuntu. Their automation
belongs in `ansible/`, with host-specific values under `hosts/<profile>/`. Apply host changes explicitly with `host-config`; never run it from Home Manager.
User services belong in Home Manager. Keep `docs/ubuntu-migration.md` the complete
migration guide and distinguish offline checks from native host/VM acceptance.

Keep one top-level flake and lockfile. Reuse shared modules; host profiles contain
only differences. Preserve automatic default selection for unknown hostnames.
Project development flakes and language dependency lockfiles belong in their
projects. mise owns development runtimes; uv owns Python environments/packages.

After every Nix configuration change, run `home-config check` and `home-config build`
from this checkout. Before committing, build all affected host profiles, including
the default; CI builds the complete x86_64-linux matrix and evaluates aarch64.
Do not claim that evaluation alone confirms a successful activation build.
Commit and push the configuration and flake.lock after validation. Never commit
credentials, private application state, caches or build results. Never place a
secret in a Nix string, derivation, environment.etc or home.file source.

Do not activate on an existing home or overwrite unmanaged files just to test.
Use the isolated activation test. Repo bootstrap must preserve existing checkouts,
including local branches, stashes, worktrees and uncommitted changes. Skills and
assistant settings remain canonical in personal-agent-customizations; Home
Manager creates external symlinks, never copies their contents into this repo.

The root flake composes `nix/outputs.nix` and keeps one shared lockfile. Shared
repository declarations live in `config/repositories.json`. Personal skills
are discovered from the canonical assistant checkout during activation; do not
maintain a duplicate skill inventory.
Keep `hosts/registry.json` the single hostname map. Do not put mutable VM state,
migration inventories or private exports in this repository.

Spawnkit's own software is CLI first. Every graphical front end (dialogs, desktop
entries, notifications) is a thin layer over subcommands that expose the same
primitives with machine-readable output, so agents can do everything a person can
without the GUI. Add the subcommand first, then the GUI that calls it.

Nothing on the desktop is off limits. When an upstream component (a Plasma
applet, a GNOME extension, an application) lacks an option Shmuel wants, fork or
patch it rather than settling for its defaults. Keep each fork reproducible: a
QML-only package is patched and built in Nix (as `tech.shmuel.kickoff`), while one
compiled against Ubuntu's libraries is built by an Ansible host role from a
checksum-pinned upstream tarball and a tracked patch (as `plasma_taskmanager`).
Rename the fork's plugin id under `tech.shmuel.*`, pin it to the upstream version
it was cut from, and fail loudly when the host's version moves.
