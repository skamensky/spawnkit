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
    runtimeInputs = [
      config.programs.tmux.package
      pkgs.procps
    ];
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
            window "$name-rc" "$dir" "claude remote-control --spawn same-dir --permission-mode bypassPermissions --name $name"
          done < ${projects}
          ;;
        stop)
          tmux kill-session -t "=$session" 2>/dev/null || true
          # A Remote Control server deregisters its folder as it exits; wait for that, or a
          # restart's new server finds the folder still served and refuses to start.
          for _ in $(seq 30); do
            pgrep -u "$(id -u)" -f '^claude remote-control' >/dev/null || break
            sleep 0.5
          done
          ;;
        ensure-home)
          # The backup: a bypass Claude with Remote Control in ~, in its own tmux session so
          # stopping the project sessions never touches it. The window relaunches claude
          # whenever it exits; the timer recreates the window if tmux itself went away.
          if ! tmux has-session -t "=claude-home" 2>/dev/null; then
            tmux new-session -d -s claude-home -n home -c "$HOME" -- bash -lic \
              'while :; do claude --dangerously-skip-permissions --remote-control home --name home; sleep 5; done'
            echo "started claude-home:home"
          fi
          ;;
        list)
          for s in "$session" claude-home; do
            tmux list-windows -t "=$s" -F "$s:#{window_name} #{pane_current_path} #{pane_current_command}" 2>/dev/null || true
          done
          ;;
        *)
          echo "usage: claude-sessions start|stop|ensure-home|list (attach with: tmux attach -t $session, or -t claude-home)" >&2
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
    # Keep at least one remote session reachable even if everything else is down.
    systemd.user.services.claude-home = {
      Unit.Description = "Ensure the backup Claude Remote Control session in ~ (tmux session claude-home)";
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe claudeSessions} ensure-home";
        # The tmux server may be started here; it must outlive this oneshot.
        KillMode = "process";
      };
    };
    systemd.user.timers.claude-home = {
      Unit.Description = "Check every minute that the backup Claude session is running";
      Timer = {
        OnActiveSec = "0";
        OnUnitActiveSec = "1min";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
