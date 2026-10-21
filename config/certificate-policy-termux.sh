# Termux shell clients only; this does not change Android system/app trust.
export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
export CURL_CA_BUNDLE="$SSL_CERT_FILE"
export DENO_TLS_CA_STORE=system
case " ${NODE_OPTIONS:-} " in
  *' --use-openssl-ca '*) ;;
  *) export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--use-openssl-ca" ;;
esac
