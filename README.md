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
`neovim.highlights` (the editor, syntax, Tree-sitter, LSP, diagnostics and
diffs: Neovim's groups, no plugin's), and
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

  -- A webview: web content in an ordinary Neovim window.
  local w = gui.webview { title = 'Outline', html = '<button>…</button>', win = 'vsplit' }
  --                      or url = 'https://…'; win = 'vsplit' | 'split' | 'float' | 'tab' | 'current'
  --                      keyboard = 'neovim' (html's default: j/k/<CR>/i over its elements) | 'content'
  w:on_message(function(msg) end)       -- the page's devhub.send(msg)
  w:send { kind = 'hello' }              -- the page's devhub.onMessage(fn)
  w:close()

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
- **LSP hover, signature help and diagnostic floats as DevHub popups.** In
  DevHub's GUI, at the first `LspAttach`, `vim.lsp.util.open_floating_preview`
  is wrapped so that its floats are `gui.popup`s: laid out by DevHub
  (paragraphs reflowed, fenced code wrapped and highlighted, links that open
  in the browser), at the cursor, flipping above when there is no room
  below, scrolling inside when long. `K K` focuses it (`j`/`k`,
  `<C-d>`/`<C-u>`, `gg`/`G` scroll, `q`/`<Esc>` close, `y` yanks); moving
  the cursor closes it. The float's `border`/`title` give way to DevHub's
  frame; `max_width`/`max_height` are kept. Callers still get a buffer and
  a (hidden) window back, as from Neovim, and the highlights they put on
  its code are drawn (signature help's active parameter, through
  `ui.md(text, { marks = … })`). Outside DevHub or on
  any error, Neovim's own float. Set `vim.g.devhub_rich_floats = false` to
  keep Neovim's always.
- `:DevhubImageDemo [path]` and `:DevhubGuiDemo` come from DevHub. There
  is no DevHub terminal inside Neovim: the Workspace's terminal is DevHub's
  editor area itself, and Neovim's own `:terminal` is drawn as usual.

## Buffer-backed GUI: components, views, cards, popups

Neovim keeps the state, the layout and the keys; DevHub only paints. What
DevHub paints is described as **data** — components — not HTML: DevHub draws
them in its own type with your colours (every colour is a highlight group, or
a tone that names one, resolved by Neovim). A click on a node runs its
`on_click` in Neovim. HTML stays the escape hatch (`gui.webview`). Outside
DevHub every call below is harmless: a view is just its buffer's text, a card
reserves nothing, the handles do nothing.

### Components: `gui.ui`

```lua
local gui = require('devhub').gui
local ui = gui.ui

ui.card {                                   -- a raised column; accent = a ring in that tone
  accent = 'warn',
  ui.hstack {                               -- a row; gap, pad, align, justify, wrap, indent, bg, round
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
(else one line with an ellipsis), `ink` (only the group's colour, not its
weight or slant) and `hl`/`tone`; runs take `hl`/`tone`,
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

Write keys as Vim writes them (`<C-v>`, `<CR>`, `<S-Tab>`, `j/k`): DevHub
shows every key — a hint row's, a `ui.kbd`'s, a button's `key` — in its one
notation, a Mac's, the same as its own hints and tmux's: `⌃V`, `↩`, `⇧⇥`,
`⎋`, a modified letter a capital, a letter alone as it is typed (`j` and
`J` stay apart). Keys already written that way, and words that are not keys
(`:write`), are shown as they are.

#### A framed view: a picker

Given a `frame`, a view is drawn in a frame over a float instead of over
its window: a picker's list, with the rest of a picker round it. Whoever's
picker it is — devhub.nvim knows none;
[snacks-ui.devhub](https://github.com/statiolake/snacks-ui.devhub) draws
snacks.nvim's this way. Every part is a Neovim window your plugin lays out,
and DevHub draws each where its window stands:

- the **items** in the cells of the window showing the view's buffer (hide
  it: `hide = true`), whose cursor line is the selected row; an item may be
  `{ node = …, heading = … }` (a heading above it that is not an item),
  `on_click(lnum, clicks)` leaves the keys in the query, `on_scroll(rows)`
  gets the wheel and `on_rows(rows)` how many rows fit — your page size;
- the **query** is a window (hidden too) whose buffer's first line is the
  field; its caret is the window's cursor while it is current in Insert
  mode, so its keys are its buffer's maps;
- the **preview** is a window drawn as cells; the row above it is its
  title. `keys` is the hint row, on the frame's last row.

```lua
local list = gui.view {
  buf = list_buf, win = list_win,                           -- list_win: hidden
  items = function(lnum, line) return ui.text(line) end,
  on_click = function(lnum, clicks) end, on_scroll = function(rows) end, on_rows = function(rows) end,
  keys = { { '<CR>', 'open' }, { '<Esc>', 'close' } },
  frame = {
    win = frame_win,                                        -- the float the frame covers
    query = { win = query_win, placeholder = 'Search' },
    preview = { win = preview_win, title = ui.text 'src › a.ts' },
    title = ui.badge 'Files', status = ui.text '3 / 9',
  },
}
list:frame { status = ui.text '2 / 9' }
list:redraw()                             -- the list's cursor moved without an edit
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

### Virtual text: the grid's face, but for Neovim's own

A plugin's virtual text and lines are drawn as it drew them, cells in the
grid's face (an inline diff's deleted lines, a blame line). DevHub sets in
its UI face only what it restyles on purpose: Neovim's own features
(diagnostics' virtual text and lines, LSP inlay hints and code lenses —
namespaces `nvim.*`), folds, and its own. There is nothing to declare.

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

