{
  config,
  inputs,
  lib,
  pkgs,
  isNixOS ? false,
  ...
}:
let
  plasmaQt = pkgs.callPackage ./plasma-qt.nix { };
  copyq = plasmaQt pkgs.copyq;
  quietAttentionUuid = "quiet-window-attention@spawnkit";
  # GNOME's WindowAttentionHandler binds its display signals in its constructor,
  # so disconnect them while enabled and reconnect the stock handler on disable.
  quietAttentionExtension = pkgs.linkFarm quietAttentionUuid {
    "metadata.json" = pkgs.writeText "metadata.json" (
      builtins.toJSON {
        uuid = quietAttentionUuid;
        name = "Quiet window attention";
        description = "Hide the 'window is ready' notifications.";
        shell-version = [
          "46"
          "47"
          "48"
        ];
      }
    );
    "extension.js" = pkgs.writeText "extension.js" ''
      import * as Main from 'resource:///org/gnome/shell/ui/main.js';
      import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

      export default class QuietWindowAttention extends Extension {
          enable() {
              global.display.disconnectObject(Main.windowAttentionHandler);
          }

          disable() {
              const handler = Main.windowAttentionHandler;
              global.display.connectObject(
                  'window-demands-attention', handler._onWindowDemandsAttention.bind(handler),
                  'window-marked-urgent', handler._onWindowDemandsAttention.bind(handler),
                  handler);
          }
      }
    '';
  };
  # After each clipboard change that holds an image, CopyQ copies the image again so that it owns
  # the clipboard.
  copyqKeepImages = pkgs.writeText "copyq-keep-images.js" ''
    var spawnkitClipboardChanged = onClipboardChanged
    onClipboardChanged = function() {
      spawnkitClipboardChanged()
      var image = data("image/png")
      if (image.length) copy("image/png", image)
    }
  '';
  # Enter on several selected items. CopyQ merges only their text, so selected screenshots left
  # the clipboard empty; one clipboard holds one image, so the images go out as a list of files
  # (as a file manager copies them), which browsers and Electron apps paste as one attachment each.
  # Writes each image once, named by its hash, under ~/.cache/copyq/paste.
  copyqPasteSelected = pkgs.writeText "copyq-paste-selected.js" ''
    var newline = String.fromCharCode(10)
    var dir = str(env('HOME')) + '/.cache/copyq/paste'
    var items = selectedItemsData()
    var images = [], uris = [], texts = []
    for (var i = 0; i < items.length; ++i) {
      var item = items[i]
      var png = item['image/png']
      if (png && png.length) {
        var path = dir + '/' + str(execute('${pkgs.coreutils}/bin/sha256sum', null, png).stdout).split(' ')[0] + '.png'
        if (!new File(path).exists()) {
          new Dir(dir).mkpath('.')
          var file = new File(path)
          file.openWriteOnly()
          file.write(png)
          file.close()
        }
        images.push('file://' + encodeURI(path))
      } else {
        if (item['text/uri-list']) uris = uris.concat(str(item['text/uri-list']).split(/\r?\n/).filter(Boolean))
        if (item['text/plain']) texts.push(str(item['text/plain']))
      }
    }
    if (images.length) {
      uris = images.concat(uris)
      copy({
        'text/uri-list': uris.join(String.fromCharCode(13, 10)) + String.fromCharCode(13, 10),
        'x-special/gnome-copied-files': ['copy'].concat(uris).join(newline),
        'application/x-copyq-hidden': '1',
      })
    } else {
      var merged = {'text/plain': texts.join(newline)}
      if (uris.length) merged['text/uri-list'] = uris.join(String.fromCharCode(13, 10))
      copy(merged)
    }
  '';
  # Installs Spawnkit's CopyQ commands at every start, replacing earlier copies by name. An item
  # command bound to Enter is CopyQ's activation action while it is enabled. Its filter enables it
  # only when the selection data holds the item list, which CopyQ adds only for several items, so
  # a single item still activates natively. (An input format cannot do this: CopyQ treats the
  # item list input as always present.)
  copyqCommands = pkgs.writeText "copyq-commands.js" ''
    function read(path) {
      var file = new File(path)
      file.openReadOnly()
      var text = str(file.readAll())
      file.close()
      return text
    }
    var spawnkit = [
      {name: 'Keep copied images after their app exits', isScript: true, cmd: read('${copyqKeepImages}')},
      {
        name: 'Paste selected items together',
        inMenu: true,
        hideWindow: true,
        matchCmd: 'copyq: if (dataFormats().indexOf("application/x-copyq-item") < 0) fail()',
        shortcuts: ['Return', 'Enter'],
        cmd: 'copyq:' + read('${copyqPasteSelected}'),
      },
    ]
    var names = spawnkit.map(function(c) { return c.name })
    setCommands(commands().filter(function(c) { return names.indexOf(c.name) < 0 }).concat(spawnkit))
  '';
  onlyoffice =
    inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.onlyoffice-desktopeditors.override
      { extraFontPackages = documentFonts; };
  # Common web and document fonts, so pages and documents that name Verdana, Arial,
  # Calibri and the like render as designed instead of a fallback.
  documentFonts = with pkgs; [
    corefonts
    vista-fonts
    liberation_ttf
    dejavu_fonts
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    culmus
    roboto
    open-sans
    lato
    inter
    source-sans
    source-serif
    source-code-pro
    ibm-plex
    fira-code
    jetbrains-mono
    ubuntu-classic
    ubuntu-sans
    ubuntu-sans-mono
    # Hack is KDE's default fixed-width font: without it terminals fall back to a
    # proportional font and space letters far apart.
    hack-font
    cascadia-code
    liberation-sans-narrow
    montserrat
    poppins
    raleway
    merriweather
    crimson-pro
    eb-garamond
    font-awesome
    nerd-fonts.symbols-only
  ];
