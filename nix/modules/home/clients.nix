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
  };
  config.home.packages =
    lib.optional config.personal.clients.gcloud pkgs.google-cloud-sdk
    ++ lib.optional config.personal.clients.docker pkgs.docker-client
    ++ lib.optional config.personal.clients.tailscale pkgs.tailscale;
}
