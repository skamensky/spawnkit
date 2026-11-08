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
  # Claude Code in the Spawnkit checkout in agent mode: its CLAUDE.md (AGENTS.md) then has it read
  # docs/agent.md. --desktop starts the session headless and hands it to Claude Desktop through
  # claude://resume, which, unlike a claude://code/new folder link, carries no outside folder for
  # Desktop to re-confirm. Otherwise it runs in this terminal and arguments pass through to claude.
  marker = "Spawnkit agent mode.";
  spawnkitAgent = pkgs.writeShellApplication {
    name = "spawnkit-agent";
    runtimeInputs = [
      pkgs.jq
      pkgs.libnotify
      pkgs.xdg-utils
    ];
    text = ''
      cd ${lib.escapeShellArg spawnkit}
      if [ "''${1-}" = --desktop ]; then
        notify-send --app-name "Spawnkit Agent" --icon claude-desktop --expire-time 8000 \
          "Spawnkit Agent" "Starting a session in Claude Desktop" || true
        if ! session=$(claude -p ${lib.escapeShellArg "${marker} Read docs/agent.md now, then reply with only: Ready. What should I change?"} \
          --name Spawnkit --add-dir ${lib.escapeShellArg repo} --output-format json | jq -er .session_id); then
          notify-send --app-name "Spawnkit Agent" --urgency critical "Spawnkit Agent" \
            "Claude could not start the session; run spawnkit-agent --desktop in a terminal to see why"
          exit 1
        fi
        exec xdg-open "claude://resume?session=$session"
      fi
      exec claude --name Spawnkit --add-dir ${lib.escapeShellArg repo} \
        --append-system-prompt ${lib.escapeShellArg marker} "$@"
    '';
  };
in
{
  home.packages = [ spawnkitAgent ];
  xdg.desktopEntries = lib.mkIf config.personal.desktop.enable {
    spawnkit-agent = {
      name = "Spawnkit Agent";
      genericName = "Machine configuration assistant";
      comment = "Claude, briefed to change this machine through Spawnkit";
      exec = "spawnkit-agent --desktop";
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
