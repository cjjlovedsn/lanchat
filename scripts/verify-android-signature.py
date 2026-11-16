#!/usr/bin/env python3
"""Verify APK integrity and the fixed release certificate using Android tools."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys


def verify_certificates(output, expected):
    if not re.fullmatch(r'[0-9a-fA-F]{64}', expected):
        raise ValueError('Invalid fixed release certificate SHA-256 fingerprint.')
    certificates = []
    for line in output.splitlines():
        if ' certificate SHA-256 digest:' not in line:
            continue
        label, digest = line.split(' certificate SHA-256 digest:', 1)
        # A source stamp identifies the distributor, not the APK signing key.
        if label == 'Source Stamp Signer':
            continue
        # Build Tools <=36: Signer #1; >=37: V2 Signer: / V3.0 Signer:.
        # SDK-range labels may repeat the same certificate across schemes.
        if 'Signer' not in label or not re.fullmatch(r'[0-9a-fA-F]{64}', digest.strip()):
            raise ValueError('Unrecognized APK certificate output: ' + line)
        certificates.append(digest.strip().lower())
    if not certificates:
        raise ValueError('No APK signer SHA-256 fingerprint found in apksigner output.')
    if set(certificates) != {expected.lower()}:
        raise ValueError(
            'APK does not use only the fixed LanChat release certificate. Do not distribute it.\n'
            + 'Expected: ' + expected.lower() + '\nActual: ' + ', '.join(sorted(set(certificates)))
        )


def find_apksigner():
    tool = shutil.which('apksigner')
    if tool:
        return tool
    for name in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        root = os.environ.get(name)
        if root:
            candidates = list((Path(root) / 'build-tools').glob('*/apksigner*'))
            candidates = [p for p in candidates if p.name in ('apksigner', 'apksigner.bat')]
            if candidates:
                return str(sorted(candidates)[-1])
    raise ValueError('Android SDK apksigner not found. Install build-tools before packaging a release.')


def verify_apk(tool, apk, expected):
    print('Verifying APK with: ' + str(tool), flush=True)
    result = subprocess.run([tool, 'verify', '--print-certs', str(apk)], capture_output=True, text=True)
    # Certificate fingerprints and tool errors are public diagnostics, not key passwords.
    if result.stdout:
        print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr)
    if result.returncode:
        raise ValueError('APK signature verification failed (exit ' + str(result.returncode) + ').')
    verify_certificates(result.stdout, expected)
    print('Verified APK signature and fixed release certificate SHA256: ' + expected)


def main():
    repo = Path(__file__).resolve().parents[1]
    apk = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / 'build/app/outputs/flutter-apk/app-release.apk'
    expected = (repo / 'android/release-certificate.sha256').read_text().strip()
    try:
        verify_apk(find_apksigner(), apk, expected)
    except (ValueError, OSError) as error:
        sys.exit(str(error))


if __name__ == '__main__':
    main()
