{ pkgs, ... }: {
  imports = [ ../../nix/modules/home/laptop.nix ];
  personal.environment = "linux";
  personal.desktop.enable = true;
  personal.virtualization.enable = pkgs.stdenv.hostPlatform.isx86_64;
  # Ubuntu daemon packages include these clients; do not install parallel copies.
  personal.clients.docker = false;
  personal.clients.tailscale = false;
}
