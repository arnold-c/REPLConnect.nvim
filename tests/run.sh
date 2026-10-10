#!/usr/bin/env bash
# Run the headless Neovim Lua tests.
#
#   tests/run.sh                 run every tests/*.lua
#   tests/run.sh tests/vars.lua  run only the given files
#
# Each file runs in its own `nvim --headless -u NONE -l` process from the
# repository root; a file passes if nvim exits with status 0. Exits non-zero if
# any file fails.

set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

if ! command -v nvim >/dev/null 2>&1; then
  echo "nvim not found on PATH" >&2
  exit 127
fi

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=(tests/*.lua)
fi

failed=()
for file in "${files[@]}"; do
  echo "== $file"
  if nvim --headless -u NONE -l "$file"; then
    echo "-- ok"
  else
    status=$?
    echo "-- FAILED (exit $status)" >&2
    failed+=("$file")
  fi
done

echo
if [ "${#failed[@]}" -eq 0 ]; then
  echo "all ${#files[@]} test file(s) passed"
else
  echo "${#failed[@]} of ${#files[@]} test file(s) failed:" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
