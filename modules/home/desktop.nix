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
        solaar
        wl-clipboard
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [ google-chrome ];
    xdg.mimeApps.enable = true;
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
