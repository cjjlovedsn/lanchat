#!/usr/bin/env python3
"""Verify APK integrity and the fixed release certificate using Android tools."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys

repo = Path(__file__).resolve().parents[1]
apk = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / 'build/app/outputs/flutter-apk/app-release.apk'
expected = (repo / 'android/release-certificate.sha256').read_text().strip()
tool = shutil.which('apksigner')
if not tool:
    for name in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        root = os.environ.get(name)
        if root:
            candidates = list((Path(root) / 'build-tools').glob('*/apksigner*'))
            candidates = [p for p in candidates if p.name in ('apksigner', 'apksigner.bat')]
            if candidates:
                tool = str(sorted(candidates)[-1])
                break
if not tool:
    sys.exit('Android SDK apksigner not found. Install build-tools before packaging a release.')
result = subprocess.run([tool, 'verify', '--print-certs', str(apk)], capture_output=True, text=True)
if result.returncode:
    sys.exit('APK signature verification failed: ' + result.stderr)
certificates = re.findall(r'Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F]+)', result.stdout)
if [value.lower() for value in certificates] != [expected]:
    sys.exit('APK does not use the fixed LanChat release certificate. Do not distribute it.')
print('Verified APK signature and fixed release certificate SHA256: ' + expected)
