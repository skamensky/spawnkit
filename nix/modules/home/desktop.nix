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
  };
  config = lib.mkIf config.personal.desktop.enable {
    home.packages =
      with pkgs;
      [
        firefox
        vscode
        copyq
        (if config.personal.desktop.session == "x11" then xclip else wl-clipboard)
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
        # Linux Chrome lists the Vulkan adapters but hands WebGPU none without this.
        (google-chrome.override { commandLineArgs = "--enable-features=Vulkan"; })
      ];
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
    # Flameshot replaces GNOME's screenshot tool on Print (X11 session).
    services.flameshot.enable = true;
    dconf.settings."org/gnome/shell/keybindings".show-screenshot-ui = [ ];
    dconf.settings."org/gnome/settings-daemon/plugins/media-keys".custom-keybindings = [
      "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/flameshot/"
    ];
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
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
    targets.genericLinux.gpu.nvidia = lib.mkIf (!isNixOS && config.personal.desktop.nvidia != null) {
      enable = true;
      inherit (config.personal.desktop.nvidia) version sha256;
    };
  };
}
