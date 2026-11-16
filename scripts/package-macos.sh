#!/bin/bash
set -euo pipefail

source_dir="${1:?Usage: package-macos.sh <staged folder> <output folder> <file basename> <volume name>}"
output_dir="${2:?Missing output folder}"
basename="${3:?Missing file basename}"
volume_name="${4:?Missing volume name}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
apps=("$source_dir"/*.app)
if [[ "${#apps[@]}" -ne 1 || ! -d "${apps[0]}" ]]; then
    echo 'The staged folder must contain exactly one Mac application.' >&2
    exit 1
fi

# Keep the original ZIP format, including bundle symlinks and permissions.
ditto -c -k --sequesterRsrc "$source_dir" "$output_dir/$basename.zip"

dmg_source="$(mktemp -d "${TMPDIR:-/tmp}/macos-dmg.XXXXXX")"
trap 'rm -rf "$dmg_source"' EXIT
ditto "$source_dir" "$dmg_source"
ln -s /Applications "$dmg_source/Applications"
test "$(readlink "$dmg_source/Applications")" = /Applications
hdiutil create -quiet -volname "$volume_name" -srcfolder "$dmg_source" \
    -fs HFS+ -format UDZO -ov "$output_dir/$basename.dmg"
hdiutil verify -quiet "$output_dir/$basename.dmg"

python3 - "$output_dir" "$basename" <<'PY'
import hashlib
import sys
import zipfile
from pathlib import Path

output, name = Path(sys.argv[1]), sys.argv[2]
with zipfile.ZipFile(output / f'{name}.zip') as bundle:
    assert bundle.testzip() is None, 'ZIP archive verification failed'
sums = []
for suffix in ('dmg', 'zip'):
    path = output / f'{name}.{suffix}'
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    sums.append(f'{digest}  {path.name}\n')
    print(f'Packaged: {path}')
(output / 'SHA256SUMS.txt').write_text(''.join(sums))
PY
