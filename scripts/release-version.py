#!/usr/bin/env python3
"""Print the app version used in release asset names (without build number)."""
import os
from pathlib import Path
import re
import sys

repo = Path(__file__).resolve().parents[1]
match = re.search(r'^version:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+[^\s]+)?\s*$',
                  (repo / 'pubspec.yaml').read_text(), re.MULTILINE)
if not match:
    sys.exit('No valid app version found in pubspec.yaml')
version = match.group(1)
if os.environ.get('GITHUB_REF_TYPE') == 'tag':
    if os.environ.get('GITHUB_REF_NAME') != 'v' + version:
        sys.exit('Release tag does not match the app version in pubspec.yaml')
print(version)
