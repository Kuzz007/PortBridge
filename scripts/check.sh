#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== bash syntax =="
find . -type f -name '*.sh' -not -path './.git/*' -print0 | while IFS= read -r -d '' file; do
  echo "bash -n $file"
  bash -n "$file"
done

echo
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck --severity=warning
else
  echo "== shellcheck =="
  echo "shellcheck not installed, skipped"
fi

echo
printf '[OK] checks completed\n'
