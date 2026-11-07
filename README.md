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

## DevHub's GUI: `require('devhub').gui`

When DevHub draws your Neovim itself (`[general] editor = "neovim"` in
DevHub's settings; `vim.g.devhub_gui` and `$DEVHUB_NEOVIM_GUI` are set), your
config can put GUI elements into it. Every one is attached to a Neovim object
and follows it — Neovim keeps the layout, the state and the keys.

```lua
local gui = require('devhub').gui

if gui.available() then
  -- A native toast (outside DevHub: vim.notify).
  gui.notify { title = 'Build', msg = 'done in 3.2s', level = 'info' } -- 'warn' | 'error' | vim.log.levels.*

  -- A GUI window: web content in an ordinary Neovim window.
  local w = gui.open { title = 'Outline', html = '<button>…</button>', win = 'vsplit' }
  --                   or url = 'https://…'; win = 'vsplit' | 'split' | 'float' | 'tab' | 'current'
  gui.on_message(w, function(msg) end) -- the page's devhub.send(msg)
  gui.send(w, { kind = 'hello' })       -- the page's devhub.onMessage(fn)
  gui.close(w)

  -- An image under line 5 (1-based) of the current buffer, in 10 rows reserved
  -- with an extmark's virt_lines: it scrolls, folds and moves with them.
  local img = gui.image(0, 5, '~/shots/diagram.png', { height_rows = 10 }) -- or an https URL
  img.clear()
end
```

- **One implementation.** DevHub injects the real module (`devhub_gui`) into
  Neovim at every attach, over the UI's own RPC channel — it owns the other
  end of every message, and it is there on an SSH host too. This module is
  the stable face of it: it forwards when DevHub is attached, waits for the
  attach (`User DevhubGui`) for a call made while Neovim is still starting,
  and does nothing (answers `nil`) outside DevHub — `notify` falls back to
  `vim.notify`. So `gui.*` is safe in a config shared with the terminal.
- **LSP hover and signature help, drawn natively.** In DevHub's GUI, at the
  first `LspAttach`, `vim.lsp.util.open_floating_preview` is wrapped so that
  a markdown float is drawn by DevHub over its window: headings, lists,
  fenced code highlighted, links that open in the browser. The float is still
  Neovim's (`<C-w>w` into it, scroll it, `q`/`<Esc>` close it; DevHub
  follows). Set `vim.g.devhub_rich_floats = false` to keep Neovim's own.
- `:DevhubImageDemo [path]`, `:DevhubGuiDemo` and `:DevhubTerminal [float]`
  come from DevHub. In `:DevhubTerminal`, keys go to the shell (`<C-w>`
  deletes a word); `<C-\><C-n>` leaves for terminal-normal mode as in a
  `:terminal`, and `i`/`a` go back in.

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
