{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.personal.virtualization = {
    enable = lib.mkEnableOption "Windows VM user interface";
    passthroughAudio = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "0000:01:00.1" ];
      description = "PCI addresses of passthrough GPU audio functions WirePlumber must never open.";
    };
  };
  config = lib.mkIf config.personal.virtualization.enable {
    home.packages = [
      pkgs.virt-manager
      pkgs.looking-glass-client
    ];
    # A desktop audio session holding the passthrough GPU's HDMI function makes the
    # GPU guard refuse to start the VM, so WirePlumber ignores those cards.
    xdg.configFile."wireplumber/main.lua.d/51-spawnkit-passthrough-audio.lua" =
      lib.mkIf (config.personal.virtualization.passthroughAudio != [ ])
        {
          text = lib.concatMapStrings (address: ''
            table.insert(alsa_monitor.rules, {
              matches = { { { "device.name", "equals", "alsa_card.pci-${
                lib.replaceStrings [ ":" ] [ "_" ] address
              }" } } },
              apply_properties = { ["device.disabled"] = true },
            })
          '') config.personal.virtualization.passthroughAudio;
        };
    xdg.desktopEntries = {
      spawnkit-windows = {
        name = "Windows (Looking Glass)";
        exec = "host-config vm-view --notify";
        icon = "computer";
        terminal = false;
        categories = [ "System" ];
      };
      spawnkit-windows-console = {
        name = "Windows installation console";
        exec = "host-config vm-console --notify";
        icon = "utilities-terminal";
        terminal = false;
        categories = [ "System" ];
      };
    };
  };
}
