{ ... }: {
  imports = [ ../../nix/modules/home/laptop.nix ];
  personal.environment = "linux";
  personal.desktop.enable = true;
}
