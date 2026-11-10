{ config, pkgs, ... }: {
  imports = [ ../../nix/modules/home/laptop.nix ];
  personal.environment = "linux";
  personal.desktop.enable = true;
  # Matches plasma in system.yml.
  personal.desktop.plasma = true;
  personal.eda.enable = true;
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
  # Citrix Workspace (the citrix role in system.yml) opens downloaded .ica launch files, not the
  # text editors that also accept them.
  xdg.mimeApps.defaultApplications."application/x-ica" = "wfica.desktop";
  # Replaces Ubuntu's wfica.desktop: files opened from Chrome inherit the Nix Chrome wrapper's
  # LD_LIBRARY_PATH, which makes wfica load Nix libraries built against a newer glibc and exit.
  xdg.desktopEntries.wfica = {
    name = "Citrix Workspace Engine";
    exec = "env -u LD_LIBRARY_PATH /opt/Citrix/ICAClient/wfica -icaroot /opt/Citrix/ICAClient %f";
    icon = "/opt/Citrix/ICAClient/icons/receiver.png";
    mimeType = [ "application/x-ica" ];
    noDisplay = true;
    settings.StartupWMClass = "Wfica";
  };
  personal.virtualization.enable = pkgs.stdenv.hostPlatform.isx86_64;
  personal.virtualization.passthroughAudio = [ "0000:01:00.1" ];
  # Ubuntu daemon packages include these clients; do not install parallel copies.
  personal.clients.docker = false;
  personal.clients.tailscale = false;
  personal.clients.taildrop = true;
}
