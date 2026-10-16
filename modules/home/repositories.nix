{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.personal.repositories;
  catalog = builtins.fromJSON (builtins.readFile ../../repositories.json);
  manifest = pkgs.writeText "personal-repositories.json" (
    builtins.toJSON (map (name: catalog.${name}) (lib.unique cfg.names))
  );
  bootstrap = pkgs.writeShellApplication {
    name = "nix-config-repos";
    runtimeInputs = [
      pkgs.python3
      pkgs.git
      pkgs.openssh
    ];
    text = ''
      exec python3 ${../../scripts/bootstrap-repos.py} ${manifest} --home "$HOME" "$@"
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
          run ${bootstrap}/bin/nix-config-repos
        '';
  };
}
