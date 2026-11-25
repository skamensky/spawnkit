{
  config,
  lib,
  pkgs,
  ...
}:
let
  diskUsage = pkgs.writers.writePython3Bin "spawnkit-disk-usage" {
    flakeIgnore = [ "E501" ];
    # GNU du: Ubuntu's is uutils, and the index depends on du's exact output.
    makeWrapperArgs = [ "--set" "SPAWNKIT_DU" "${pkgs.coreutils}/bin/du" ];
  } (builtins.readFile ./disk-usage.py);
in
{
  # The disk space each directory occupies, kept in an index (~/.cache/spawnkit/disk-usage.db)
  # that the patched Dolphin (ansible/roles/dolphin) shows as folder sizes. Dolphin recomputes
  # the subtree of every folder it opens; the nightly scan covers what is never opened.
  config = lib.mkIf (config.personal.desktop.enable && config.personal.desktop.plasma) {
    home.packages = [ diskUsage ];
    # Folders show the size of their contents, not an item count.
    programs.plasma.configFile.dolphinrc.ContentDisplay.DirectorySizeMode = "ContentSize";
    systemd.user.services.spawnkit-disk-usage = {
      Unit.Description = "Index the disk space every directory occupies";
      Service = {
        Type = "oneshot";
        ExecStart = "${diskUsage}/bin/spawnkit-disk-usage refresh --max-age 0 /";
        # The scan reads the whole filesystem: stay out of the way of interactive work.
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };
    systemd.user.timers.spawnkit-disk-usage = {
      Unit.Description = "Index disk usage daily";
      Timer = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
