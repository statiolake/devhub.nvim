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
  -- A notification, fidget-like (outside DevHub: vim.notify).
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

## Buffer-backed GUI: components, views, cards, decorations

Neovim keeps the state, the layout and the keys; DevHub only paints. What
DevHub paints is described as **data** — components — not HTML: DevHub draws
them in its own type with your colours (every colour is a highlight group, or
a tone that names one, resolved by Neovim). A click on a node runs its
`on_click` in Neovim. HTML stays the escape hatch (`gui.open`). Outside
DevHub every call below is harmless: a view is just its buffer's text, a card
reserves nothing, the handles do nothing.

### Components: `gui.ui`

```lua
local gui = require('devhub').gui
local ui = gui.ui

ui.card {                                   -- a raised column; accent = a bar on the left
  accent = 'warn',
  ui.hstack {                               -- a row; gap, pad, align, justify, wrap, indent, bg
    ui.avatar('claude', { tone = 'keyword' }),
    ui.text { { 'claude', bold = true }, ' replied ', { '3 min ago', dim = true } }, -- runs
    ui.badge('agent', { tone = 'keyword' }), ui.pill(2, { tone = 'warn' }),
    ui.spacer(),                            -- all the room left (or ui.spacer(8): 8 px)
    ui.icon(0xf09b),                        -- a Nerd Font codepoint, in the grid's font
  },
  ui.md 'Yes — `os.Rename` is atomic, but **without a sync** …', -- the hover renderer
  ui.divider(),
  ui.hstack {
    ui.checkbox('mixed'),                   -- true | false | 'mixed'
    ui.progress(0.56, { label = '5 / 9 reviewed', grow = true }),
    ui.sparkline({ 3, 5, 2, 8 }, { kind = 'bar', tone = 'ok' }),
  },
  ui.chart { { values = { 1, 4, 2, 6 }, tone = 'ok', label = 'passed' } },
  ui.image '~/shots/plot.png',              -- a path, an https or data URL
  ui.hstack { ui.button('Reply', { key = 'r', on_click = reply }), ui.kbd 'q' },
}
```

Text takes `size = 'xs' | 'sm' | 'md' | 'lg'`, `mono`, `bold`, `dim`, `wrap`
(else one line with an ellipsis) and `hl`/`tone`; runs take `hl`/`tone`,
`mono`, `bold`, `italic`, `dim`, `strike`, `underline`. Tones: `info`, `warn`,
`error`, `ok`, `hint`, `muted`, `accent`, `special`, `keyword`, `string`,
`title`, `added`, `changed`, `removed`. Every node takes `on_click`, `grow`
and `tip`. The builders check their arguments; `ui.validate(node)` checks a
tree made by hand.

### `gui.view`: a panel that is a buffer

One buffer line per item — your code writes the lines, so `/`, `5j`, marks
and macros work on them — and DevHub paints each item's component over every
window showing the buffer, as tall as it draws (not bound to cells). The
cursor line is the focused item (a ring in the cursor's colour), kept in
sight; a click moves the cursor there and runs the node's (or the view's)
`on_click`; the wheel scrolls and takes the cursor along. An edit to the
buffer draws it again.

```lua
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Tests', 'ok   parse', 'FAIL render' })
local view = gui.view {
  buf = buf,
  win = 'vsplit',                         -- or a window; nil: wherever the buffer is shown
  items = function(lnum, line)            -- or { [lnum] = component }; nil: the plain line
    if lnum == 1 then return ui.text('Tests', { size = 'lg', bold = true }) end
    local ok = line:match '^ok'
    return ui.hstack { ui.badge(ok and 'ok' or 'FAIL', { tone = ok and 'ok' or 'error' }), ui.text(line:sub(6)) }
  end,
  on_click = function(lnum) end,
  keys = { { 'j/k', 'move' }, { '<CR>', 'open' } }, -- the hint line
}
view:update()                             -- draw again (state the items read changed)
view:close()
```

