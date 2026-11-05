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
    # GPU guard refuse to start the VM, so WirePlumber (0.5, SPA-JSON rules) ignores those cards.
    xdg.configFile."wireplumber/wireplumber.conf.d/51-spawnkit-passthrough-audio.conf" =
      lib.mkIf (config.personal.virtualization.passthroughAudio != [ ])
        {
          text = ''
            monitor.alsa.rules = [
            ${lib.concatMapStrings (address: ''
              {
                matches = [ { device.name = "alsa_card.pci-${
                  lib.replaceStrings [ ":" ] [ "_" ] address
                }" } ]
                actions = { update-props = { device.disabled = true } }
              }
            '') config.personal.virtualization.passthroughAudio}]
          '';
        };
    # Launchers live in ~/.local/share/applications rather than the profile: GNOME
    # Shell never notices launchers added to a profile directory that a switch
    # replaces, so a new one stays out of the dock until the next login.
    xdg.dataFile =
      lib.mapAttrs'
        (
          id: entry:
          lib.nameValuePair "applications/${id}.desktop" {
            source = "${
              pkgs.makeDesktopItem (
                {
                  name = id;
                  terminal = false;
                  categories = [ "System" ];
                }
                // entry
              )
            }/share/applications/${id}.desktop";
          }
        )
        {
          spawnkit-windows = {
            desktopName = "Windows";
            exec = "host-config vm-view --notify --gui";
            icon = "${./spawnkit-windows.svg}";
            # Groups the viewer's window under this launcher in the dock.
            startupWMClass = "looking-glass-client";
            actions.windowed = {
              name = "Open in a window";
              exec = "host-config vm-view --notify --gui --windowed";
            };
          };
          spawnkit-windows-without-rtx = {
            desktopName = "Windows (no RTX)";
            exec = "host-config vm-view --notify --without-rtx";
            icon = "${./spawnkit-windows.svg}";
          };
          spawnkit-windows-shutdown = {
            desktopName = "Shut down Windows";
            exec = "host-config vm-stop --notify";
            icon = "system-shutdown";
          };
          spawnkit-windows-console = {
            desktopName = "Windows installation console";
            exec = "host-config vm-console --notify";
            icon = "utilities-terminal";
          };
        };
    # Pin the Windows launchers to the dock without replacing the user's own pins.
    home.activation.pinWindowsLauncher = lib.hm.dag.entryAfter [ "dconfSettings" ] ''
      # gsettings, unlike dconf, also reports GNOME's default pins; without the dconf
      # module it would read and write a private keyfile instead.
      export GIO_EXTRA_MODULES=${pkgs.dconf.lib}/lib/gio/modules
      gsettings=${pkgs.glib.bin}/bin/gsettings
      if [ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ] &&
          favorites=$($gsettings get org.gnome.shell favorite-apps 2>/dev/null); then
        updated=$favorites
        for launcher in spawnkit-windows.desktop spawnkit-windows-shutdown.desktop; do
          case "$updated" in
            *"'$launcher'"*) ;;
            "@as []") updated="['$launcher']" ;;
            *) updated="''${updated%]}, '$launcher']" ;;
          esac
        done
        if [ "$updated" != "$favorites" ]; then
          run $gsettings set org.gnome.shell favorite-apps "$updated"
        fi
      fi
    '';
  };
}
