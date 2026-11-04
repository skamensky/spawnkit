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
      # B7 ignores the pointer after Alt+Tab until it leaves and re-enters the window.
      (pkgs.looking-glass-client.overrideAttrs (old: {
        patches = old.patches or [ ] ++ [ ./looking-glass-enter-on-ungrab.patch ];
      }))
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
        name = "Windows";
        exec = "host-config vm-view --notify --gui";
        icon = "${./spawnkit-windows.svg}";
        terminal = false;
        categories = [ "System" ];
        # Groups the viewer's window under this launcher in the dock.
        settings.StartupWMClass = "looking-glass-client";
      };
      spawnkit-windows-console = {
        name = "Windows installation console";
        exec = "host-config vm-console --notify";
        icon = "utilities-terminal";
        terminal = false;
        categories = [ "System" ];
      };
    };
    # Pin the Windows launcher to the dock without replacing the user's own pins.
    home.activation.pinWindowsLauncher = lib.hm.dag.entryAfter [ "dconfSettings" ] ''
      # gsettings, unlike dconf, also reports GNOME's default pins; without the dconf
      # module it would read and write a private keyfile instead.
      export GIO_EXTRA_MODULES=${pkgs.dconf.lib}/lib/gio/modules
      gsettings=${pkgs.glib.bin}/bin/gsettings
      if [ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ] &&
          favorites=$($gsettings get org.gnome.shell favorite-apps 2>/dev/null); then
        case "$favorites" in
          *"'spawnkit-windows.desktop'"*) ;;
          "@as []") run $gsettings set org.gnome.shell favorite-apps "['spawnkit-windows.desktop']" ;;
          *) run $gsettings set org.gnome.shell favorite-apps "''${favorites%]}, 'spawnkit-windows.desktop']" ;;
        esac
      fi
    '';
  };
}
