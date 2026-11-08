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
  # docs/agent.md. --desktop opens a Claude Desktop session there with the marker in the prompt box;
  # otherwise it runs in this terminal and the remaining arguments pass through to claude.
  marker = "Spawnkit agent mode.";
  spawnkitAgent = pkgs.writeShellApplication {
    name = "spawnkit-agent";
    runtimeInputs = [ pkgs.xdg-utils ];
    text = ''
      if [ "''${1-}" = --desktop ]; then
        exec xdg-open ${lib.escapeShellArg "claude://code/new?folder=${lib.escapeURL spawnkit}&q=${lib.escapeURL "${marker} "}"}
      fi
      cd ${lib.escapeShellArg spawnkit}
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
