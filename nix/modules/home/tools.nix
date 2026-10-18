{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;
in
{
  options.personal.tools.googleAutomation = lib.mkEnableOption ''
    the google-automation CLI from its project flake. Development uses that
    repository's own dev shell; its binaries reference the Nix store and must not
    be copied into ~/.local/bin
  '';
  config.home.packages =
    with pkgs;
    [
      curl
      jq
      ripgrep
      fd
      bat
      fzf
      btop
      ncdu
      unzip
      zip
      xz
      p7zip
      vim
      shellcheck
      sqlite
      postgresql
      rtk
      openssh
      mosh
      inputs.llm-agents.packages.${system}.claude-code
      inputs.llm-agents.packages.${system}.codex
      inputs.self.packages.${system}.home-config
      inputs.self.packages.${system}.host-config
    ]
    ++
      lib.optional config.personal.tools.googleAutomation
        inputs.google-automation.packages.${system}.default;
}
