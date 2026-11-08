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
echo "gui, components and review-relay:"
"$NVIM" --headless --clean --cmd "set rtp^=$PWD" \
  -c "lua local ok, e = pcall(dofile, 'tests/gui_spec.lua'); if not ok then io.stderr:write('FAIL\n  ' .. tostring(e) .. '\n'); vim.cmd 'cquit 1' end" </dev/null
