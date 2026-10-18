{ lib, pkgs, ... }: {
  personal.repositories.names = [
    "google-automation"
    "personal-supabase"
    "family-desk"
    "safe-phone"
    "shmutils"
    "pgmeta"
    "photo-search"
    "formql"
    "supa-crm"
  ];
  personal.tools.googleAutomation = true;
  personal.clients = {
    gcloud = lib.mkDefault true;
    docker = lib.mkDefault true;
    tailscale = lib.mkDefault true;
  };
  home.packages = with pkgs; [
    cloudflared
    poppler-utils
    ffmpeg
    imagemagick
    exiftool
    pandoc
  ];
}