A popup may hold a **list** whose selection your Lua moves and a **pane**
that scrolls on its own — a menu at the cursor with its documentation under
it:

```lua
local menu = gui.popup {
  anchor = { buf, lnum, col }, close_on = {},
  min_width = 36,                         -- cells: it does not narrow when the pane goes
  component = ui.stack {
    ui.stack {                            -- a list: one band behind the selected row
      selected = 1, band = 'PmenuSel',
      ui.hstack { ui.badge('f', { size = 'sm', hl = 'Function' }),
                  ui.text('useState', { mono = true, anchor = true }) }, -- anchor: under the anchor's column
      ui.hstack { ui.badge('v', { size = 'sm' }), ui.text('user', { mono = true }) },
    },
    ui.stack { pane = 'doc', max_height = 240, ui.md(doc) },   -- pixels; scrolls inside past that
  },
}
menu:select(2)                            -- the band glides there; only the index is sent
menu:pane('doc', ui.md(other))            -- the pane's content alone, not the tree
menu:scroll(4, 'doc')                     -- the pane, not the popup ('half', 'page', 'top', … too)
menu:update(tree)                         -- for a tree that changed
```

The band moves by transform only, placed at once when it appears. A pane
starts at its top again when its content changes, has a hairline at its top
edge, is not there while empty, and gives up its height first when the
popup has no room for all of it. The first node with
`anchor = true` starts at the anchor's column: the popup moves left by as
much as that node is from its edge, so the words of a list line up with the
word being typed. `ui.badge(text, { size = 'sm' })` (or `'xs'`) is a badge
for a dense row.

No Neovim window: DevHub draws it at the position (it follows scrolling),
as wide and tall as its content up to its maximum and the room there, and
scrolls inside past that (the wheel too). Neovim keeps the keys: focused,
the keys above are buffer-local maps on the anchor's buffer, and what they
replaced comes back when it closes. Outside DevHub `gui.popup` answers `nil`.

A popup may stand on DevHub's **command line** instead — a menu for what is
being typed after `:`:

```lua
local wild = gui.popup {
  anchor = { cmdline = start },           -- a 0-based byte of getcmdline(); or 'cmdline' (its start)
  close_on = {},                          -- the default here: it closes with the command line
  component = menu_tree,                  -- the same list and pane as above
}
```

DevHub draws the command line in its own box, so the popup goes above that
box (`placement = 'below'`: under it), on the other side when only that one
has the room, and never over it; its `anchor = true` node is over the cell
of that byte in the box's text. It follows the box as it moves or grows,
and closes when the command line does (`CmdlineLeave`). It takes no keys
(`:focus()` does nothing: the command line has them). With no command line
being typed `gui.popup` answers `nil`; `gui.has_cmdline_popup()` says
whether this DevHub takes `anchor = 'cmdline'` at all (an older one does
not: draw your own there).

### `gui.statusline`: each window's footer

DevHub does not draw Neovim's status line cells: it draws each window's
footer in the row Neovim keeps for it (`laststatus` is yours; nothing
moves). Register a function and its tree is that footer:

```lua
gui.statusline(function(win, ctx)
  -- ctx = { current, laststatus, width, local_statusline, default = fn() -> tree }
  if ctx.local_statusline then return nil end   -- quickfix, a window picker's hints: Neovim's cells
  local buf = vim.api.nvim_win_get_buf(win)
  return ui.hstack { align = 'center', gap = 4,
    ui.line { grow = true, hl = ctx.current and 'StatusLine' or 'StatusLineNC' }, -- a line through the row
    ui.hstack { bg = 'Pmenu', pad = { 0, 6 }, round = true,                       -- a chip
      ui.text(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t')),
      vim.bo[buf].modified and ui.text('●') or nil },
    ctx.current and ui.position { format = 'Ln %l, Col %c' } or nil }
end, { events = { 'BufAdd' } })
```

- `fn` answers a tree, `nil` (DevHub's rules: a window's own `statusline`
  is Neovim's cells; Neovim's default `statusline` is DevHub's default
  footer — path, name, `●`, lock; diagnostics, `Ln, Col`, filetype and
  branch for the current window; a global `statusline` of yours is cells),
  or `false` (an empty footer). `ctx.default()` is DevHub's default footer,
  to use a part of it.
- It runs on buffer, window, modified, diagnostic, option and colorscheme
  changes (and `events`), at most once per turn of the event loop, and a
  tree is sent only when it changed — never per key. What changes at every
  key is a slot DevHub fills from Neovim's redraw: `ui.position{ format }`
  (`%l` line, `%c` column, `%L` lines, `%p` percent), `ui.mode{}`,
  `ui.showcmd{}`.
- `ui.line{}` is drawn at the height of the window boundaries' lines, so a
  boundary ending beside it meets it. A node with `on_click` runs it on a
  click; any other press is Neovim's (a drag of the row resizes).
- `gui.statusline('default')` draws DevHub's default footer even with a
  global `statusline` of yours (as `vim.g.devhub_statusline = 'default'`);
  `gui.statusline('cells')` Neovim's cells everywhere; `gui.statusline(nil)`
  lets go; `gui.statusline_refresh()` makes the footers again.
- Outside DevHub it does nothing: `'statusline'` is what Neovim draws, so
  keep yours for a terminal. A DevHub from before footers draws your
  `statusline` as cells; a config shared with an older devhub.nvim (an SSH
  host) guards with `if gui.statusline then … end`.

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
