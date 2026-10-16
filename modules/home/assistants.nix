{ config, lib, ... }:
let
  repo = "${config.home.homeDirectory}/repos/skamensky/personal-agent-customizations";
  skills = builtins.fromJSON (builtins.readFile ../../assistant-skills.json);
  link = path: config.lib.file.mkOutOfStoreSymlink "${repo}/${path}";
  skillLinks = lib.listToAttrs (
    lib.concatMap (
      skill:
      map
        (assistant: {
          name = ".${assistant}/skills/${skill}";
          value.source = link "skills/${skill}";
        })
        [
          "claude"
          "codex"
        ]
    ) skills
  );
in
{
  home.file = skillLinks // {
    ".claude/CLAUDE.md".source = link "AGENTS.md";
    ".codex/AGENTS.md".source = link "AGENTS.md";
    ".claude/settings.json".source = link "config/claude/settings.json";
    ".codex/config.toml".source = link "config/codex/config.toml";
    # RTK contains instructions only, never credentials or application state.
    ".codex/RTK.md".text = builtins.readFile ../../config/RTK.md;
  };
}