in
{
  options.personal.desktop = {
    enable = lib.mkEnableOption "laptop GUI applications and host graphics integration";
    # Match the host's GDM pin (desktop_session in hosts/<profile>/system.yml).
    session = lib.mkOption {
      type = lib.types.enum [
        "wayland"
        "x11"
      ];
      default = "wayland";
      description = "Graphical session type; selects the clipboard tools and how CopyQ reaches the clipboard.";
    };
    nvidia = lib.mkOption {
      default = null;
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            version = lib.mkOption { type = lib.types.str; };
            sha256 = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      description = "Exact Ubuntu NVIDIA driver version and upstream installer hash; fill on native Ubuntu.";
    };
    copyqShare = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Directory that receives CopyQ's tabs whenever CopyQ saves them, for the Windows VM's CopyQ to load at sign-in.";
    };
  };
  config = lib.mkIf config.personal.desktop.enable {
    home.packages =
      with pkgs;
      [
        firefox
        # Its nixpkgs wrapper already adds dconf's GIO module. Vulkan is on for WebGPU, like
        # Chrome; nixpkgs leaves it off by default because it can break VA-API video decoding.
        (brave.override { enableVulkan = true; })
        (plasmaQt (
          callPackage ./ladybird-rtx.nix {
            ladybird = callPackage ./ladybird.nix { src = inputs.ladybird; };
          }
        ))
        vscode
        copyq
        (if config.personal.desktop.session == "x11" then xclip else wl-clipboard)
      ]
      ++ documentFonts
      ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
        # Linux Chrome lists the Vulkan adapters but hands WebGPU none without this.
        # Without dconf its Nix GTK reads default settings, whose title bar has only a close button.
        ((google-chrome.override { commandLineArgs = "--enable-features=Vulkan"; }).overrideAttrs (old: {
          installPhase = old.installPhase + ''
            wrapProgram $out/bin/google-chrome-stable --prefix GIO_EXTRA_MODULES : ${dconf.lib}/lib/gio/modules
          '';
        }))
        zoom-us
        # Office documents open here: closer to Microsoft Office than LibreOffice, and keeps OOXML intact.
        # It bundles its own Qt, so plasma-qt.nix must not wrap it. Version 10 reached
        # nixpkgs-unstable first; take it from nixpkgs once nixos-unstable has 10.0 or later.
        # It reads fonts only from its own sandbox, not fontconfig, so it gets copies of the
        # desktop's fonts; without them Hebrew and other scripts draw as empty boxes.
        onlyoffice
        (pkgs.callPackage ./office-thumbnailer.nix { inherit onlyoffice; })
        (pkgs.callPackage ./document-thumbnailer.nix { })
        # Shell, awk and sed scripts are plain text again: shared-mime-info 2.5 declares them
        # only executables, so Dolphin had no text preview for them and editors were not
        # offered to open them. Home Manager merges this into the profile's MIME database.
        (pkgs.writeTextDir "share/mime/packages/spawnkit-scripts-are-text.xml" ''
          <?xml version="1.0" encoding="UTF-8"?>
          <mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
            <mime-type type="text/x-shellscript"><sub-class-of type="text/plain"/></mime-type>
            <mime-type type="text/x-awk"><sub-class-of type="text/plain"/></mime-type>
            <mime-type type="text/x-sed"><sub-class-of type="text/plain"/></mime-type>
          </mime-info>
        '')
      ];
    # GNOME Shell never notices launchers added to a profile directory that a switch
    # replaces, so link every profile app into ~/.local/share/applications, which stays
    # put and which GNOME and KDE watch. Its unmanaged launchers are left alone.
    xdg.dataFile."applications" = {
      source = pkgs.runCommand "profile-launchers" { } ''
        mkdir $out
        for f in ${config.home.path}/share/applications/*.desktop; do ln -s "$f" $out/; done
      '';
      recursive = true;
    };
    # Lets fontconfig find the Home Manager profile's fonts on Ubuntu.
    fonts.fontconfig.enable = true;
    # Dark mode; GTK3 apps ignore color-scheme and need Ubuntu's dark Yaru theme.
    dconf.settings."org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "Yaru-dark";
    };
    # GNOME likewise never locks or blanks the screen on its own.
    dconf.settings."org/gnome/desktop/screensaver" = {
      lock-enabled = false;
      ubuntu-lock-on-suspend = false;
    };
    dconf.settings."org/gnome/desktop/session".idle-delay = lib.hm.gvariant.mkUint32 0;
    # English and Hebrew keyboard layouts; GNOME switches with Super+Space.
    dconf.settings."org/gnome/desktop/input-sources".sources = [
      (lib.hm.gvariant.mkTuple [
        "xkb"
        "us"
      ])
      (lib.hm.gvariant.mkTuple [
        "xkb"
        "il"
      ])
    ];
    # Suppress GNOME's '"<window>" is ready' banners (window-demands-attention);
    # the dock still highlights the app.
    xdg.dataFile."gnome-shell/extensions/${quietAttentionUuid}" = {
      source = quietAttentionExtension;
      recursive = true;
    };
    dconf.settings."org/gnome/shell".enabled-extensions = [ quietAttentionUuid ];
    # Encodes through /run/opengl-driver: VA-API on the Intel iGPU, NVENC on the RTX
    # whenever the Windows VM is not holding it.
    # GPU-rendered terminal beside Konsole, which stays the default terminal. Its shell
    # integration (prompt marks, cwd for new tabs) is injected automatically for bash.
    programs.ghostty = {
      enable = true;
      settings.font-family = "Hack";
    };
    programs.obs-studio.enable = true;
    # nixpkgs adds the driver path only to OBS's libraries; its NVENC probe in bin/ (behind the
    # Qt wrapper) needs it too.
    programs.obs-studio.package = plasmaQt (
      pkgs.obs-studio.overrideAttrs (old: {
        postFixup = old.postFixup + ''
          addDriverRunpath $out/bin/.obs-nvenc-test-wrapped
        '';
      })
    );
    # Print opens GNOME's screenshot UI: drag a region, then Enter copies it to the clipboard
    # (and keeps a copy in ~/Pictures/Screenshots); no save dialog.
    dconf.settings."org/gnome/shell/keybindings".show-screenshot-ui = [ "Print" ];
    dconf.settings."org/gnome/settings-daemon/plugins/media-keys".custom-keybindings = [
      "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/copyq/"
    ];
    # Ditto's shortcut. While Looking Glass holds the keyboard, Windows' CopyQ gets it instead.
    dconf.settings."org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/copyq" = {
      name = "CopyQ";
      command = "${copyq}/bin/copyq toggle";
      binding = "<Control>grave";
    };
    xdg.mimeApps = {
      enable = true;
      defaultApplications = lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 (
        lib.genAttrs [
          "text/html"
          "x-scheme-handler/http"
          "x-scheme-handler/https"
          "x-scheme-handler/about"
          "x-scheme-handler/unknown"
        ] (_: "google-chrome.desktop")
        // lib.genAttrs [
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
          "application/vnd.openxmlformats-officedocument.spreadsheetml.template"
          "application/vnd.ms-excel"
          "application/vnd.ms-excel.sheet.macroEnabled.12"
          "application/vnd.ms-excel.sheet.binary.macroEnabled.12"
          "application/vnd.oasis.opendocument.spreadsheet"
          "text/csv"
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
          "application/vnd.openxmlformats-officedocument.wordprocessingml.template"
          "application/msword"
          "application/vnd.ms-word.document.macroEnabled.12"
          "application/vnd.oasis.opendocument.text"
          "application/rtf"
          "application/vnd.openxmlformats-officedocument.presentationml.presentation"
          "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
          "application/vnd.ms-powerpoint"
          "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
          "application/vnd.oasis.opendocument.presentation"
        ] (_: "onlyoffice-desktopeditors.desktop")
      );
    };
    # WhatsApp Desktop's replacement: web.whatsapp.com in its own Chrome app window. It runs a
    # dedicated Chrome profile (its own login) with DevTools on a loopback port, from which
    # spawnkit-badges reads the unread count for the task manager icon. The entry's name is the
    # window's Wayland app id, so docks group the window with this launcher.
    xdg.desktopEntries."chrome-web.whatsapp.com__-Default" =
      lib.mkIf pkgs.stdenv.hostPlatform.isx86_64
        {
          name = "WhatsApp";
          comment = "WhatsApp Web in its own window";
          exec = "google-chrome --user-data-dir=${config.home.homeDirectory}/.local/share/spawnkit/whatsapp-chrome --remote-debugging-port=9333 --no-first-run --app=https://web.whatsapp.com/";
          icon = "${pkgs.tela-circle-icon-theme}/share/icons/Tela-circle/scalable/apps/whatsapp.svg";
          categories = [
            "Network"
            "InstantMessaging"
          ];
          startupNotify = true;
          settings = {
            Keywords = "WhatsApp;Chat;Messages;";
            StartupWMClass = "chrome-web.whatsapp.com__-Default";
          };
        };
    systemd.user.services.copyq = {
      Unit = {
        Description = "CopyQ clipboard history";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${copyq}/bin/copyq";
        # GNOME's Wayland compositor lets no background app watch the clipboard; through
        # XWayland, which GNOME keeps in sync with it, CopyQ can. KWin offers Wayland's data
        # control protocol instead and syncs XWayland only while an X11 window has focus, so
        # under Plasma CopyQ stays native (else Spectacle's and other Wayland apps' copies
        # never reach it).
        Environment = lib.optional (
          config.personal.desktop.session == "wayland" && !config.personal.desktop.plasma
        ) "QT_QPA_PLATFORM=xcb";
        Restart = "on-failure";
        # Spectacle (and any app that exits right after copying) takes its clipboard with it, as
        # nothing else owns Wayland's clipboard here; CopyQ re-offers a copied image as its own.
        # CopyQ saves new items after five minutes by default; with a Windows share, save them
        # within seconds so a Windows sign-in soon after a copy still loads it.
        ExecStartPost = toString (
          pkgs.writeShellScript "copyq-setup" ''
            ready=
            for _ in $(${pkgs.coreutils}/bin/seq 30); do
              ${copyq}/bin/copyq source ${copyqCommands} >/dev/null 2>&1 && { ready=1; break; }
              ${pkgs.coreutils}/bin/sleep 1
            done
            [ -n "$ready" ] || exit 1
            ${lib.optionalString (
              config.personal.desktop.copyqShare != null
            ) "${copyq}/bin/copyq config save_delay_ms_on_item_added 10000 >/dev/null"}
          ''
        );
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
    # CopyQ replaces a tab file by renaming a new one over it, so watching the directory sees every save.
    systemd.user.paths.copyq-share = lib.mkIf (config.personal.desktop.copyqShare != null) {
      Unit.Description = "Publish CopyQ history to the Windows VM share";
      Path.PathChanged = "%h/.config/copyq";
      Install.WantedBy = [ "default.target" ];
    };
    systemd.user.services.copyq-share = lib.mkIf (config.personal.desktop.copyqShare != null) {
      Unit = {
        Description = "Publish CopyQ history to the Windows VM share";
        # CopyQ writes several files at startup; the default start limit would fail this
        # service and its path unit at every login.
        StartLimitIntervalSec = 0;
      };
      Service = {
        Type = "oneshot";
        Environment = "PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.diffutils
            pkgs.gnugrep
          ]
        }";
        # Each file lands under a temporary name and is renamed, so Windows never reads half a tab.
        ExecStart = toString (
          pkgs.writeShellScript "copyq-share" ''
            set -eu
            src="$HOME/.config/copyq" dest=${lib.escapeShellArg config.personal.desktop.copyqShare}
            mkdir -p "$dest"
            for f in "$src"/copyq_tab_*.dat; do
              cmp -s "$f" "$dest/''${f##*/}" || { cp "$f" "$dest/.tmp"; mv "$dest/.tmp" "$dest/''${f##*/}"; }
            done
            grep -E '^(tabs|maxitems)=' "$src/copyq.conf" > "$dest/.tmp"; mv "$dest/.tmp" "$dest/options.ini"
          ''
        );
      };
    };
    targets.genericLinux.gpu.nvidia = lib.mkIf (!isNixOS && config.personal.desktop.nvidia != null) {
      enable = true;
      inherit (config.personal.desktop.nvidia) version sha256;
    };
  };
}
