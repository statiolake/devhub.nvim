# devhub.nvim

Neovim in the colour theme [DevHub](https://github.com/statiolake/devhub)
wears — from the very first frame, and following every change.

DevHub publishes the theme it wears to the programs in its terminals, with the
Neovim colorscheme it generates from it: a JSON file (`$DEVHUB_THEME_FILE`, by
default `~/.local/state/devhub/theme.json`) and, for the Neovims DevHub draws,
a `User DevhubTheme` event with the same object. This plugin wears that
colorscheme — the object's `neovim` table, the very one DevHub applies to the
Neovims it draws — so a Neovim it does not draw (a plain TUI in one of its
terminals) looks the same, and one it does draw is the same from the first
frame. See DevHub's `docs/themes.md` ("Neovim") for how the table is made.

## No flicker

`plugin/devhub.lua` reads the file **synchronously** while Neovim loads its
plugins and, when no colorscheme has been chosen yet, applies it there — so no
frame is ever drawn in the default (or any other) colorscheme first. A live
change, whether it arrives as `User DevhubTheme` over RPC or as the file being
replaced, goes through the same function and the same value, so the colours
after a switch are identical to the ones at startup.

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

## A theme's own colorscheme

A theme can name a Neovim colorscheme of its own (`neovim.colorscheme` in
`theme.json`: TokyoNight's `tokyonight-night`, a custom theme's
`neovim_colorscheme` in DevHub's settings). Then `background` and the
terminal colours are set from the theme and `:colorscheme <name>` is run; your
`ColorScheme` autocommands run after it as after any. With lazy.nvim the
plugin that has it can be lazy — lazy loads a colorscheme plugin when
`:colorscheme` asks for one of its colorschemes, at startup too:

```lua
{ 'statiolake/min-theme.nvim', lazy = true },
```

Where `:colorscheme` cannot find it, DevHub's generated table is worn (below)
and a notification says once which plugin to install (`neovim.plugin`). A
colorscheme your config chose itself is never painted over; one DevHub put on
(`g:devhub_colorscheme`) follows the theme.

## What it sets

Without a colorscheme of the theme's own: exactly DevHub's table (`neovim` in `theme.json`), applied as a colorscheme
file applies itself: `highlight clear`, `background`, every group in
`neovim.highlights` (the editor, syntax, Tree-sitter, LSP, diagnostics, diffs,
and gitsigns / blink.cmp / snacks / fidget / nvim-tree), and
`g:terminal_color_0` … `15` from `neovim.terminal`; then `g:colors_name` is
`devhub` and the `ColorScheme` event fires, so your `ColorScheme`
autocommands adjust it as they would any other.

There is nothing to wear without the file: on a remote host's panes, which get
only DevHub's `DEVHUB_*` variables, `inside()` is false and `setup()` does
nothing (a Neovim DevHub draws there is still dressed by DevHub itself).

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
  --                   keyboard = 'neovim' (html's default: j/k/<CR>/i over its elements) | 'content'
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
- `:DevhubImageDemo [path]` and `:DevhubGuiDemo` come from DevHub. There
  is no DevHub terminal inside Neovim: the Workspace's terminal is DevHub's
  editor area itself, and Neovim's own `:terminal` is drawn as usual.

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

### `gui.content_namespace`: virtual text that is code

DevHub sets virtual text and virtual lines in its UI face, a step smaller:
they are usually words about the code (diagnostics, inlay hints, blame).
When a plugin's virtual lines are code themselves — the deleted lines of an
inline diff, a hunk preview — it says so, and they stay in the grid's face:

```lua
local ns = vim.api.nvim_create_namespace 'my_inline_diff'
require('devhub').gui.content_namespace(ns)        -- false undoes it
```

### `gui.popup`: a hover at a buffer position

```lua
local pop = gui.popup {
  anchor = 'cursor',                      -- or { buf, lnum, col } (lnum 1-based, col 0-based)
  placement = 'below',                    -- 'above' | 'auto': the side it tries first
  component = ui.md '**detect**() -> `Platform`',
  max_width = 80, max_height = 20,        -- cells
  close_on = { 'CursorMoved', 'InsertEnter', 'BufLeave' }, -- while not focused
  keys = { ['<CR>'] = function(p) end },  -- extra keys while focused
  text = 'what y yanks',                  -- default: the content's text
  on_close = function(p) end,
}
pop:focus()                               -- j/k, <C-d>/<C-u>, gg/G scroll; q/<Esc> close; y yanks
pop:scroll('half'); pop:update(ui.md 'new'); pop:close(); pop:is_open()
```

No Neovim window: DevHub draws it at the position (it follows scrolling),
as wide and tall as its content up to its maximum and the room there, and
scrolls inside past that (the wheel too). Neovim keeps the keys: focused,
the keys above are buffer-local maps on the anchor's buffer, and what they
replaced comes back when it closes. Outside DevHub `gui.popup` answers `nil`.

### Notifications: `notify = true`

```lua
require('devhub').setup { notify = true }  -- or require('devhub').gui.override_notify()
gui.notify { group = 'build', key = 'job:1', msg = 'compiling', progress = true, percent = 40 }
gui.notify { group = 'build', key = 'job:1', msg = 'compiled', done = true }
```

In DevHub's GUI `vim.notify` becomes DevHub's, drawn as fidget draws: compact
lines at the bottom right above the status line, under their source
(`opts.title`), fading. LSP progress (`LspProgress`) shows as a
spinner, the work's title and its percentage, ticked when done. Outside
DevHub nothing changes.

`gui.history()` answers the notifications DevHub has shown, oldest first
(`time`, `group`, `title`, `msg`, `level`; at most 200, LSP work only once
done); `gui.clear_history()` forgets them. `:Notifications`
(`gui.notifications()`) reads them again in DevHub's pager — a buffer in a
float, newest last: `j`/`k`, `/` and `y` as anywhere, `q` closes, `<Tab>`
switches to Neovim's `:messages` (`:DevhubNotifications` is the same pager
without this plugin). Outside DevHub it is `:messages`.

### Choices: `quick_pick = true`

```lua
require('devhub').setup { quick_pick = true }  -- or require('devhub').gui.quick_pick()
```

In DevHub's GUI `vim.ui.select` and `vim.ui.input` become DevHub's quick
pick — the control DevHub asks all its own questions with (the command
palette's): typing filters, the arrows and `<C-n>`/`<C-p>` move, Return
answers, Escape cancels. The callback runs with the answer (`nil` when
cancelled); Neovim does not wait meanwhile. It wins over a plugin that
takes `vim.ui.select` in its own setup (snacks' `ui_select`, dressing), and
what it replaced is used outside DevHub. `gui.select`/`gui.input` are the
same calls without replacing anything. See DevHub's `docs/native-picker.md`.

## Options

```lua
require('devhub').setup {
  auto = true,     -- wear the theme at startup when no colorscheme is chosen
  notify = false,  -- vim.notify drawn by DevHub (in its GUI), with LSP progress
  quick_pick = false, -- vim.ui.select / vim.ui.input as DevHub's quick pick (in its GUI)
  follow = true,   -- follow User DevhubTheme and changes to the file
  on_apply = function(theme) end, -- your tweaks, after every apply: theme.colors
                                  -- (background, foreground, ansi[1..16], …), theme.neovim
}
```

`vim.g.devhub_auto = false` (before the plugin loads) keeps `plugin/` from
applying anything; `:colorscheme devhub` is then yours to run.
`require('devhub').fzf_colors()` is the theme's `fzf --color=` value, for
fzf-lua's `fzf_opts`.

## Tests

```sh
tests/run.sh   # nvim --headless: startup highlights are the theme file's
               # table, every group, before any event; a live switch and back is identical; a
               # replaced file is followed; setup() outside DevHub is a no-op;
               # the component builders, the GUI facade over a stand-in for
               # DevHub
tests/fixtures/regenerate.sh <DevHub checkout>  # the fixtures, from DevHub's generator
```

Neovim 0.12, the one DevHub runs: `NVIM=<DevHub>/apps/desktop/out/nvim/bin/nvim
tests/run.sh` in a built DevHub checkout (`pnpm --filter @devhub/desktop
build:nvim`).
