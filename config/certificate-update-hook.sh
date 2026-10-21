#!/bin/sh
set -eu
python3 /usr/local/libexec/spawnkit/certificate-policy.py \
  --policy /etc/ssl/spawnkit-certificate-denylist.json \
  --bundle /etc/ssl/certs/ca-certificates.crt
if command -v keytool >/dev/null 2>&1 && [ -f /etc/ssl/certs/java/cacerts ]; then
  python3 /usr/local/libexec/spawnkit/certificate-policy.py \
    --policy /etc/ssl/spawnkit-certificate-denylist.json \
    --java-store /etc/ssl/certs/java/cacerts --apply
fi
