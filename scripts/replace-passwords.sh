#!/usr/bin/env bash
set -euo pipefail

for file in *.sh; do
  [[ "$file" == "replace-passwords.sh" ]] && continue

  echo "Processing $file"

  cp -n "$file" "$file.bak"

  sed -i -E \
    -e 's/^([[:space:]]*[A-Za-z0-9_]*PASS[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)".*"(.*)$/\1"changeme"\2/I' \
    -e "s/^([[:space:]]*[A-Za-z0-9_]*PASS[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)'.*'(.*)$/\1'changeme'\2/I" \
    -e 's/^([[:space:]]*[A-Za-z0-9_]*PASSWORD[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)".*"(.*)$/\1"changeme"\2/I' \
    -e "s/^([[:space:]]*[A-Za-z0-9_]*PASSWORD[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)'.*'(.*)$/\1'changeme'\2/I" \
    "$file"
done

echo
echo "Done. Backups created as *.bak"
echo "Check remaining password-like lines with:"
echo "grep -RiE 'pass|password|passwd|secret|token' *.sh"
