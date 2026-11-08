#!/bin/sh
# Rewrite the theme fixtures from DevHub's own generator: theme.json exactly as
# DevHub publishes it (model/publishedTheme.ts) for a built-in theme.
#   tests/fixtures/regenerate.sh <DevHub checkout>
# with esbuild from its apps/desktop/node_modules, or $ESBUILD.
set -eu
devhub=$(cd "$1" && pwd)
desktop=$devhub/apps/desktop
fixtures=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat >"$work/gen.ts" <<TS
import { writeFileSync } from "node:fs";
import { builtinThemes, terminalPaletteOfTheme } from "$desktop/src/model/themes/theme.ts";
import { publishedThemeOf, themeFileText } from "$desktop/src/model/publishedTheme.ts";
for (const [file, name] of [["nord", "Nord"], ["light", "DevHub Light"]]) {
  const theme = builtinThemes().find((each) => each.name === name);
  if (!theme) throw new Error("no built-in theme " + name);
  const terminal = terminalPaletteOfTheme(theme);
  writeFileSync("$fixtures/" + file + ".json", themeFileText(publishedThemeOf({ theme, terminal, temporary: false })));
}
TS
"${ESBUILD:-$desktop/node_modules/.bin/esbuild}" "$work/gen.ts" --bundle --platform=node --format=esm \
  --outfile="$work/gen.mjs" --log-level=warning
node "$work/gen.mjs"
