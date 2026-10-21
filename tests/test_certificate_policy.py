import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("certificate_policy", ROOT / "scripts/certificate-policy.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class CertificatePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import subprocess
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        fixtures = []
        for number in range(2):
            certificate = Path(cls.directory.name) / f"fixture-{number}.pem"
            private = Path(cls.directory.name) / f"fixture-{number}.key"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-subj", f"/CN=Certificate policy fixture {number}",
                            "-days", "1", "-keyout", str(private), "-out", str(certificate)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            fixtures.append(certificate.read_bytes())
        cls.first, cls.second = fixtures
        assert cls.first != cls.second
        cls.fingerprint, cls.spki = policy.hashes(cls.first)

    def test_removes_only_denied_certificate(self):
        original = b"# preserved\n" + self.first + self.second
        updated, denied, count = policy.filter_bundle(original, {self.fingerprint}, set())
        self.assertEqual(count, 2)
        self.assertEqual(denied, [self.fingerprint])
        self.assertEqual(updated, b"# preserved\n" + original[len(b"# preserved\n"):].replace(self.first.strip(), b"", 1))

    def test_blocks_matching_public_key(self):
        updated, removed, _ = policy.filter_bundle(self.first + self.second, set(), {self.spki})
        self.assertTrue(removed)
        self.assertIn(self.second.strip(), updated)

    def test_refuses_empty_or_private_bundle(self):
        for bundle in [b"nothing", self.first, self.first + b"-----BEGIN PRIVATE KEY-----"]:
            with self.assertRaises(ValueError):
                policy.filter_bundle(bundle, {self.fingerprint}, set())

    def test_idempotence_and_backup(self):
        data, _, _ = policy.filter_bundle(self.first + self.second, {self.fingerprint}, set())
        again, denied, _ = policy.filter_bundle(data, {self.fingerprint}, set())
        self.assertEqual(data, again)
        self.assertEqual(denied, [])
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "bundle.pem"
            target.write_bytes(self.first + self.second)
            target.chmod(0o640)
            policy.atomic_replace(target, data)
            self.assertEqual(target.stat().st_mode & 0o777, 0o640)
            self.assertEqual(target.with_name(target.name + ".before-emudhra-20261021").read_bytes(), self.first + self.second)


if __name__ == "__main__":
    unittest.main()
