# devhub.nvim

Neovim in the colour theme [DevHub](https://github.com/statiolake/devhub)
wears — from the very first frame, and following every change.

DevHub publishes the VS Code colour theme it wears to the programs in its
terminals: a JSON file (`$DEVHUB_THEME_FILE`, by default
`~/.local/state/devhub/theme.json`), a few `DEVHUB_*` variables in every new
pane, and, for the Neovim DevHub manages, a `User DevhubTheme` event with the
same object. This plugin is a colorscheme made from that object: the terminal
palette, the editor's colours as VS Code resolves them, and the syntax colours
from the theme's `tokenColors`.

## No flicker

`plugin/devhub.lua` reads the file **synchronously** while Neovim loads its
plugins and, when no colorscheme has been chosen yet, applies it there — so no
frame is ever drawn in the default (or any other) colorscheme first. A live
change, whether it arrives as `User DevhubTheme` over RPC or as the file being
replaced, goes through the same `:colorscheme devhub`, the same function and
the same value, so the colours after a switch are identical to the ones at
startup.

## Install

With lazy.nvim:

```lua
{
  'statiolake/devhub.nvim',
  lazy = false,
  priority = 1000,
  config = function()
    local devhub = require 'devhub'
    if devhub.inside() then
      devhub.setup {}          -- :colorscheme devhub, and follow changes
    else
      vim.cmd.colorscheme 'nord' -- whatever you wear outside DevHub
    end
  end,
}
```

`setup()` does nothing outside DevHub, so it is safe to call everywhere.

## What it sets

- every highlight a colorscheme usually does: the editor (`Normal`,
  `CursorLine`, `LineNr`, `StatusLine`, `Pmenu`, `Visual`, `Search`, diffs, …);
- syntax groups, Tree-sitter captures (`@keyword`, `@function.call`,
  `@variable.member`, … and the pre-2024 names), LSP semantic tokens
  (`@lsp.type.*`) and references, diagnostics, gitsigns, Telescope and
  fzf-lua basics;
- `g:terminal_color_0` … `g:terminal_color_15`, and `background`.

Syntax colours come from the theme's `tokenColors` for the scopes DevHub
publishes; where a theme says nothing about one, the terminal palette fills in.
On a remote host, where there is no file, the palette in
`$DEVHUB_THEME_COLORS` is used.

## Options

```lua
require('devhub').setup {
  auto = true,     -- wear the theme at startup when no colorscheme is chosen
  follow = true,   -- follow User DevhubTheme and changes to the file
  on_apply = function(theme) end, -- your tweaks, after every apply
}
```

`vim.g.devhub_auto = false` (before the plugin loads) keeps `plugin/` from
applying anything; `:colorscheme devhub` is then yours to run.
`require('devhub').fzf_colors()` is the theme's `fzf --color=` value, for
fzf-lua's `fzf_opts`.

## Tests

```sh
tests/run.sh   # nvim --headless: startup highlights match the theme file
               # before any event; a live switch and back is identical; a
               # replaced file is followed; setup() outside DevHub is a no-op
```

Neovim 0.9 or later.
