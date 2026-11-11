{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.personal.claudeSessions;
  # One line per project: its name, then its checkout.
  projects = pkgs.writeText "claude-sessions-projects" (
    lib.concatStrings (
      lib.mapAttrsToList (name: path: "${name} ${config.home.homeDirectory}/repos/${path}\n") cfg.projects
    )
  );
  # Each declared project whose checkout exists gets two windows in the detached tmux
  # session `claude`: Claude with permissions bypassed, and a Remote Control server
  # (`claude remote-control`). The server registers this machine as a device in
  # claude.ai/code and the mobile app, so new sessions in the project can be started
  # from there; `claude --remote-control` would only expose one existing session. A login shell runs
  # each, so claude sees the same PATH and credentials as a terminal; when claude exits
  # the window keeps a shell. `start` adds only missing windows, so it is safe to rerun.
  claudeSessions = pkgs.writeShellApplication {
    name = "claude-sessions";
    runtimeInputs = [ config.programs.tmux.package ];
    text = ''
      session=claude
      window() { # name dir command
        if tmux has-session -t "=$session" 2>/dev/null; then
          tmux list-windows -t "=$session" -F '#{window_name}' | grep -qxF -- "$1" && return
          tmux new-window -d -t "=$session:" -n "$1" -c "$2" -- bash -lic "$3; exec bash -li"
        else
          tmux new-session -d -s "$session" -n "$1" -c "$2" -- bash -lic "$3; exec bash -li"
        fi
        echo "started $session:$1"
      }
      case "''${1:-}" in
        start)
          while read -r name dir; do
            if [ ! -d "$dir" ]; then
              echo "skipped $name: no checkout at $dir"
              continue
            fi
            window "$name" "$dir" "claude --dangerously-skip-permissions --name $name"
            window "$name-rc" "$dir" "claude remote-control --permission-mode bypassPermissions --name $name"
          done < ${projects}
          ;;
        stop)
          tmux kill-session -t "=$session" 2>/dev/null || true
          ;;
        list)
          tmux list-windows -t "=$session" -F '#{window_name} #{pane_current_path} #{pane_current_command}' 2>/dev/null || true
          ;;
        *)
          echo "usage: claude-sessions start|stop|list (attach with: tmux attach -t $session)" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.personal.claudeSessions.projects = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {
      spawnkit = "skamensky/spawnkit";
      supa-crm = "SkylineCapital/supa-crm";
    };
    description = "Projects (name to path under ~/repos) that get background Claude sessions at login.";
  };
  config = lib.mkIf (cfg.projects != { }) {
    home.packages = [ claudeSessions ];
    systemd.user.services.claude-sessions = {
      Unit = {
        Description = "Background Claude sessions (tmux session claude) for declared projects";
        # A switch must not kill running Claude conversations; changes apply at next login
        # or with `systemctl --user restart claude-sessions`.
        X-RestartIfChanged = false;
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe claudeSessions} start";
        ExecStop = "${lib.getExe claudeSessions} stop";
        # The tmux server may start in this unit; leave it (and any other tmux sessions it
        # serves) running, and stop only the `claude` session.
        KillMode = "process";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
