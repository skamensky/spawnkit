# Certificate distrust policy

## October 2026 eMudhra incident

Eight compromised intermediate keys were represented by sixteen certificates,
including cross-signatures under Sectigo's AAA Certificate Services root.
Blocking only emSign ECC Root CA - G3 is insufficient. The reviewed public
manifest in `config/certificate-denylist.json` includes those sixteen certificates
and four related roots: twenty certificate SHA-256 fingerprints and twelve
unique public-key (SPKI) SHA-256 fingerprints. It contains no private keys.

Sources:

- https://emudhra.we-have-a-problem.com/
- https://emudhra.we-have-a-problem.com/impacted-intermediates.json
- https://emudhra.we-have-a-problem.com/roots.json
- https://blog.cloudflare.com/emudhra-certificate-compromise/

The downloader scripts accept only certificate bytes matching the reviewed
manifest. Review any upstream changes before updating that manifest. Do not
disable TLS verification, trust an incident test certificate, or restore the
pre-remediation backups as a routine rollback.

## Ownership and application

Ubuntu system trust belongs to the Ansible `certificate_policy` role. It updates
`ca-certificates`, explicitly disables the affected root paths, installs the
fingerprint/SPKI auditor, and audits generated bundles after CA updates. It also
removes matching entries from Java's shared store, which may retain roots after
an OS bundle update. Normal package updates are still required.

Home Manager's `certificate-policy.nix` directs newly started user clients to
the maintained system bundle. Node uses `--use-openssl-ca`; Deno uses `system`.
NixOS exports the corresponding root blacklist through `nixosModules.default`.
These settings do not change existing processes or applications that explicitly
select independent trust stores. The NixOS declaration is composition/build
checked, not a claim of live NixOS remediation.

On an Ubuntu host **not enrolled in Spawnkit**, an authorized emergency repair
can run `sudo bash scripts/install-certificate-policy-ubuntu.sh` from this
checkout. It does not enroll the host, activate Home Manager, restart services,
or change the Spawnkit sentinel. Its profile/environment files are for unmanaged
hosts; an eventual managed migration must remove that temporary ownership.
On enrolled hosts, use the Ansible role and Home Manager instead.

For an explicitly selected additional PEM bundle or shared Java store:

```sh
python3 scripts/certificate-policy.py --policy config/certificate-denylist.json \
  --bundle /exact/path/to/cacert.pem
python3 scripts/certificate-policy.py --policy config/certificate-denylist.json \
  --bundle /exact/path/to/cacert.pem --apply
python3 scripts/certificate-policy.py --policy config/certificate-denylist.json \
  --java-store /etc/ssl/certs/java/cacerts --apply
```

The filter refuses private-key inputs and an empty resulting bundle, preserves
unrelated certificates, and retains one adjacent pre-incident backup. The Java
adapter is for the public default-password truststore, not private key stores.
Do not mutate `/nix/store`; rebuild affected dependencies instead. Python
virtualenv or cache regeneration may reintroduce old certifi data: update the
dependency or direct the client to the maintained OS store, and re-audit it.

## Windows and NSS

Windows uses explicit distrust, not merely removal from the root store:

```powershell
# Elevated PowerShell is required for all local-machine users/services.
.\scripts\block-emudhra-windows.ps1 -Scope LocalMachine `
  -PolicyPath .\config\certificate-denylist.json
# Without elevation this covers only the current Windows user.
.\scripts\block-emudhra-windows.ps1 -Scope CurrentUser `
  -PolicyPath .\config\certificate-denylist.json
```

An existing, explicitly selected NSS database can be protected independently:

```sh
python3 scripts/block-emudhra-nss.py --policy config/certificate-denylist.json \
  --database "$HOME/.pki/nssdb"
```

It imports all twenty public certificates with `p,p,p` prohibited trust for TLS,
email, and signing. It does not copy private-key databases or invent a browser
profile. NSS-using applications may need restarting. Other browser profiles,
Windows Java/Node bundles, and custom application stores need their own audit.

## Android, iPad, containers, and offline hosts

Updating Termux `ca-certificates` updates **Termux only**, not Android's system
or application-specific trust. `config/certificate-policy-termux.sh` can be
installed in `$PREFIX/etc/profile.d/` for new Termux login shells. Android's
system trust requires supported vendor updates or a deliberate trusted-CA
settings change on the device. Verify actual rejection rather than assuming a
package update or browser revocation covers every Android app. iPadOS likewise
requires supported Apple/browser updates and device-side verification.

Containers, statically linked Rust applications, private Java stores, immutable
Nix dependencies and embedded CA bundles must be rebuilt or audited separately.
Environment variables are not an enforced global deny mechanism. Running clients
may cache trust: arrange targeted restarts instead of silently terminating owner
sessions. Offline hosts and stopped VMs remain outstanding until brought online
with owner authorization; do not boot expensive build VMs merely to claim fleet
coverage. Do not mutate shared tailnet peers without confirming ownership.

## Acceptance

Run `tests/test_certificate_policy.py`, Home Manager check/build for affected
profiles, and host-config's Ansible syntax check before publishing changes.
Test both a direct G3 chain and the AAA cross-signed path, plus a normal HTTPS
control, with each actual client/store combination. A connection error alone is
not sufficient: require a certificate-validation rejection and a successful
control. Store presence, a successful config build, or patched curl alone does
not prove all browsers, applications, running processes, or machines protected.
