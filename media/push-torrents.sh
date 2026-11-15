#!/usr/bin/env bash
# Copy .torrent files to the seedbox watch dir, then delete only the ones that were sent.
# Usage: push-torrents [dir]   (default: ~/Downloads)
set -euo pipefail

SRC="${1:-$HOME/Downloads}"
DEST="${PUSH_TORRENTS_DEST:-shell:watch/}"

shopt -s nullglob nocaseglob
cd "$SRC"
files=(*.torrent)

if (( ${#files[@]} == 0 )); then
  echo "No .torrent files in $SRC"
  exit 0
fi

printf 'Sending %d file(s) to %s\n' "${#files[@]}" "$DEST"
printf '  %s\n' "${files[@]}"

# ClearAllForwardings: skip the DynamicForward 1080 in ~/.ssh/config (avoids bind errors if a session is already open).
if scp -q -o ClearAllForwardings=yes -- "${files[@]}" "$DEST"; then
  rm -f -- "${files[@]}"
  echo "Done. Removed local copies."
else
  echo "scp failed; local files kept." >&2
  exit 1
fi
