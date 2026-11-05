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
      # Looking Glass master (unreleased since B7) plus our fixes, from the fork's
      # spawnkit branch; see docs/windows-vm.md. The Windows host pin must be the
      # bleeding-edge build of the same upstream commit.
      (pkgs.looking-glass-client.overrideAttrs (old: {
        version = "B7-829-cdba29f2-spawnkit";
        src = pkgs.fetchFromGitHub {
          owner = "skamensky";
          repo = "LookingGlass";
          rev = "c174aa9b15bfe4cf4c5c48206583062c47f0212d";
          hash = "sha256-91Y1aJGdbzoDzc0RcrpKKZdJMRiGMGSF01bBTxsbMFg=";
          fetchSubmodules = true;
        };
        # nixpkgs unvendors nanosvg for B7; that patch no longer applies to master.
        patches = [ ];
        postUnpack = ''
          echo B7-829-cdba29f2-spawnkit > source/VERSION
          export sourceRoot="source/client"
        '';
        buildInputs = old.buildInputs ++ [
          pkgs.fuse3
          pkgs.usbredir
          pkgs.libunwind
          pkgs.elfutils
        ];
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
            # The task manager shows only the actions the Windows tag lists for the
            # current state (plasma-badges.py), matched by name.
            actions = {
              windowed = {
                name = "Open in a window";
                exec = "host-config vm-view --notify --gui --windowed";
              };
              without-rtx = {
                name = "Start without the RTX";
                exec = "host-config vm-view --notify --without-rtx";
              };
              pause = {
                name = "Pause";
                exec = "host-config vm-pause --notify";
              };
              resume = {
                name = "Resume";
                exec = "host-config vm-resume --notify";
              };
              restart = {
                name = "Restart";
                exec = "host-config vm-restart --notify";
              };
              shutdown = {
                name = "Shut down";
                exec = "host-config vm-stop --notify";
              };
            };
          };
          spawnkit-windows-without-rtx = {
            desktopName = "Windows (no RTX)";
            exec = "host-config vm-view --notify --without-rtx";
            icon = "${./spawnkit-windows.svg}";
          };
          spawnkit-windows-console = {
            desktopName = "Windows installation console";
            exec = "host-config vm-console --notify";
            icon = "utilities-terminal";
          };
        };
    # Plasma reads launchers (and their right-click actions) from its sycoca cache,
    # which does not notice a launcher symlink retargeted by a switch.
    home.activation.refreshKdeServiceCache = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      if [ -x /usr/bin/kbuildsycoca6 ] && [ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        run /usr/bin/kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
      fi
    '';
    # Pin the Windows launcher to the dock without replacing the user's own pins.
    home.activation.pinWindowsLauncher = lib.hm.dag.entryAfter [ "dconfSettings" ] ''
      # gsettings, unlike dconf, also reports GNOME's default pins; without the dconf
      # module it would read and write a private keyfile instead.
      export GIO_EXTRA_MODULES=${pkgs.dconf.lib}/lib/gio/modules
      gsettings=${pkgs.glib.bin}/bin/gsettings
      if [ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ] &&
          favorites=$($gsettings get org.gnome.shell favorite-apps 2>/dev/null); then
        updated=$favorites
        for launcher in spawnkit-windows.desktop; do
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
