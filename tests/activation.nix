{ flake, testHome }:
let
  infrastructure = builtins.getFlake flake;
  cfg = infrastructure.homeConfigurations."shmuel@default-x86_64-linux";
in
(cfg.extendModules {
  modules = [
    ({ lib, ... }: {
      home.homeDirectory = lib.mkForce testHome;
      personal.repositories.enable = false;
      systemd.user.startServices = lib.mkForce "suggest";
    })
  ];
}).config.home.activationPackage
