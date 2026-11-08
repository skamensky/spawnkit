{
  config,
  lib,
  pkgs,
  isNixOS ? false,
  ...
}:
{
  imports = [
    ./clients.nix
    ./virtualization.nix
    ./git.nix
    ./shell.nix
    ./certificate-policy.nix
    ./tools.nix
    ./runtimes.nix
    ./repositories.nix
    ./assistants.nix
    ./desktop.nix
    ./plasma.nix
    ./wallpaper.nix
  ];
  options.personal = {
    profile = lib.mkOption { type = lib.types.str; };
    environment = lib.mkOption {
      type = lib.types.enum [
        "linux"
        "wsl"
      ];
      default = "linux";
    };
  };
  config = {
    programs.home-manager.enable = true;
    targets.genericLinux.enable = !isNixOS;
    targets.genericLinux.gpu.enable = !isNixOS && config.personal.desktop.enable;
    xdg.enable = true;
    systemd.user.startServices = "sd-switch";
    nix.package = lib.mkDefault pkgs.nix;
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
}
