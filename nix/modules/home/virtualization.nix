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
        # A resize (Insert+F) can leave B7's cursor scale bogus for one event, and
        # PureSpice then splits a ~2e9 px move into 127 px steps: one 270 MB send
        # whose millions of motion events QEMU queues until it runs out of memory.
        # No real pointer move exceeds a screen, so drop larger ones.
        postPatch = (old.postPatch or "") + ''
          substituteInPlace ../repos/PureSpice/src/channel_inputs.c --replace-fail \
            'const unsigned msgs  = (delta + 126) / 127;' \
            'if (delta > 16384) { PS_LOG_ERROR("Dropping a bogus %u px mouse motion", delta); return true; }
          const unsigned msgs  = (delta + 126) / 127;'
          # The bogus motion's source: a resize that briefly leaves a 0 px output
          # rectangle makes the cursor scale infinite, one move turns the fractional
          # accumulator into NaN, and every later move converts to INT_MIN until a
          # capture toggle resets it (the mouse goes dead in bursts). The client
          # builds with -ffast-math, which folds isfinite() to true, so test the bits.
          substituteInPlace src/core.c --replace-fail \
            'g_cursor.scale.x  = (float)srcW / (float)g_state.dstRect.w;' \
            'if (g_state.dstRect.w > 0 && g_state.dstRect.h > 0) {
          g_cursor.scale.x  = (float)srcW / (float)g_state.dstRect.w;' \
            --replace-fail \
            'g_cursor.scale.y  = (float)srcH / (float)g_state.dstRect.h;' \
            'g_cursor.scale.y  = (float)srcH / (float)g_state.dstRect.h; }'
          substituteInPlace src/util.c --replace-fail \
            'g_cursor.acc.y = modf(ey, &ey);' \
            'g_cursor.acc.y = modf(ey, &ey);
          unsigned long long bx, by; memcpy(&bx, &ex, 8); memcpy(&by, &ey, 8);
          if ((bx & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL || (by & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL) { DEBUG_WARN("Dropping a non-finite mouse motion"); g_cursor.acc.x = g_cursor.acc.y = 0.0; ex = ey = 0.0; }'
          # Leaving full screen (Insert+F), KWin configures 0x0, which xdg-shell
          # means "choose your own size". B7 adopts 0x0 literally: its window has
          # no size, it commits frames unthrottled (~900/s, the black flashing and
          # stall) and the cursor scale goes infinite until a real configure
          # arrives. Use the last windowed size instead, 1024x768 at first.
          substituteInPlace displayservers/Wayland/desktops/xdg/xdg.c --replace-fail \
            'state.width      = width;' \
            'static int32_t floatW = 1024, floatH = 768;
          if (state.floating && state.width > 0 && state.height > 0) { floatW = state.width; floatH = state.height; }
          if (width <= 0 || height <= 0) { DEBUG_INFO("Compositor left the size to us, using %dx%d", floatW, floatH); width = floatW; height = floatH; }
          state.width      = width;'
        '';
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
