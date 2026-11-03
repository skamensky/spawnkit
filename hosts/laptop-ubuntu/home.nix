{ pkgs, ... }: {
  imports = [ ../../nix/modules/home/laptop.nix ];
  personal.environment = "linux";
  personal.desktop.enable = true;
  # GDM is pinned to Xorg (desktop_session: x11 in system.yml).
  personal.desktop.session = "x11";
  # Must match the running Ubuntu driver (/proc/driver/nvidia/version, nvidia_driver_package
  # in system.yml); update both after an Ubuntu driver upgrade.
  personal.desktop.nvidia = {
    version = "580.178.04";
    sha256 = "sha256-WXWobuRb/8tib1GuM9EWmxCBhqLqR61lHnLxP6S21vk=";
  };
  personal.virtualization.enable = pkgs.stdenv.hostPlatform.isx86_64;
  # Ubuntu daemon packages include these clients; do not install parallel copies.
  personal.clients.docker = false;
  personal.clients.tailscale = false;
}
