{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  # vinceliuice's Plasma 6 themes, which nixpkgs dropped with Plasma 5. Their installers
  # write to $HOME; run them in the build and keep the data they lay down.
  vinceliuiceKde =
    name: rev: hash:
    pkgs.stdenvNoCC.mkDerivation {
      pname = lib.toLower name;
      version = "0-unstable-${builtins.substring 0 7 rev}";
      src = pkgs.fetchFromGitHub {
        owner = "vinceliuice";
        repo = name;
        inherit rev hash;
      };
      installPhase = ''
        # The installers take the theme name from $name, which stdenv sets to the derivation name.
        unset name
        export HOME=$PWD/home
        patchShebangs install.sh
        ./install.sh
        mkdir -p $out/share
        cp -r $HOME/.local/share/. $out/share/
        cp -r $HOME/.config/Kvantum $out/share/
      '';
    };
  # Plasma 6 finds a global or desktop theme only through metadata.json; these packages still
  # ship Plasma 5's metadata.desktop. Their contents otherwise load unchanged.
  withPlasma6Metadata =
    pkg:
    pkgs.runCommand "${pkg.name}-plasma6" { nativeBuildInputs = [ pkgs.jq ]; } ''
      # Copies, not symlinks: KPackage ignores files that resolve outside the package.
      cp -r --no-preserve=mode ${pkg} $out
      for kind in look-and-feel:Plasma/LookAndFeel desktoptheme:Plasma/Theme; do
        for d in $out/share/plasma/''${kind%%:*}/*/; do
          [ -e $d/metadata.json ] || [ ! -e $d/metadata.desktop ] && continue
          jq -n --arg id "$(basename $d)" --arg name "$(sed -n 's/^Name=//p' $d/metadata.desktop | head -1)" \
            --arg structure "''${kind#*:}" \
            '{KPackageStructure: $structure, "X-Plasma-APIVersion": "2", KPlugin: {Id: $id, Name: $name}}' > $d/metadata.json
        done
      done
    '';
  layan = vinceliuiceKde "Layan-kde" "a0b6a4956022276aee33309b2e07d1d0ef3db30c" "sha256-gy3sHVoCo4q7ihFuLvQEil7t4GdrbcfatOulAy2MZ9U=";
  colloid = vinceliuiceKde "Colloid-kde" "b768904d10ba9fcb95abfb59538eab100b1fed1e" "sha256-CWa6HnMP042jh573/x7WxYyRScN/l+jjCasiaBODljA=";
  orchis = vinceliuiceKde "Orchis-kde" "b2a96919eee40264e79db402b915f926436100ad" "sha256-mO1AVrnXNdg3Rftj0cQWef/RrBgSDy5kaMHagwKywEo=";
  graphite = vinceliuiceKde "Graphite-kde-theme" "5eb5020c327e133ff147cf1f47b5ab2807f11ae3" "sha256-M/5XdWcMQRhFl1Hm8c0S9TKb0EoGTaJAuySl7LRNDos=";

  # Twenty of the most downloaded global themes on store.kde.org that support Plasma 6.
  # kvantum names the Kvantum theme a look-and-feel's Kvantum widget style needs.
  # wallpaper names the theme's wallpaper package; full applies set it.
  theme = id: name: tone: author: lookandfeel: kvantum: wallpaper: description: {
    inherit id name tone author lookandfeel kvantum wallpaper description;
  };
  # The Windows VM start and shut-down launchers, pinned to every task manager.
  windowsPins = [ "applications:spawnkit-windows.desktop" "applications:spawnkit-windows-shutdown.desktop" ];
  catalog = [
    (theme "breeze-dark" "Breeze Dark" "dark" "KDE" "org.kde.breezedark.desktop" null null "Plasma's stock dark theme.")
    (theme "breeze-twilight" "Breeze Twilight" "dark" "KDE" "org.kde.breezetwilight.desktop" null null "Dark panels with light application windows.")
    (theme "sweet" "Sweet" "dark" "EliverLara" "com.github.eliverlara.sweet" "Sweet" null "Deep purple with pink and cyan accents; among the most downloaded.")
    (theme "layan" "Layan" "dark" "vinceliuice" "com.github.vinceliuice.Layan" "LayanDark" "Layan" "Flat dark theme with a soft blue-violet gradient accent.")
    (theme "layan-light" "Layan Light" "light" "vinceliuice" "com.github.vinceliuice.Layan-light" "Layan" "Layan-light" "Layan's light variant.")
    (theme "whitesur-dark" "WhiteSur Dark" "dark" "vinceliuice" "com.github.vinceliuice.WhiteSur-dark" "WhiteSurDark" "WhiteSur-dark" "macOS Big Sur style, dark.")
    (theme "whitesur" "WhiteSur" "light" "vinceliuice" "com.github.vinceliuice.WhiteSur" "WhiteSur" "WhiteSur-light" "macOS Big Sur style, light.")
    (theme "orchis-dark" "Orchis Dark" "dark" "vinceliuice" "com.github.vinceliuice.Orchis-dark" "OrchisDark" "Orchis" "Material-inspired with rounded surfaces.")
    (theme "colloid-dark" "Colloid Dark" "dark" "vinceliuice" "com.github.vinceliuice.Colloid-dark" "ColloidDark" "Colloid-dark" "Clean, low-contrast dark theme.")
    (theme "colloid-nord" "Colloid Nord" "dark" "vinceliuice" "com.github.vinceliuice.Colloid-dark-nord" "ColloidNordDark" "Colloid-dark-nord" "Colloid with the Nord palette.")
    (theme "graphite-dark" "Graphite Dark" "dark" "vinceliuice" "com.github.vinceliuice.Graphite-dark" "GraphiteDark" "Graphite-dark" "Monochrome greys, almost no colour.")
    (theme "nordic" "Nordic" "dark" "EliverLara" "Nordic" "Nordic" "Nordic" "Nord palette, dark blue-grey.")
    (theme "nordic-darker" "Nordic Darker" "dark" "EliverLara" "Nordic-darker" "Nordic-Darker" "Nordic" "Nordic with near-black surfaces.")
    (theme "utterly-nord" "Utterly Nord" "dark" "HimDek" "Utterly-Nord" "Utterly-Nord" "Utterly-Nord" "Nord palette with translucent, rounded panels.")
    (theme "dracula" "Dracula" "dark" "Dracula" "Dracula" "Dracula" null "The Dracula palette: purple, pink and green on charcoal.")
    (theme "catppuccin-mocha" "Catppuccin Mocha" "dark" "Catppuccin" "Catppuccin-Mocha-Mauve" null null "Pastel colours on a dark base.")
    (theme "catppuccin-latte" "Catppuccin Latte" "light" "Catppuccin" "Catppuccin-Latte-Mauve" null null "Catppuccin's light flavour.")
    (theme "qogir-dark" "Qogir Dark" "dark" "vinceliuice" "com.github.vinceliuice.Qogir-dark" "Qogir-dark" "Qogir-dark" "Flat theme with a blue accent.")
    (theme "arc-dark" "Arc Dark" "dark" "varlesh" "com.github.varlesh.arc-dark" "ArcDark" "Arc-Dark" "The classic Arc look with transparent elements.")
    (theme "materia-dark" "Materia Dark" "dark" "varlesh" "com.github.varlesh.materia-dark" "MateriaDark" "Materia-Dark" "Google Material Design, dark.")
  ];
  # Layan Dark with see-through Qt windows and menus; KWin's blur shows the wallpaper through.
  layanGlass = pkgs.runCommand "kvantum-layan-glass" { } ''
    mkdir -p $out/share/Kvantum/LayanGlass
    cp ${layan}/share/Kvantum/Layan/LayanDark.svg $out/share/Kvantum/LayanGlass/LayanGlass.svg
    sed -e 's/^reduce_window_opacity=.*/reduce_window_opacity=15/' -e 's/^reduce_menu_opacity=.*/reduce_menu_opacity=10/' \
      ${layan}/share/Kvantum/Layan/LayanDark.kvconfig > $out/share/Kvantum/LayanGlass/LayanGlass.kvconfig
  '';
  # Windows 11 style cursors, which the Fluent icon theme's source ships prebuilt but nixpkgs
  # does not install.
  fluentCursors = pkgs.runCommand "fluent-cursors" { } ''
    mkdir -p $out/share/icons
    cp -r ${pkgs.fluent-icon-theme.src}/cursors/dist $out/share/icons/Fluent-cursors
    chmod -R u+w $out
    sed -i 's/^Name=.*/Name=Fluent Cursors/' $out/share/icons/Fluent-cursors/index.theme
  '';
  # Reads the Google calendars into a local copy for the panel clock (tech.shmuel.clock).
  calendarSync = pkgs.writers.writePython3Bin "spawnkit-calendar" {
    flakeIgnore = [ "E501" ];
    makeWrapperArgs = [ "--set" "SPAWNKIT_CALENDAR_ACCOUNT" "shmuelkamensky@gmail.com" ];
  } (builtins.readFile ./plasma-calendar.py);
  # Panel widgets: KPackage reads them from share/plasma/plasmoids in the profile.
  plasmoid =
    id: src: substitutions:
    pkgs.runCommand id { } ''
      mkdir -p $out/share/plasma/plasmoids
      cp -r --no-preserve=mode ${src} $out/share/plasma/plasmoids/${id}
      ${lib.concatMapStrings (
        name: "substituteInPlace $out/share/plasma/plasmoids/${id}/contents/ui/main.qml --replace-fail @${name}@ ${substitutions.${name}}\n"
      ) (builtins.attrNames substitutions)}
    '';
  batteryWidget = plasmoid "tech.shmuel.battery" ./plasma-battery { };
  clockWidget = plasmoid "tech.shmuel.clock" ./plasma-clock { calendar = "${calendarSync}/bin/spawnkit-calendar"; };
  plasmaTheme = pkgs.writers.writePython3Bin "spawnkit-plasma-theme" {
    flakeIgnore = [ "E501" ];
    makeWrapperArgs = [
      "--set" "SPAWNKIT_PLASMA_THEMES" (pkgs.writeText "plasma-themes.json" (builtins.toJSON catalog))
      "--set" "SPAWNKIT_PANEL_PINS" (lib.concatStringsSep "," windowsPins)
    ];
  } (builtins.readFile ./plasma-theme.py);
in
{
  imports = [ inputs.plasma-manager.homeModules.plasma-manager ];
  # Plasma itself comes from Ubuntu (plasma in hosts/<profile>/system.yml); this declares
  # its look, panel and settings, and the theme gallery's candidates.
  options.personal.desktop.plasma = lib.mkEnableOption "KDE Plasma 6 settings and themes";
  config = lib.mkIf (config.personal.desktop.enable && config.personal.desktop.plasma) {
    programs.plasma = {
      enable = true;
      # English and Hebrew keyboard layouts; Super+Space switches, as on GNOME.
      input.keyboard = {
        layouts = [
          { layout = "us"; }
          { layout = "il"; }
        ];
        options = [ "grp:win_space_toggle" ];
      };
      # Print selects a region; nothing is taken until Enter, which copies it to the
      # clipboard and closes Spectacle without saving a file.
      spectacle.shortcuts = {
        captureRectangularRegion = "Print";
        launch = [ ];
      };
      # Layan's soft dark palette with see-through windows, and Windows 11's icons and cursors.
      workspace = {
        colorScheme = "Layan";
        theme = "Layan";
        widgetStyle = "kvantum";
        iconTheme = "Fluent-dark";
        cursor = {
          theme = "Fluent-cursors";
          size = 24;
        };
        windowDecorations = {
          library = "org.kde.kwin.aurorae";
          theme = "__aurorae__svg__Layan";
        };
        wallpaper = "${layan}/share/wallpapers/Layan/contents/images/2560x1440.png";
      };
      # The session stays unlocked until an explicit lock or log out: no idle lock and no lock on
      # waking from sleep. Without PowerDevil, Plasma never suspends or ends the session itself.
      kscreenlocker = {
        autoLock = false;
        lockOnResume = false;
        timeout = 0;
      };
      configFile."Kvantum/kvantum.kvconfig".General.theme = "LayanGlass";
      kwin.effects = {
        blur.enable = true;
        translucency.enable = true;
      };
      # One bottom panel, as on Windows. Its right side holds only the battery (while on
      # battery), the clock with Google Calendar, and notifications; without a system tray,
      # applications' tray icons (CopyQ, Claude) have nowhere to appear.
      panels = [
        {
          location = "bottom";
          height = 44;
          opacity = "translucent";
          widgets = [
            "org.kde.plasma.kickoff"
            {
              iconTasks.launchers = [
                "preferred://filemanager"
                "preferred://browser"
              ]
              ++ windowsPins;
            }
            "org.kde.plasma.marginsseparator"
            "tech.shmuel.battery"
            "tech.shmuel.clock"
            "org.kde.plasma.notifications"
          ];
        }
      ];
      # Windows-style snapping: KWin's drag-to-edge halves and corner quarters, KZones' snap
      # layouts while dragging a window to the top, and Windows' Meta+arrow keys.
      configFile.kwinrc = {
        Plugins.kzonesEnabled = true;
        Effect-translucency = {
          Inactive = 92;
          MoveResize = 80;
        };
      };
      shortcuts.kwin = {
        "Window Maximize" = "Meta+Up";
        "Window Minimize" = "Meta+Down";
        "Window Quick Tile Top" = [ ];
        "Window Quick Tile Bottom" = [ ];
      };
      configFile.spectaclerc = {
        General = {
          clipboardGroup = "PostScreenshotCopyImage";
          autoSaveImage = false;
          useReleaseToCapture = false;
        };
        GuiConfig.quitAfterSaveCopyExport = true;
      };
    };
    # Theme trial (migration D7): spawnkit-plasma-theme gallery applies these live; pin the
    # winner here. Their Kvantum themes use Ubuntu's Kvantum, which matches Plasma's Qt.
    home.packages = with pkgs; [
      plasmaTheme
      layan
      colloid
      orchis
      graphite
      whitesur-kde
      (catppuccin-kde.override {
        flavour = [
          "mocha"
          "latte"
        ];
        accents = [ "mauve" ];
      })
      (withPlasma6Metadata nordic)
      (withPlasma6Metadata sweet-nova)
      utterly-nord-plasma
      utterly-round-plasma-style
      dracula-theme
      qogir-kde
      (withPlasma6Metadata arc-kde-theme)
      (withPlasma6Metadata materia-kde-theme)
      # Icon themes the look-and-feels above select.
      papirus-icon-theme
      tela-icon-theme
      tela-circle-icon-theme
      candy-icons
      qogir-icon-theme
      whitesur-icon-theme
      bibata-cursors
      # plasma-manager's layout scripts call qdbus, which Ubuntu's Qt 6 names qdbus6.
      (writeShellScriptBin "qdbus" ''exec /usr/bin/qdbus6 "$@"'')
      # The pinned look and panel.
      layanGlass
      fluent-icon-theme
      fluentCursors
      kdePackages.kzones
      batteryWidget
      clockWidget
      calendarSync
    ];
    systemd.user.services.spawnkit-calendar = {
      Unit.Description = "Copy Google Calendar events for the panel clock";
      Service = {
        Type = "oneshot";
        # The credential wrapper runs gcloud and google-automation from the profile.
        Environment = "PATH=${config.home.profileDirectory}/bin:/usr/bin:/bin";
        ExecStart = "${calendarSync}/bin/spawnkit-calendar sync";
      };
    };
    systemd.user.timers.spawnkit-calendar = {
      Unit.Description = "Copy Google Calendar events for the panel clock every 15 minutes";
      Timer = {
        OnStartupSec = "1min";
        OnUnitActiveSec = "15min";
      };
      Install.WantedBy = [ "timers.target" ];
    };
    # Claude's own launcher (from its Ubuntu package) lists New Chat and new-session actions,
    # which Plasma's search shows as separate results. This user copy has none; Claude leaves a
    # user entry without its X-Claude-Generated marker alone.
    xdg.desktopEntries."com.anthropic.Claude" = {
      name = "Claude";
      genericName = "AI Assistant";
      comment = "Desktop application for Claude.ai";
      exec = "claude-desktop %U";
      icon = "claude-desktop";
      categories = [
        "Utility"
        "Development"
      ];
      mimeType = [
        "x-scheme-handler/claude"
        "application/vnd.anthropic.mcpb"
        "application/vnd.anthropic.skill"
      ];
      startupNotify = true;
      settings = {
        Keywords = "AI;Chat;Assistant;Claude;Code;LLM;";
        StartupWMClass = "com.anthropic.Claude";
        SingleMainWindow = "true";
        TryExec = "claude-desktop";
      };
    };
    xdg.desktopEntries.spawnkit-plasma-theme = {
      name = "Theme Gallery";
      comment = "Preview and apply Plasma global themes";
      exec = "spawnkit-plasma-theme gallery";
      icon = "preferences-desktop-theme-global";
      categories = [ "Settings" ];
      settings.OnlyShowIn = "KDE;";
    };
  };
}
