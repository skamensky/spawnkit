{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.personal.clients = {
    gcloud = lib.mkEnableOption "Google Cloud CLI";
    docker = lib.mkEnableOption "Docker client only (daemon stays with host automation)";
    tailscale = lib.mkEnableOption "Tailscale client (omit when Ubuntu provides it)";
    taildrop = lib.mkEnableOption ''
      moving files sent over Taildrop into ~/Downloads/Tailscale as they arrive (needs the
      host's Tailscale operator set to this user)
    '';
  };
  config.home.packages =
    lib.optional config.personal.clients.gcloud pkgs.google-cloud-sdk
    ++ lib.optional config.personal.clients.docker pkgs.docker-client
    ++ lib.optional config.personal.clients.tailscale pkgs.tailscale;

  config.systemd.user.services.taildrop-receive = lib.mkIf config.personal.clients.taildrop (
    let
      # Ubuntu's package provides the CLI when the Nix client is omitted.
      tailscale =
        if config.personal.clients.tailscale then "${pkgs.tailscale}/bin/tailscale" else "/usr/bin/tailscale";
    in
    {
      Unit.Description = "Move received Taildrop files into ~/Downloads/Tailscale";
      Service = {
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/Downloads/Tailscale";
        ExecStart = "${tailscale} file get --loop --conflict=rename %h/Downloads/Tailscale";
        # Fails until tailscaled is up and the operator is set; keep retrying.
        Restart = "always";
        RestartSec = 30;
      };
      Install.WantedBy = [ "default.target" ];
    }
  );
}
