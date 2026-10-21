# Security policy: use the maintained system CA bundle instead of stale runtime
# roots. Preserve existing Node options; never turn certificate verification off.
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export DENO_TLS_CA_STORE=system
case " ${NODE_OPTIONS-} " in
    *" --use-openssl-ca "*) ;;
    *) export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--use-openssl-ca" ;;
esac
