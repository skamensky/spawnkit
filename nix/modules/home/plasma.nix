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
  # WhatsApp (desktop.nix) and the Windows VM start and shut-down launchers, pinned to every
  # task manager.
  panelPins = [
    "applications:chrome-web.whatsapp.com__-Default.desktop"
    "applications:spawnkit-windows.desktop"
    "applications:spawnkit-windows-shutdown.desktop"
  ];
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
  # Layan Dark with see-through Qt windows (Dolphin's file view included) and menus; KWin's
  # blur shows the wallpaper through.
  layanGlass = pkgs.runCommand "kvantum-layan-glass" { } ''
    mkdir -p $out/share/Kvantum/LayanGlass
    cp ${layan}/share/Kvantum/Layan/LayanDark.svg $out/share/Kvantum/LayanGlass/LayanGlass.svg
    sed -e 's/^reduce_window_opacity=.*/reduce_window_opacity=30/' -e 's/^reduce_menu_opacity=.*/reduce_menu_opacity=15/' \
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
  # Fluent's dark Windows 11 style icons for folders, devices and actions, with each application's
  # own icon: Fluent's restyled app icons (a flat Chrome, for one) are left out.
  fluentRealApps = pkgs.runCommand "fluent-dark-real-apps" { } ''
    src=${pkgs.fluent-icon-theme}/share/icons/Fluent-dark
    dest=$out/share/icons/Fluent-dark-real-apps
    for dir in $(cd $src && find -L . -mindepth 2 -maxdepth 2 -type d ! -name apps); do
      mkdir -p $dest/$(dirname $dir)
      ln -s $(readlink -f $src/$dir) $dest/$dir
    done
    for dir in $(cd $src && find -L . -mindepth 2 -maxdepth 2 -type d -path './symbolic/apps'); do
      ln -s $(readlink -f $src/$dir) $dest/$dir
    done
    sed -e 's/^Name=.*/Name=Fluent dark (application icons)/' -e 's/^Inherits=.*/Inherits=hicolor,breeze-dark/' \
      $src/index.theme > $dest/index.theme
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
  # Plasma's Start menu (Kickoff) without its Places tab, which it has no option to hide. Kickoff
  # is pure QML compiled into a plugin; this repackages that QML as a plain plasmoid. Pinned to
  # Ubuntu's Plasma (6.6.6): move it with Ubuntu's Plasma, whose private QML modules it imports.
  kickoffWidget =
    let
      id = "tech.shmuel.kickoff";
      plasmaDesktop = pkgs.fetchurl {
        url = "mirror://kde/stable/plasma/6.6.6/plasma-desktop-6.6.6.tar.xz";
        hash = "sha256-268SrI3PihK6PqCXwR5x6Ea+SzZzfvYkIOEc83pPY44=";
      };
    in
    pkgs.runCommand id { nativeBuildInputs = [ pkgs.jq ]; } ''
      tar -xJf ${plasmaDesktop} plasma-desktop-6.6.6/applets/kickoff
      src=plasma-desktop-6.6.6/applets/kickoff
      patch -d $src -p1 < ${./plasma-kickoff.patch}
      dest=$out/share/plasma/plasmoids/${id}
      mkdir -p $dest/contents/ui/code $dest/contents/config
      cp $src/*.qml $dest/contents/ui/
      mv $dest/contents/ui/config.qml $dest/contents/config/
      cp $src/main.xml $dest/contents/config/
      cp $src/code/tools.js $dest/contents/ui/code/
      # The plugin build registers these two as singletons; a plain directory needs a qmldir.
      (
        cd $dest/contents/ui
        for f in *.qml; do
          case $f in
            main.qml) ;;
            KickoffSingleton.qml|ActionMenu.qml) echo "singleton ''${f%.qml} 1.0 $f" ;;
            *) echo "''${f%.qml} 1.0 $f" ;;
          esac
        done
      ) > $dest/contents/ui/qmldir
      jq --arg id ${id} '.KPackageStructure = "Plasma/Applet"
        | .KPlugin |= (with_entries(select(.key | startswith("Name[") | not)) | .Id = $id | .Name = "Start menu")' \
        $src/metadata.json > $dest/metadata.json
    '';
  # Windows' Snap Assist (kwin-snap-assist/contents/ui/main.qml): after a window snaps to half
  # the screen, the other windows are offered for the free half.
  snapAssist = pkgs.runCommand "kwin-snap-assist" { } ''
    mkdir -p $out/share/kwin/scripts
    cp -r ${./kwin-snap-assist} $out/share/kwin/scripts/spawnkitsnapassist
  '';
  # Unread counts on task manager icons for web apps that show them only inside the page
  # (WhatsApp, read through its window's DevTools port).
  appBadges = pkgs.writers.writePython3Bin "spawnkit-badges" {
    libraries = [
      pkgs.python3Packages.dbus-next
      pkgs.python3Packages.websockets
    ];
    # dbus-next reads D-Bus signatures from annotations ("s"), which flake8 takes for names.
    flakeIgnore = [ "E501" "F821" "F722" ];
  } (builtins.readFile ./plasma-badges.py);
  # Application search for the Start menu and KRunner, in place of Plasma's own: apps rank by
  # how their name matches and by which app was launched after typing the same thing.
  appSearch = pkgs.writers.writePython3Bin "spawnkit-search" {
    libraries = [ pkgs.python3Packages.dbus-next ];
    flakeIgnore = [ "E501" "F821" "F722" "W503" ];
  } (builtins.readFile ./plasma-search.py);
  # Hides Places entries and sections (Dolphin's panel and KDE's file dialogs).
  placesTool = pkgs.writers.writePython3Bin "spawnkit-places" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./plasma-places.py);
  batteryWidget = plasmoid "tech.shmuel.battery" ./plasma-battery { };
  languageWidget = plasmoid "tech.shmuel.language" ./plasma-language { };
  # The Start menu's icon: a penguin on a rounded tile in Layan's colours. Fluent's start-here
  # is the Windows logo, which reads as one more window button.
  startIcon = pkgs.runCommand "spawnkit-start-icon" { } ''
    install -Dm644 ${./plasma-start-icon.svg} $out/share/icons/hicolor/scalable/apps/spawnkit-start.svg
  '';
  clockWidget = plasmoid "tech.shmuel.clock" ./plasma-clock { calendar = "${calendarSync}/bin/spawnkit-calendar"; };
  plasmaTheme = pkgs.writers.writePython3Bin "spawnkit-plasma-theme" {
    flakeIgnore = [ "E501" ];
    makeWrapperArgs = [
      "--set" "SPAWNKIT_PLASMA_THEMES" (pkgs.writeText "plasma-themes.json" (builtins.toJSON catalog))
      "--set" "SPAWNKIT_PANEL_PINS" (lib.concatStringsSep "," panelPins)
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
      # English and Hebrew keyboard layouts; Super+Space switches (shortcuts below), as on GNOME.
      input.keyboard.layouts = [
        { layout = "us"; }
        { layout = "il"; }
      ];
      # No XKB switching option: with GNOME's grp:win_space_toggle, Super+Space would switch
      # twice, once in XKB and once through the shortcut below.
      input.keyboard.options = [ ];
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
        iconTheme = "Fluent-dark-real-apps";
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
      # waking from sleep. PowerDevil (brightness keys, power) never suspends on idle either;
      # it still dims and turns off an idle screen.
      kscreenlocker = {
        autoLock = false;
        lockOnResume = false;
        timeout = 0;
      };
      powerdevil = lib.genAttrs [ "AC" "battery" "lowBattery" ] (_: {
        autoSuspend.action = "nothing";
      });
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
            {
              name = "tech.shmuel.kickoff";
              # No power buttons: sleep, restart, shut down and the session actions share
              # one Power menu.
              config.General = {
                icon = "spawnkit-start";
                primaryActions = 1;
                systemFavorites = "";
              };
            }
            # Plasma's icon-only task manager, forked by the plasma_taskmanager host role so
            # that a right click offers only Pin/Unpin and Close.
            {
              name = "tech.shmuel.taskmanager";
              config.General.launchers = [
                "preferred://filemanager"
                "preferred://browser"
              ]
              ++ panelPins;
            }
            "org.kde.plasma.marginsseparator"
            "tech.shmuel.battery"
            # The current layout: a click switches between two, or opens a menu of more.
            "tech.shmuel.language"
            # The paired phone (shown only while connected): battery, texts, ring, send a file.
            "org.kde.kdeconnect"
            "tech.shmuel.clock"
            "org.kde.plasma.notifications"
          ];
        }
      ];
      # Windows-style snapping: KWin's drag-to-edge halves and corner quarters, KZones' snap
      # layouts while dragging a window to the top, and Windows' Meta+arrow keys.
      configFile.kwinrc = {
        Plugins = {
          kzonesEnabled = true;
          spawnkitsnapassistEnabled = true;
        };
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
        # KZones registers its actions in KWin's component and claims Super+Space by default;
        # the layout switcher gets it instead.
        "KZones: Snap all windows" = [ ];
      };
      shortcuts."KDE Keyboard Layout Switcher"."Switch to Next Keyboard Layout" = "Meta+Space";
      # Ditto's shortcut, as on GNOME (desktop.nix): Ctrl+` shows or hides CopyQ's history.
      # KWin matches the typed symbol, not the key, and Hebrew puts ; on the ` key.
      hotkeys.commands.copyq-toggle = {
        name = "CopyQ";
        keys = [
          "Ctrl+`"
          "Ctrl+;"
        ];
        command = "${pkgs.copyq}/bin/copyq toggle";
      };
      # Windows' title bar buttons: the window menu on the left, minimize, maximize and
      # close on the right (Layan's Aurorae theme defaults to macOS' left-hand set).
      kwin.titlebarButtons = {
        left = [ "more-window-actions" ];
        right = [ "minimize" "maximize" "close" ];
      };
      configFile.spectaclerc = {
        General = {
          clipboardGroup = "PostScreenshotCopyImage";
          autoSaveImage = false;
          useReleaseToCapture = false;
        };
        GuiConfig.quitAfterSaveCopyExport = true;
      };
      # GDM unlocks GNOME's keyring at login and it already owns org.freedesktop.secrets; KWallet
      # has no wallet and nothing unlocks it, so every secret request (Chrome's, through the
      # portal) opened a KDE Wallet prompt. KWallet stays off; the portal below uses the keyring.
      configFile.kwalletrc.Wallet = {
        Enabled = false;
        "First Use" = false;
      };
      # Widgets are locked (immutability 2), and locked widgets offer no configure entries, so a
      # task's right-click menu keeps only its own actions (pin, unpin, close). Panels stay
      # declared here; the plasma-manager scripts still apply them.
      configFile."plasma-org.kde.plasma.desktop-appletsrc".General.immutability = 2;
      # Plasma's application runner gives way to spawnkit-search (krunner/dbusplugins below), and
      # search offers no Software Center installs.
      configFile.krunnerrc = {
        Plugins.krunner_servicesEnabled = false;
        Plugins.krunner_appstreamEnabled = false;
        Plugins."tech.shmuel.appsEnabled" = true;
        "Plugins/Favorites".plugins = "tech.shmuel.apps";
      };
      configFile.kdeglobals."KDE Action Restrictions"."plasma/allow_configure_when_locked" = false;
      # Dolphin's right-click menu: Open in New Tab, Create New, Cut, Copy, Copy Location, Rename,
      # Move to Trash, Open Terminal Here and Properties. The Dolphin host role patches out the
      # entries these settings cannot remove (Open Folder With, Paste on items, service menus).
      configFile.dolphinrc.ContextMenu = {
        ShowOpenInNewTab = true;
        ShowOpenInNewWindow = false;
        ShowOpenInSplitView = false;
        ShowAddToPlaces = false;
        ShowDuplicateHere = false;
        ShowCopyLocation = true;
        ShowCopyMoveMenu = false;
        ShowOpenTerminal = true;
        ShowCopyToOtherSplitView = false;
        ShowMoveToOtherSplitView = false;
      };
      # Spectacle announces nothing: no popup for a copied, saved or recorded capture.
      # The groups are named "Event/<id>"; KConfig escapes a "/" in a group name as "\/".
      configFile."spectacle.notifyrc" = lib.genAttrs [
        "Event\\/newScreenshotSaved"
        "Event\\/recordingSaved"
        "Event\\/ocrTextExtracted"
      ] (_: { Action = ""; });
      # No "N notifications were received while Do Not Disturb was active" summary.
      configFile."libnotificationmanager.notifyrc"."Event\\/inhibitionSummary".Action = "";
      # The phone's app notifications never pop up: the KDE Connect tray applet lists them
      # (the phone's current notifications) for a look when wanted. Calls and pairing still pop up.
      configFile."kdeconnect.notifyrc"."Event\\/notification".Action = "";
    };
    # Ubuntu's kde-portals.conf with the Secret portal on GNOME's keyring instead of KWallet.
    xdg.configFile."xdg-desktop-portal/kde-portals.conf".text = lib.generators.toINI { } {
      preferred = {
        default = "kde";
        "org.freedesktop.impl.portal.Settings" = "kde;gtk;";
        "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
      };
    };
    # GTK and Chromium apps draw their own title bars from this layout; Plasma's GTK sync
    # copies it from KWin's buttons, but it starts from whatever GNOME left.
    dconf.settings."org/gnome/desktop/wm/preferences".button-layout = "appmenu:minimize,maximize,close";
    # Theme trial (migration D7): spawnkit-plasma-theme gallery applies these live; pin the
    # winner here. Their Kvantum themes use Ubuntu's Kvantum, which matches Plasma's Qt.
    # Ubuntu's Kvantum reads themes only from ~/.config/Kvantum, ~/.themes and /usr/share, never
    # the profile; link every profile theme there (kvantum.kvconfig beside them stays a plain file).
    xdg.configFile."Kvantum" = {
      source = pkgs.runCommand "kvantum-themes" { } ''
        mkdir $out
        for d in ${config.home.path}/share/Kvantum/*/; do ln -s "$d" $out/; done
      '';
      recursive = true;
    };
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
      fluentRealApps
      fluentCursors
      kdePackages.kzones
      kickoffWidget
      snapAssist
      appBadges
      appSearch
      placesTool
      batteryWidget
      languageWidget
      startIcon
      clockWidget
      calendarSync
    ];
    # KRunner and the Start menu find applications through spawnkit-search, which they reach on
    # D-Bus; Plasma's own application runner is off, and the new one's results lead the list.
    xdg.dataFile."krunner/dbusplugins/spawnkit-search.desktop".text = lib.generators.toINI { } {
      "Desktop Entry" = {
        Type = "Service";
        Name = "Spawnkit applications";
        Comment = "Applications, ranked by what you launch";
        Icon = "applications-all";
        X-KDE-PluginInfo-Name = "tech.shmuel.apps";
        X-KDE-PluginInfo-EnabledByDefault = true;
        X-Plasma-API = "DBus";
        X-Plasma-DBusRunner-Service = "tech.shmuel.apps";
        X-Plasma-DBusRunner-Path = "/runner";
        X-Plasma-Runner-Unique-Results = true;
      };
    };
    # Places without Desktop, Music or the Recent section (recent files and locations, modified
    # today and yesterday); everything else in Places stays as edited in Dolphin.
    home.activation.spawnkitPlaces = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${placesTool}/bin/spawnkit-places hide --section RecentlySaved \
        file://${config.home.homeDirectory}/Desktop file://${config.home.homeDirectory}/Music
    '';
    systemd.user.services.spawnkit-search = {
      Unit = {
        Description = "Application search for the Start menu and KRunner";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "dbus";
        BusName = "tech.shmuel.apps";
        ExecStart = "${appSearch}/bin/spawnkit-search serve";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
    systemd.user.services.spawnkit-badges = {
      Unit = {
        Description = "Unread-count badges on task manager icons";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "dbus";
        BusName = "tech.shmuel.Badges";
        ExecStart = "${appBadges}/bin/spawnkit-badges serve";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
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
