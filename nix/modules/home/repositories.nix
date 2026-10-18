{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.personal.repositories;
  catalog = builtins.fromJSON (builtins.readFile ../../../config/repositories.json);
  manifest = pkgs.writeText "personal-repositories.json" (
    builtins.toJSON (map (name: catalog.${name}) (lib.unique cfg.names))
  );
  # GitHub's published host keys (api.github.com/meta). A fresh host has no
  # known_hosts entry and activation cannot answer the interactive prompt.
  githubKnownHosts = pkgs.writeText "github-known-hosts" ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
    github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
  '';
  bootstrap = pkgs.writeShellApplication {
    name = "spawnkit-repos";
    runtimeInputs = [
      pkgs.python3
      pkgs.git
      pkgs.openssh
    ];
    text = ''
      exec python3 ${../../../scripts/bootstrap-repos.py} ${manifest} --home "$HOME" --known-hosts ${githubKnownHosts} "$@"
    '';
  };
in
{
  options.personal.repositories = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    names = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.hasAttr name catalog) cfg.names;
        message = "Every personal.repositories.names entry must exist in repositories.json.";
      }
    ];
    home.packages = [ bootstrap ];
    # External assistant link targets exist before Home Manager installs links.
    home.activation.bootstrapRepositories =
      lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ]
        ''
          run ${bootstrap}/bin/spawnkit-repos
        '';
  };
}
