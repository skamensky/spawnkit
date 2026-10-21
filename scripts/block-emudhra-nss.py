#!/usr/bin/env python3
"""Explicit NSS distrust for one existing certificate database; no key copying."""
import argparse
import hashlib
import json
from pathlib import Path
import ssl
import subprocess
import tempfile
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--policy', type=Path, required=True)
parser.add_argument('--database', type=Path, required=True)
args = parser.parse_args()
assert (args.database / 'cert9.db').is_file(), 'Existing NSS database required'
policy = json.loads(args.policy.read_text())
expected = {item['sha256'] for item in policy['certificates']}
assert len(expected) == 20
certificates = {}
for filename in ['roots.json', 'impacted-intermediates.json']:
    values = json.load(urllib.request.urlopen('https://emudhra.we-have-a-problem.com/' + filename, timeout=20))
    for item in values:
        der = ssl.PEM_cert_to_DER_cert(item['pem'])
        digest = hashlib.sha256(der).hexdigest().upper()
        assert digest in expected, 'Unreviewed certificate data'
        certificates[digest] = item['pem']
assert set(certificates) == expected, 'Incomplete public certificate data'
database = 'sql:' + str(args.database.resolve())
with tempfile.TemporaryDirectory(prefix='nss-distrust-') as temporary:
    for digest, pem in certificates.items():
        nickname = 'spawnkit-distrust-' + digest
        existing = subprocess.run(['certutil', '-L', '-d', database, '-n', nickname, '-a'], stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if existing.returncode == 0:
            assert hashlib.sha256(ssl.PEM_cert_to_DER_cert(existing.stdout)).hexdigest().upper() == digest
            command = ['certutil', '-M', '-d', database, '-n', nickname, '-t', 'p,p,p']
        else:
            path = Path(temporary)/'certificate.pem'
            path.write_text(pem)
            command = ['certutil', '-A', '-d', database, '-n', nickname, '-t', 'p,p,p', '-i', str(path)]
        subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, check=True)
result = subprocess.run(['certutil', '-L', '-d', database], capture_output=True, text=True, check=True).stdout
verified = [line for line in result.splitlines() if line.startswith('spawnkit-distrust-') and line.rsplit(None,1)[-1] == 'p,p,p']
assert len(verified) == 20
print(json.dumps({'database':str(args.database),'explicitly_distrusted':len(verified)}))
