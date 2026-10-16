# Ubuntu host automation

This subsystem is planned. No playbook, role or host apply command is installed
yet. The maintained design is in [architecture](../docs/architecture.md), and the
native migration steps are in the [Ubuntu migration guide](../docs/ubuntu-migration.md).

Ansible will manage the privileged Ubuntu configuration that Home Manager cannot
apply: APT packages, root-owned configuration, service/socket enablement, groups,
udev rules and libvirt hooks. It will not manage Home Manager-owned user tools,
dotfiles or personal skills.

The feature roles will cover the required native build dependencies, Docker,
NVIDIA and its container toolkit, Tailscale's `tailscaled` daemon, SSH, libvirt,
and GPU handoff. Add each role with its feature's implementation; unused scaffold
roles are not needed. The Nix-managed Tailscale command alone does not set up the
host daemon. Tailnet identity, keys and login state remain outside Git.

Host selection must consume the existing `hosts/registry.json` and selector;
profile-specific root configuration will live in `hosts/<profile>/system.yml`.
Unknown hosts get a minimal baseline. Native Ubuntu hardware operations must not
run on WSL or NixOS.

Install privileged scripts/configuration as root-owned files and use Ubuntu's
packaged service units, with small drop-ins only where needed. GPU work runs in
libvirt lifecycle hooks. Keep Home Manager switching separate from privileged
host application, and do not enable Windows VM autostart.

The future Ansible runtime will come from the shared root Nixpkgs input. No
second flake or independent Nixpkgs lock belongs in this directory.
