{ pkgs, inputs, ... }: {
  home.packages = with pkgs; [
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
    gnumake
    pkg-config
    sqlite
    postgresql
    rtk
    openssh
    mosh
    claude-code
    codex
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.home-config
  ];
}
