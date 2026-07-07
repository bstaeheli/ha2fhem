#!/bin/sh
# Regenerate fhem/controls_ha2fhem.txt from the files under fhem/.
# Run from the repo root after every change to fhem/ files, commit the result.
set -eu
cd "$(dirname "$0")/.."

OUT=fhem/controls_ha2fhem.txt
: > "$OUT"
(cd fhem && find FHEM lib -type f -name '*.pm' | LC_ALL=C sort) | while read -r f; do
    path="fhem/$f"
    size=$(wc -c < "$path" | tr -d ' ')
    ts=$(date -u -r "$path" '+%Y-%m-%d_%H:%M:%S')
    printf 'UPD %s %s %s\n' "$ts" "$size" "$f" >> "$OUT"
done
cat "$OUT"
