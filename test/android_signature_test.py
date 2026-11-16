"""Regression checks for real apksigner 36/37 output and fail-closed behavior."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('android_signature', REPO / 'scripts/verify-android-signature.py')
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
EXPECTED = (REPO / 'android/release-certificate.sha256').read_text().strip()
OTHER = '0' * 64


class SignatureTests(unittest.TestCase):
    def test_real_build_tools_outputs(self):
        # Captured from the published v1.0.8 APK with Google's official tools.
        for version in (36, 37):
            with self.subTest(version=version):
                output = (REPO / f'test/fixtures/android-signature/build-tools-{version}.txt').read_text()
                signer.verify_certificates(output, EXPECTED)

    def test_multiple_schemes_with_same_key(self):
        signer.verify_certificates(
            f'V3.1 Signer: (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: {EXPECTED}\n'
            f'V3.0 Signer: (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: {EXPECTED.upper()}\n', EXPECTED)

    def test_old_sdk_range_label(self):
        signer.verify_certificates(f'Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: {EXPECTED}', EXPECTED)

    def test_different_key_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Actual: ' + OTHER):
            signer.verify_certificates(f'V2 Signer: certificate SHA-256 digest: {OTHER}', EXPECTED)

    def test_extra_signer_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Do not distribute'):
            signer.verify_certificates(
                f'V2 Signer #1 certificate SHA-256 digest: {EXPECTED}\n'
                f'V2 Signer #2 certificate SHA-256 digest: {OTHER}', EXPECTED)

    def test_missing_signer_rejected(self):
        for output in ('', f'Signer #1 public key SHA-256 digest: {EXPECTED}',
                       f'Source Stamp Signer certificate SHA-256 digest: {EXPECTED}'):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, 'No APK signer'):
                signer.verify_certificates(output, EXPECTED)

    def test_malformed_fingerprint_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unrecognized'):
            signer.verify_certificates(f'V2 Signer: certificate SHA-256 digest: {EXPECTED}00', EXPECTED)

    def test_invalid_expected_fingerprint_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Invalid fixed'):
            signer.verify_certificates('', 'abc')

    def test_source_stamp_is_not_app_signer(self):
        signer.verify_certificates(
            f'V2 Signer: certificate SHA-256 digest: {EXPECTED}\n'
            f'Source Stamp Signer certificate SHA-256 digest: {OTHER}', EXPECTED)

    def test_failed_integrity_verification_cannot_pass_matching_certificate(self):
        result = subprocess.CompletedProcess([], 1,
            f'V2 Signer: certificate SHA-256 digest: {EXPECTED}\n', 'DOES NOT VERIFY\n')
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(signer.subprocess, 'run', return_value=result) as run, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            with self.assertRaisesRegex(ValueError, 'signature verification failed'):
                signer.verify_apk('apksigner', 'test.apk', EXPECTED)
        self.assertEqual(run.call_args.args[0], ['apksigner', 'verify', '--print-certs', 'test.apk'])
        self.assertIn(EXPECTED, output.getvalue())
        self.assertIn('DOES NOT VERIFY', errors.getvalue())


if __name__ == '__main__':
    unittest.main()
