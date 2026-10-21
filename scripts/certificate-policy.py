#!/usr/bin/env python3
"""Audit or remove explicitly denied public certificates from PEM CA bundles.

Uses fingerprints and public-key hashes, not subject-name substring matching.
Only paths explicitly supplied by the caller can be modified. No TLS bypasses.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import tempfile

PEM = re.compile(rb"-----BEGIN CERTIFICATE-----\s+.*?-----END CERTIFICATE-----", re.S)


def hashes(pem):
    der = ssl.PEM_cert_to_DER_cert(pem.decode("ascii"))
    fingerprint = hashlib.sha256(der).hexdigest().upper()
    public = subprocess.run(["openssl", "x509", "-pubkey", "-noout"], input=pem,
                            capture_output=True, check=True).stdout
    spki = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"],
                          input=public, capture_output=True, check=True).stdout
    return fingerprint, hashlib.sha256(spki).hexdigest().upper()


def filter_bundle(data, denied, denied_keys, cache=None):
    if b"PRIVATE KEY-----" in data:
        raise ValueError("Refusing a PEM file containing private keys")
    matches = list(PEM.finditer(data))
    if not matches:
        raise ValueError("No PEM certificates found")
    cache = {} if cache is None else cache
    removed = []

    def replace(match):
        pem = match.group()
        digest = hashlib.sha256(pem).digest()
        if digest not in cache:
            cache[digest] = hashes(pem)
        fingerprint, key = cache[digest]
        if fingerprint in denied or key in denied_keys:
            removed.append(fingerprint)
            return b""
        return pem

    updated = PEM.sub(replace, data)
    if not PEM.search(updated):
        raise ValueError("Refusing to empty the entire CA bundle")
    return updated, removed, len(matches)


def atomic_replace(path, data):
    """Preserve the target's mode/owner and a one-time pre-change backup."""
    target = path.resolve(strict=True)
    backup = target.with_name(target.name + ".before-emudhra-20261021")
    if not backup.exists():
        shutil.copy2(target, backup)
    original = target.stat()
    fd, temporary = tempfile.mkstemp(prefix=".certificate-policy-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, original.st_mode & 0o777)
        if os.geteuid() == 0:
            os.chown(temporary, original.st_uid, original.st_gid)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def java_store(path, denied, denied_keys, apply=False):
    command = ["keytool", "-J-Duser.language=en", "-J-Duser.country=US",
               "-keystore", str(path), "-storepass", "changeit"]
    listed = subprocess.run(command + ["-list", "-rfc"], capture_output=True, check=True).stdout
    removed = []
    for section in re.split(rb"(?m)^Alias name: ", listed)[1:]:
        alias = section.splitlines()[0].decode().strip()
        match = PEM.search(section)
        if not match:
            raise ValueError("Java trust entry has no certificate")
        fingerprint, key = hashes(match.group())
        if fingerprint in denied or key in denied_keys:
            removed.append({"alias": alias, "sha256": fingerprint})
    if removed and apply:
        target = path.resolve(strict=True)
        backup = target.with_name(target.name + ".before-emudhra-20261021")
        if not backup.exists():
            shutil.copy2(target, backup)
        for item in removed:
            subprocess.run(command + ["-delete", "-alias", item["alias"]],
                           check=True, capture_output=True)
    return {"java_store": str(path), "denied_certificates": removed,
            "changed": bool(removed and apply)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, action="append", default=[])
    parser.add_argument("--java-store", type=Path, action="append", default=[],
                        help="Public Java truststore using the standard changeit password")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if not args.bundle and not args.java_store:
        parser.error("Supply at least one --bundle or --java-store")
    policy = json.loads(args.policy.read_text())
    denied = {item["sha256"] for item in policy["certificates"]}
    denied_keys = {item["spki_sha256"] for item in policy["certificates"]}
    cache, results = {}, []
    for path in args.bundle:
        updated, removed, count = filter_bundle(path.read_bytes(), denied, denied_keys, cache)
        if removed and args.apply:
            atomic_replace(path, updated)
        results.append({"bundle": str(path), "certificates": count,
                        "denied_certificates": removed, "changed": bool(removed and args.apply)})
    for path in args.java_store:
        results.append(java_store(path, denied, denied_keys, args.apply))
    print(json.dumps({"applied": args.apply, "results": results}, indent=2))
    return 1 if any(r["denied_certificates"] for r in results) and not args.apply else 0


if __name__ == "__main__":
    raise SystemExit(main())
