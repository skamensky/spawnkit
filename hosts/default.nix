{ lib, hostProfile, ... }: {
  imports = [ ../modules/home ];
  personal.profile = hostProfile;
  personal.desktop.enable = lib.mkDefault false;
}
