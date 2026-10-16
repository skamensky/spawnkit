{ lib, hostProfile, ... }: {
  imports = [ ../../nix/modules/home ];
  personal.profile = hostProfile;
  personal.desktop.enable = lib.mkDefault false;
}
