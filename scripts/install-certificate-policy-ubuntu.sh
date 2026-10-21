#!/bin/sh
# Targeted incident response only. Does NOT enroll a host in Spawnkit, activate
# Home Manager, restart applications, or apply unrelated host configuration.
set -eu
test "$(id -u)" = 0
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test -f /etc/ca-certificates.conf
command -v update-ca-certificates >/dev/null
if [ ! -f /etc/ca-certificates.conf.before-emudhra-20261021 ]; then
  cp -p /etc/ca-certificates.conf /etc/ca-certificates.conf.before-emudhra-20261021
fi
for name in emSign_ECC_Root_CA_-_G3.crt emSign_Root_TLS_CA_-_G3.crt emSign_Root_CS_CA_-_G3.crt Comodo_AAA_Services_root.crt; do
  sed -i "s|^mozilla/$name\$|!mozilla/$name|" /etc/ca-certificates.conf
  if ! grep -Fqx "!mozilla/$name" /etc/ca-certificates.conf; then
    printf '\n!mozilla/%s\n' "$name" >> /etc/ca-certificates.conf
  fi
done
install -d -m 755 /usr/local/libexec/spawnkit /etc/environment.d
install -m 644 "$repo_dir/config/certificate-denylist.json" /etc/ssl/spawnkit-certificate-denylist.json
install -m 755 "$repo_dir/scripts/certificate-policy.py" /usr/local/libexec/spawnkit/certificate-policy.py
install -m 755 "$repo_dir/config/certificate-update-hook.sh" /etc/ca-certificates/update.d/zz-spawnkit-denylist-audit
install -m 644 "$repo_dir/config/certificate-policy.sh" /etc/profile.d/70-certificate-policy.sh
install -m 644 "$repo_dir/config/certificate-policy.environment.conf" /etc/environment.d/70-certificate-policy.conf
update-ca-certificates --fresh
