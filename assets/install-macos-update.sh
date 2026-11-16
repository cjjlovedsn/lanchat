#!/bin/sh
# Arguments are passed separately by the native updater, never interpolated.
set -eu
old_pid="$1"
staged="$2"
target="$3"
backup="$4"
log="$5"
exec >>"$log" 2>&1
case "$old_pid" in ''|*[!0-9]*) exit 1;; esac
# Never replace a running application. Leave the existing app intact on timeout.
count=0
while kill -0 "$old_pid" 2>/dev/null; do
  count=$((count + 1))
  if [ "$count" -ge 60 ]; then echo 'Timed out waiting for LanChat to quit'; exit 1; fi
  sleep 1
done
if [ ! -d "$staged" ] || [ ! -d "$target" ] || [ -e "$backup" ]; then
  echo 'Invalid update staging paths'; exit 1
fi
if ! mv "$target" "$backup"; then echo 'Cannot move old application'; exit 1; fi
if ! mv "$staged" "$target"; then
  mv "$backup" "$target"
  open "$target"
  exit 1
fi
if ! open "$target"; then
  # Restore the old application if LaunchServices rejects the new bundle.
  mv "$target" "$staged"
  mv "$backup" "$target"
  open "$target"
  exit 1
fi
# The bundle contains no chat data. Keep one backup until the next launch has
# succeeded; the app's updater removes it on a future successful update.
echo 'Update installed; previous bundle retained at:' "$backup"
