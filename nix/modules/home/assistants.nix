{
  config,
  lib,
  pkgs,
  ...
}:
let
  repo = "${config.home.homeDirectory}/repos/skamensky/personal-agent-customizations";
  link = path: config.lib.file.mkOutOfStoreSymlink "${repo}/${path}";
in
{
  home.file = {
    ".claude/CLAUDE.md".source = link "AGENTS.md";
    ".codex/AGENTS.md".source = link "AGENTS.md";
    ".claude/settings.json".source = link "config/claude/settings.json";
    ".codex/config.toml".source = link "config/codex/config.toml";
    # RTK contains instructions only, never credentials or application state.
    ".codex/RTK.md".text = builtins.readFile ../../../config/assistants/RTK.md;
  };
  # Discover names at activation rather than importing private checkout contents
  # into the Nix store or maintaining a duplicate inventory in this repository.
  home.activation.linkAssistantSkills = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${pkgs.python3}/bin/python3 ${../../../scripts/link-assistant-skills.py} \
      --source ${lib.escapeShellArg "${repo}/skills"} \
      --home ${lib.escapeShellArg config.home.homeDirectory}
  '';
}
