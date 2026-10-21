{ ... }:
{
  # Host trust belongs to Ubuntu/Ansible or NixOS. User clients should consume
  # that maintained bundle rather than stale language-runtime snapshots.
  home.sessionVariables = {
    SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
    CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
    NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    DENO_TLS_CA_STORE = "system";
    NODE_OPTIONS = "--use-openssl-ca";
  };
}
