{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Nature photos from Wikimedia Commons' featured pictures, all freely licensed (CC BY, CC BY-SA);
  # each entry credits its author. These are Commons' 3840 px renderings; Commons can re-render
  # one with different bytes, so a hash mismatch means re-pinning that entry, not a bad download.
  photos = lib.imap0 (
    i: photo:
    photo
    // {
      path = pkgs.fetchurl {
        name = "wallpaper-${toString i}.jpg";
        inherit (photo) url hash;
        curlOptsList = [ "--user-agent" "spawnkit-wallpaper/1.0 (personal desktop setup)" ];
      };
    }
  ) (lib.importJSON ./wallpapers.json);
  wallpaperTool = pkgs.writers.writePython3Bin "spawnkit-wallpaper" {
    flakeIgnore = [ "E501" ];
    makeWrapperArgs = [ "--set" "SPAWNKIT_WALLPAPERS" (pkgs.writeText "wallpapers.json" (builtins.toJSON photos)) ];
  } (builtins.readFile ./plasma-wallpaper.py);
  widget = pkgs.runCommand "tech.shmuel.wallpaper" { } ''
    dest=$out/share/plasma/plasmoids/tech.shmuel.wallpaper
    mkdir -p $(dirname $dest)
    cp -r --no-preserve=mode ${./plasma-wallpaper} $dest
    substituteInPlace $dest/contents/ui/main.qml --replace-fail @wallpaper@ ${wallpaperTool}/bin/spawnkit-wallpaper
  '';
in
{
  # A new nature wallpaper every day, with a small desktop button that skips to the next one.
  config = lib.mkIf (config.personal.desktop.enable && config.personal.desktop.plasma) {
    home.packages = [
      wallpaperTool
      widget
    ];
    # Top right of the 2048x1280 (scaled) laptop screen, clear of the bottom panel. plasma-manager's
    # widget script cannot add widgets while the layout is locked (immutability 2 in plasma.nix), and
    # scripts cannot unlock it: to apply a change here, stop plasmashell, set General/immutability=1
    # in plasma-org.kde.plasma.desktop-appletsrc, start it, rerun the script, then set it back to 2.
    programs.plasma.desktop.widgets = [
      {
        name = "tech.shmuel.wallpaper";
        position = {
          horizontal = 1964;
          vertical = 20;
        };
        size = {
          width = 64;
          height = 64;
        };
      }
    ];
    systemd.user.services.spawnkit-wallpaper = {
      Unit = {
        Description = "Daily nature wallpaper";
        After = [ "plasma-plasmashell.service" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${wallpaperTool}/bin/spawnkit-wallpaper daily";
      };
      Install.WantedBy = [ "plasma-workspace.target" ];
    };
    systemd.user.timers.spawnkit-wallpaper = {
      Unit.Description = "Daily nature wallpaper";
      Timer = {
        OnCalendar = "daily";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
