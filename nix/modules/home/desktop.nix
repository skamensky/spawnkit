{
  config,
  lib,
  pkgs,
  isNixOS ? false,
  ...
}:
let
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
      description = "Graphical session type; selects the clipboard tools.";
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
        vscode
        copyq
        (if config.personal.desktop.session == "x11" then xclip else wl-clipboard)
        # Common web and document fonts, so pages that name Verdana, Arial,
        # Calibri and the like render as designed instead of a fallback.
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
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
        # Linux Chrome lists the Vulkan adapters but hands WebGPU none without this.
        (google-chrome.override { commandLineArgs = "--enable-features=Vulkan"; })
      ];
    # Lets fontconfig find the Home Manager profile's fonts on Ubuntu.
    fonts.fontconfig.enable = true;
    # Dark mode; GTK3 apps ignore color-scheme and need Ubuntu's dark Yaru theme.
    dconf.settings."org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "Yaru-dark";
    };
    # English and Hebrew keyboard layouts; GNOME switches with Super+Space.
    dconf.settings."org/gnome/desktop/input-sources".sources = [
      (lib.hm.gvariant.mkTuple [ "xkb" "us" ])
      (lib.hm.gvariant.mkTuple [ "xkb" "il" ])
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
    programs.obs-studio.enable = true;
    # Flameshot replaces GNOME's screenshot tool on Print (X11 session).
    services.flameshot.enable = true;
    dconf.settings."org/gnome/shell/keybindings".show-screenshot-ui = [ ];
    dconf.settings."org/gnome/settings-daemon/plugins/media-keys".custom-keybindings = [
      "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/flameshot/"
      "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/copyq/"
    ];
    # Ditto's shortcut. While Looking Glass holds the keyboard, Windows' CopyQ gets it instead.
    dconf.settings."org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/copyq" = {
      name = "CopyQ";
      command = "${pkgs.copyq}/bin/copyq toggle";
      binding = "<Control>grave";
    };
    dconf.settings."org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/flameshot" = {
      name = "Flameshot";
      # --clipboard: Enter copies the selection and closes; no save dialog.
      command = "${pkgs.flameshot}/bin/flameshot gui --clipboard";
      binding = "Print";
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
      );
    };
    systemd.user.services.copyq = {
      Unit = {
        Description = "CopyQ clipboard history";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.copyq}/bin/copyq";
        Restart = "on-failure";
      }
      // lib.optionalAttrs (config.personal.desktop.copyqShare != null) {
        # CopyQ saves new items after five minutes by default; save them within seconds so a
        # Windows sign-in soon after a copy still loads it.
        ExecStartPost = toString (
          pkgs.writeShellScript "copyq-save-delay" ''
            for _ in $(${pkgs.coreutils}/bin/seq 30); do
              ${pkgs.copyq}/bin/copyq config save_delay_ms_on_item_added 10000 >/dev/null 2>&1 && exit 0
              ${pkgs.coreutils}/bin/sleep 1
            done
            exit 1
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
      Unit.Description = "Publish CopyQ history to the Windows VM share";
      Service = {
        Type = "oneshot";
        Environment = "PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.diffutils pkgs.gnugrep ]}";
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
