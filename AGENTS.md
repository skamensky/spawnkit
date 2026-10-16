# Personal Nix infrastructure

This repository owns Shmuel's declarative user environment. The shared personal
instructions live in ~/repos/skamensky/personal-agent-customizations/AGENTS.md.
Read them before changing this repository. Follow the RTK shell convention.

Use Home Manager modules for user packages, shell configuration, dotfiles,
repository bootstrap and user services. Use the optional NixOS modules only on
NixOS. Ubuntu kernel drivers and system services stay with Ubuntu; document their
host setup instead of pretending Home Manager owns them.

Keep one top-level flake and lockfile. Reuse shared modules; host profiles contain
only differences. Preserve automatic default selection for unknown hostnames.
Project development flakes and language dependency lockfiles belong in their
projects. mise owns development runtimes; uv owns Python environments/packages.

After every configuration change, run `home-config check` and `home-config build`
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
