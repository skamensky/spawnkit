{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.personal.virtualization.enable = lib.mkEnableOption "Windows VM user interface";
  config = lib.mkIf config.personal.virtualization.enable {
    home.packages = [
      pkgs.virt-manager
      pkgs.looking-glass-client
    ];
    xdg.desktopEntries = {
      spawnkit-windows = {
        name = "Windows (Looking Glass)";
        exec = "host-config vm-view --notify";
        terminal = false;
        categories = [ "System" ];
      };
      spawnkit-windows-console = {
        name = "Windows installation console";
        exec = "host-config vm-console --notify";
        terminal = false;
        categories = [ "System" ];
      };
    };
  };
}
