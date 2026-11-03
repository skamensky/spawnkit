{
  config,
  lib,
  pkgs,
  isNixOS ? false,
  ...
}:
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
