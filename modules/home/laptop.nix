{ pkgs, ... }: {
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
  home.packages = with pkgs; [
    google-cloud-sdk
    docker-client
    cloudflared
    tailscale
    cmake
    ninja
    poppler-utils
    ffmpeg
    imagemagick
    exiftool
    pandoc
  ];
}
