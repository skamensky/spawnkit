{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.personal.runtimes.install = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Install declared mise runtimes during activation (network required).";
  };
  config = {
    home.packages = [ pkgs.uv ];
    programs.mise = {
      enable = true;
      enableBashIntegration = true;
      globalConfig = builtins.fromTOML (builtins.readFile ../../../config/runtimes/mise.toml);
    };
    xdg.configFile."uv/uv.toml".text = ''
      python-downloads = "never"
      python-preference = "only-system"
    '';
    xdg.configFile."mise/mise.lock".source = ../../../config/runtimes/mise.lock;
    # Makes selected runtimes discoverable by GUI apps and noninteractive agents.
    # mkBefore keeps the shims ahead of ~/.local/bin regardless of module order,
    # so migrated stray node/python copies cannot shadow the declared runtimes.
    home.sessionPath = lib.mkBefore [ "$HOME/.local/share/mise/shims" ];
    home.sessionVariables.UV_PYTHON = "${config.home.homeDirectory}/.local/share/mise/shims/python";
    home.activation.installRuntimes = lib.mkIf config.personal.runtimes.install (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        run ${pkgs.mise}/bin/mise -C "$HOME" install --yes --locked
      ''
    );
  };
}
