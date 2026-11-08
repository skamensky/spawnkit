{
  config,
  lib,
  pkgs,
  ...
}:
let
  repo = "${config.home.homeDirectory}/repos/skamensky/personal-agent-customizations";
  link = path: config.lib.file.mkOutOfStoreSymlink "${repo}/${path}";
  spawnkit = "${config.home.homeDirectory}/repos/skamensky/spawnkit";
  # Claude Code in the Spawnkit checkout in agent mode, in a new tmux window of the first
  # existing tmux session (or a new "spawnkit" session), then shows that window: inside tmux
  # by switching to it, elsewhere by attaching this terminal. The brief is the personal
  # `spawnkit` skill, which any session also loads on its own for machine changes; agent
  # mode only pins it for the whole session. Arguments pass through to claude.
  spawnkitAgent = pkgs.writeShellApplication {
    name = "spawnkit-agent";
    runtimeInputs = [ config.programs.tmux.package ];
    text = ''
      # The tmux server keeps the environment it started with, so name claude by its path.
      cmd=("$(command -v claude)" --name Spawnkit --add-dir ${lib.escapeShellArg repo}
        --permission-mode bypassPermissions
        --append-system-prompt "Spawnkit agent mode. Every request in this session is a change to, or a question about, Shmuel's machines: load the spawnkit skill before anything else and follow it for the whole session." "$@")
      dir=${lib.escapeShellArg spawnkit}
      session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | head -n 1 || true)
      if [ -n "$session" ]; then
        window=$(tmux new-window -P -F '#{window_id}' -t "$session:" -n Spawnkit -c "$dir" -- "''${cmd[@]}")
      else
        session=spawnkit
        window=$(tmux new-session -d -P -F '#{window_id}' -s "$session" -n Spawnkit -c "$dir" -- "''${cmd[@]}")
      fi
      if [ -n "''${TMUX:-}" ]; then
        exec tmux switch-client -t "$window"
      fi
      exec tmux attach-session -t "$session"
    '';
  };
in
{
  home.packages = [ spawnkitAgent ];
  xdg.desktopEntries = lib.mkIf config.personal.desktop.enable {
    spawnkit-agent = {
      name = "Spawnkit Agent";
      genericName = "Machine configuration assistant";
      comment = "Claude, briefed to change this machine through Spawnkit, in a tmux window";
      exec = "spawnkit-agent";
      terminal = true;
      icon = "${./plasma-start-icon.svg}";
      categories = [
        "Utility"
        "Settings"
      ];
      settings.Keywords = "spawnkit;agent;claude;machine;system;config;install;settings;";
    };
  };
  home.file = {
    ".claude/CLAUDE.md".source = link "AGENTS.md";
    ".codex/AGENTS.md".source = link "AGENTS.md";
    ".claude/settings.json".source = link "config/claude/settings.json";
    ".codex/config.toml".source = link "config/codex/config.toml";
    ".codex/RTK.md".source = link "config/codex/RTK.md";
  };
  # Discover names at activation rather than importing private checkout contents
  # into the Nix store or maintaining a duplicate inventory in this repository.
  home.activation.linkAssistantSkills = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${pkgs.python3}/bin/python3 ${../../../scripts/link-assistant-skills.py} \
      --source ${lib.escapeShellArg "${repo}/skills"} \
      --home ${lib.escapeShellArg config.home.homeDirectory}
  '';
}