### `gui.inline`: a card under a line

```lua
local card = gui.inline {
  buf = 0, lnum = 87,                     -- under line 87
  id = 'thread:42',                       -- the same id updates this card
  range = { 84, 87 },                     -- the cursor here marks the card active
  component = ui.card { ui.md '**Waiting for the agent**' },
}
card:update(new_component); card:move(90); card:clear()
gui.inline_focus(card, true)              -- ring it, whatever the cursor says
```

Neovim reserves the rows (`virt_lines`); DevHub measures the card and Neovim
reserves exactly that many (it settles at once: the height depends on the
width only). It follows scrolling, folds and window moves and is clipped by
its window. Its keys are yours: buffer-local keymaps on its lines.

### `gui.decorate`: a dimmed, highlighted or tagged range

```lua
local d = gui.decorate { buf = 0, range = { 23, 31 }, style = 'dim' }  -- 'highlight' | 'tag'
gui.decorate { buf = 0, range = { 32, 36 }, style = 'highlight', hl = 'warn', tag = 'NEW since viewed' }
d:clear()
```

Painted over every window showing the range, diff windows too; the range
follows edits.

### Notifications: `notify = true`

```lua
require('devhub').setup { notify = true }  -- or require('devhub').gui.override_notify()
gui.notify { group = 'build', key = 'job:1', msg = 'compiling', progress = true, percent = 40 }
gui.notify { group = 'build', key = 'job:1', msg = 'compiled', done = true }
```

In DevHub's GUI `vim.notify` becomes DevHub's, drawn as fidget draws: compact
lines at the bottom right above the status line, under their source
(`opts.title`), fading. LSP progress (`LspProgress`, 0.10+) shows as a
spinner, the work's title and its percentage, ticked when done. Outside
DevHub nothing changes.

## review-relay: `:ReviewRelay`

[review-relay](https://github.com/statiolake/review-relay)'s review, inside
Neovim, as a thin adapter: it reads and writes through review-relay's own
commands and endpoints (`review-relay comments list|resolve|unresolve`, a
reply as you, `/ui/files`, reviewed marks) and follows the viewer's event
stream, so a reply from the agent shows at once (and is notified).

- `:ReviewRelay` opens the panel (a `gui.view`): progress, the files with
  their status, reviewed checkboxes and thread counts, Waiting / Answered /
  All, the threads, the overall comment. Keys: `<CR>` open (a file, a
  thread at its line; a directory folds), `<Space>` reviewed, `r` reply,
  `s` resolve / reopen, `f` filter, `R` refresh, `q` close.
- In a file of the review each thread is a card under its last line
  (`gui.inline`): the comments in markdown, who wrote them (you / agent),
  Reply and Resolve; `r` and `s` on the thread's lines do the same (anywhere
  else they are `r` and `s`). A resolved thread folds to one line.
- `:ReviewRelay refresh`, `:ReviewRelay stop`.

A viewer must be running for the workspace (`review-relay main...HEAD`, or
`review-relay --no-window main...HEAD`). Outside DevHub's GUI the panel is the
same buffer as text, the keys work, threads are signs.

```lua
require('devhub.review_relay').setup {
  cmd = 'review-relay', width = 54, reply_with = 'input', -- or 'buffer' (:w sends)
  inline_keys = { reply = 'r', resolve = 's' },           -- false: none
  colors = { agent = 'Function', human = 'DiagnosticInfo', waiting = 'DiagnosticWarn' },
}
```

## Options

```lua
require('devhub').setup {
  auto = true,     -- wear the theme at startup when no colorscheme is chosen
  notify = false,  -- vim.notify drawn by DevHub (in its GUI), with LSP progress
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
               # replaced file is followed; setup() outside DevHub is a no-op;
               # the component builders, the GUI facade over a stand-in for
               # DevHub, and :ReviewRelay against a fake review-relay CLI
```

Neovim 0.9 or later.
