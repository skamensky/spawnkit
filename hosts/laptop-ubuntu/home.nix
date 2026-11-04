{ config, pkgs, ... }: {
  imports = [ ../../nix/modules/home/laptop.nix ];
  personal.environment = "linux";
  personal.desktop.enable = true;
  # Matches plasma in system.yml.
  personal.desktop.plasma = true;
  # The built-in touchpad scrolls naturally, as it did under GNOME; the mouse keeps wheel scrolling.
  programs.plasma.input.touchpads = [
    {
      name = "ELAN06FA:00 04F3:327E Touchpad";
      vendorId = "04f3";
      productId = "327e";
      naturalScroll = true;
    }
  ];
  # Z: in the Windows VM (windows_share in system.yml).
  personal.desktop.copyqShare = "${config.home.homeDirectory}/Shared/.copyq";
  # Must match the running Ubuntu driver (/proc/driver/nvidia/version, nvidia_driver_package
  # in system.yml); update both after an Ubuntu driver upgrade.
  personal.desktop.nvidia = {
    version = "580.178.04";
    sha256 = "sha256-WXWobuRb/8tib1GuM9EWmxCBhqLqR61lHnLxP6S21vk=";
  };
  personal.virtualization.enable = pkgs.stdenv.hostPlatform.isx86_64;
  personal.virtualization.passthroughAudio = [ "0000:01:00.1" ];
  # Ubuntu daemon packages include these clients; do not install parallel copies.
  personal.clients.docker = false;
  personal.clients.tailscale = false;
}
