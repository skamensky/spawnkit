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
  personal.shell.secrets = {
    GITHUB_TOKEN = "/github/GITHUB_TOKEN";
    FLY_API_TOKEN = "/hosting/FLY_API_TOKEN";
    NAMECHEAP_API_KEY = "/hosting/NAMECHEAP_API_KEY";
    VERCEL_TOKEN = "/hosting/VERCEL_TOKEN";
    JAM_TOKEN = "/jam/JAM_TOKEN";
    TAILSCALE_API_KEY = "/tailscale/TAILSCALE_API_KEY";
    SUPABASE_PERSONAL_DB_PASSWORD = "/supabase/personal_cloud/shell_env/SUPABASE_PERSONAL_DB_PASSWORD";
    LINEAR_API_KEY = "/linear/LINEAR_API_KEY";
    AIRTABLE_API_KEY = "/airtable/AIRTABLE_API_KEY";
    AIRTABLE_WORKSPACE_ID = "/airtable/AIRTABLE_WORKSPACE_ID";
    NOTION_API_KEY = "/notion/NOTION_API_KEY";
  };
  home.sessionVariables.AWS_PROFILE = "slate";
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
