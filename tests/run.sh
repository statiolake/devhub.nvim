#!/bin/sh
# Run the headless tests: nvim must be on PATH (or $NVIM).
set -eu
cd "$(dirname "$0")/.."
NVIM="${NVIM:-nvim}"
for theme in nord light; do
  other=light
  [ "$theme" = light ] && other=nord
  echo "startup in $theme:"
  DEVHUB_THEME_FILE="$PWD/tests/fixtures/$theme.json" \
  DEVHUB_TEST_OTHER="$PWD/tests/fixtures/$other.json" \
    "$NVIM" --headless --clean \
      --cmd "set rtp^=$PWD" \
      --cmd "luafile tests/record.lua" \
      -c "autocmd VimEnter * ++once ++nested luafile tests/check.lua" </dev/null
done
