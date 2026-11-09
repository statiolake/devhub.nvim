-- require('devhub').gui: DevHub's GUI from your config.
--
-- When DevHub is Neovim's GUI (`[general] editor = "neovim"`), DevHub injects
-- the implementation at every attach: a Lua module, `devhub_gui`, that talks
-- to DevHub over the UI's RPC channel. DevHub owns it because it owns the
-- other end of every message (and it is there on an SSH host where this
-- plugin may be a version behind). This module is the stable face of it for
-- configs and plugins:
--
--   * every call forwards to `devhub_gui` when DevHub is attached;
--   * outside DevHub it is harmless: notify falls back to vim.notify, the
--     rest do nothing and answer nil;
--   * your config runs before DevHub attaches, so a call made while
--     Neovim starts in DevHub's GUI ($DEVHUB_NEOVIM_GUI) waits for the
--     attach (`User DevhubGui`) instead of being dropped.

local M = {}

local pending = {}

--- Whether this Neovim's UI is (or is about to be) DevHub's GUI.
function M.available()
  return vim.g.devhub_gui == true or vim.env.DEVHUB_NEOVIM_GUI == '1'
end

--- The implementation DevHub injected, once it has attached.
local function core()
  local c = package.loaded['devhub_gui']
  if c and c._chan then
    return c
  end
  return nil
end
M._core = core

-- Run fn(core) now, or at the attach when DevHub's GUI is still starting.
local function with_core(fn)
  local c = core()
  if c then
    return fn(c)
  end
  if vim.env.DEVHUB_NEOVIM_GUI == '1' then
    table.insert(pending, fn)
  end
  return nil
end

vim.api.nvim_create_autocmd('User', {
  pattern = 'DevhubGui',
  group = vim.api.nvim_create_augroup('devhub_gui_facade', { clear = true }),
  callback = function()
    local c = core()
    if not c then
      return
    end
    local queued = pending
    pending = {}
    for _, fn in ipairs(queued) do
      local ok, err = pcall(fn, c)
      if not ok then
        vim.notify('devhub.gui: ' .. tostring(err), vim.log.levels.WARN)
      end
    end
  end,
})

--- A GUI window: web content DevHub paints over a Neovim window.
--- opts: { title, html | url, win = 'vsplit' | 'split' | 'float' | 'tab' | 'current',
---   keyboard = 'neovim' | 'content' }.
--- keyboard: 'neovim' (an html page's default) keeps the keys Neovim's, as
--- in normal mode: the buffer's lines are the page's focusable elements, the
--- cursor line the focused one, <CR> activates it, i/a/I/A type into a field
--- (insert mode) and <Esc> leaves it. 'content' gives the page the keys
--- while its window is current (<C-w> gives them back); a url page's default
--- and only choice.
--- Answers a handle (nil outside DevHub, or while it has not attached yet).
function M.open(opts)
  local c = core()
  return c and c.open(opts) or nil
end

--- Send a GUI window's page a message (its devhub.onMessage(fn) gets it).
function M.send(handle, message)
  local c = core()
  if c and handle then
    c.send(handle, message)
  end
end

--- fn(message) for every devhub.send(message) of the window's page.
function M.on_message(handle, fn)
  local c = core()
  if c and handle then
    c.on_message(handle, fn)
  end
end

function M.close(handle)
  local c = core()
  if c and handle then
    c.close(handle)
  end
end

--- A notification, drawn by DevHub as fidget draws: bottom right, under its
--- source's name, fading when its time is up.
--- notify{ msg = 'done', title = 'Build', level = 'info' | 'warn' | 'error' |
---   'debug' | vim.log.levels.*, group = 'source', key = 'id', timeout = ms,
---   progress = true, percent = 0..100, done = bool }; a key updates the
--- notification it named. Outside DevHub: vim.notify(msg, level, { title }).
function M.notify(opts)
  if type(opts) ~= 'table' then
    opts = { msg = opts }
  end
  if core() or vim.env.DEVHUB_NEOVIM_GUI == '1' then
    with_core(function(c)
      c.notify(opts)
    end)
    return
  end
  local level = opts.level
  if type(level) == 'string' then
    level = vim.log.levels[level:upper()] or vim.log.levels.INFO
  end
  local notify = M._original_notify or vim.notify
  notify(tostring(opts.msg or opts.body or ''), level, { title = opts.title })
end

--- The notifications DevHub has shown, oldest first (at most 200, LSP work
--- only once done): { time = os.time(), group, title, msg, level, key }.
--- Empty outside DevHub, or with a DevHub that does not keep them.
function M.history()
  local c = core()
  return c and c.history and c.history() or {}
end

--- Forget them.
function M.clear_history()
  local c = core()
  if c and c.clear_history then
    c.clear_history()
  end
end

--- Read them again (`:Notifications`): DevHub's pager, a buffer in a float
--- (j/k, /, y; q closes, <Tab> goes to Neovim's :messages), newest last.
--- Outside DevHub, or with a DevHub that has no pager: :messages.
function M.notifications()
  local c = core()
  if c and c.notifications then
    c.notifications()
    return
  end
  vim.cmd 'messages'
end

local overridden = false

--- vim.notify drawn by DevHub (gui.notify) in DevHub's GUI, with LSP
--- progress (spinner, title, percentage) as fidget shows it. Outside DevHub
--- this does nothing and answers false. setup{ notify = true } calls it.
function M.override_notify()
  if not M.available() then
    return false
  end
  if overridden then
    return true
  end
  overridden = true
  M._original_notify = vim.notify
  vim.notify = function(msg, level, opts)
    opts = opts or {}
    M.notify {
      msg = type(msg) == 'string' and msg or vim.inspect(msg),
      level = level,
      title = opts.title,
      group = opts.group or opts.title,
      key = opts.key or opts.id,
      timeout = type(opts.timeout) == 'number' and opts.timeout or nil,
    }
  end
  M.lsp_progress()
  return true
end

--- LSP progress ($/progress) as notifications grouped by the
--- client's name: a spinner and the percentage while it works, a tick when done.
function M.lsp_progress()
  if vim.fn.exists '##LspProgress' == 0 then
    return
  end
  vim.api.nvim_create_autocmd('LspProgress', {
    group = vim.api.nvim_create_augroup('devhub_gui_lsp_progress', { clear = true }),
    callback = function(ev)
      local data = ev.data or {}
      local params = data.params or {}
      local value = params.value
      if type(value) ~= 'table' or not value.kind then
        return
      end
      local client = vim.lsp.get_client_by_id(data.client_id)
      local key = 'lsp:' .. tostring(data.client_id) .. ':' .. tostring(params.token)
      M._progress = M._progress or {}
      if value.kind == 'begin' then
        M._progress[key] = value.title or ''
      end
      local title = M._progress[key] or value.title or ''
      local done = value.kind == 'end'
      M.notify {
        group = client and client.name or 'LSP',
        key = key,
        title = title,
        msg = value.message or (done and 'done' or ''),
        percent = value.percentage,
        progress = true,
        done = done,
      }
      if done then
        M._progress[key] = nil
      end
    end,
  })
end

--- An image under line `line` (1-based) of `buf` (0: the current one).
--- src: a path on this Neovim's machine, or an https URL.
--- opts.height_rows: the rows reserved for it (virt_lines), default 8.
--- Answers a handle with :clear() (nil outside DevHub: nothing is reserved).
function M.image(buf, line, src, opts)
  return with_core(function(c)
    return c.image(buf, line, src, opts)
  end)
end


-- Buffer-backed GUI: views, inline cards, decorations. ---------------------

--- The component builders (lua/devhub/ui.lua).
M.ui = require 'devhub.ui'

-- A handle that works before DevHub attaches (and outside it, as a no-op):
-- the call is made at the attach, and the handle then forwards to the real one.
local function deferred(call)
  local handle = { pending = true }
  local real
  with_core(function(c)
    real = call(c)
    handle.pending = false
    if real then
      handle.id, handle.buf, handle.win = real.id, real.buf, real.win
    end
  end)
  setmetatable(handle, {
    __index = function(_, method)
      return function(_, ...)
        if real and real[method] then
          return real[method](real, ...)
        end
      end
    end,
  })
  return handle
end

local function check_component(where, node)
  local ok, err = M.ui.validate(node)
  if not ok then
    error('devhub.gui.' .. where .. ': ' .. err, 3)
  end
end

--- A panel backed by a buffer: one buffer line per item (your adapter writes
--- the lines — they stay searchable text), each drawn by DevHub as a
--- component over every window showing the buffer, as tall as it draws.
--- The cursor line is the focused item; Neovim keeps the keys.
---   opts.buf    the buffer (0: the current one)
---   opts.win    a window, or 'vsplit' | 'split' | 'float' | 'current' to open one
---   opts.items  fn(lnum, line) -> component | nil, or { [lnum] = component }
---               (nil: the line's own text, plainly)
---   opts.on_click fn(lnum): a click on an item (after the cursor moved there)
---   opts.keys   { { 'j/k', 'move' }, { '<CR>', 'open' } }: the hint line
--- Answers a handle: :update(items?) to draw again, :close(). Outside DevHub
--- the buffer is just text and the handle does nothing.
function M.view(opts)
  opts = opts or {}
  if type(opts.items) == 'table' then
    for lnum, node in pairs(opts.items) do
      check_component('view (item ' .. tostring(lnum) .. ')', node)
    end
  elseif opts.items ~= nil and type(opts.items) ~= 'function' then
    error('devhub.gui.view: items must be a function or a table', 2)
  end
  return deferred(function(c)
    return c.view and c.view(opts)
  end)
end

--- A card under line lnum of buf, in rows Neovim reserves (virt_lines) and
--- DevHub fills; as tall as it draws. It follows scrolling, folds and window
--- moves. opts: { buf, lnum, component, id?, range = { first, last }? }.
--- The same id in the same buffer updates that card. The cursor on the
--- range (default: lnum) marks the card active; your buffer-local keymaps
--- on those lines are its keys. Answers a handle: :update(component),
--- :move(lnum), :clear(). Outside DevHub nothing is reserved.
function M.inline(opts)
  opts = opts or {}
  check_component('inline', opts.component)
  return deferred(function(c)
    return c.inline and c.inline(opts)
  end)
end

--- Ring an inline card as focused (or not), whatever the cursor says.
function M.inline_focus(handle, on)
  local c = core()
  if c and c.inline_focus and handle then
    c.inline_focus(handle.id or handle, on)
  end
end

--- Every inline card of buf (nil: all), cleared.
function M.inline_clear_all(buf)
  local c = core()
  if c and c.inline_clear_all then
    c.inline_clear_all(buf)
  end
end

--- Paint a line range over every window showing it (diff windows too):
--- opts: { buf, range = { first, last }, style = 'dim' | 'highlight' | 'tag',
--- tag = 'NEW since viewed'?, hl = group or tone? }. Answers a handle: :clear().
function M.decorate(opts)
  opts = opts or {}
  if opts.style and opts.style ~= 'dim' and opts.style ~= 'highlight' and opts.style ~= 'tag' then
    error("devhub.gui.decorate: style must be 'dim', 'highlight' or 'tag'", 2)
  end
  return deferred(function(c)
    return c.decorate and c.decorate(opts)
  end)
end

--- Declare that the virtual text and lines of extmark namespace ns (an id or
--- a name) are content — code, like the deleted lines of an inline diff —
--- so DevHub draws them in the grid's face as the buffer's own lines, not in
--- the proportional face it gives words about the code (diagnostics, hints,
--- notes). on = false undoes it. Outside DevHub nothing changes.
function M.content_namespace(ns, on)
  with_core(function(c)
    if c.content_namespace then
      c.content_namespace(ns, on)
    end
  end)
end

function M.decorate_clear_all(buf)
  local c = core()
  if c and c.decorate_clear_all then
    c.decorate_clear_all(buf)
  end
end

--- A popup DevHub draws at a buffer position (a hover), with no Neovim
--- window: Neovim keeps the content and the keys.
---   opts.anchor     'cursor' (default) or { buf, lnum, col } (1-based lnum, 0-based col)
---   opts.placement  'below' (default) | 'above' | 'auto': the side it prefers;
---                   it flips when the other side has the room
---   opts.component  a gui.ui tree (ui.md for markdown and code)
---   opts.max_width, opts.max_height  in cells
---   opts.close_on   events that close it while it is not focused
---                   (default CursorMoved, CursorMovedI, InsertCharPre, BufLeave)
---   opts.keys       { [lhs] = fn(handle) }: extra keys while it is focused
---   opts.text       what y yanks (default: the content's text)
---   opts.on_close   fn(handle)
--- Answers a handle — :update(component), :focus() (j/k, <C-d>/<C-u>, gg/G
--- scroll it, q/<Esc> close it, y yanks, until the cursor moves),
--- :scroll(n | 'half' | '-half' | 'page' | '-page' | 'top' | 'bottom'),
--- :close(), :is_open() — or nil outside DevHub.
function M.popup(opts)
  opts = opts or {}
  check_component('popup', opts.component)
  local c = core()
  return c and c.popup and c.popup(opts) or nil
end

--- vim.ui.select in DevHub's quick pick: the same contract (on_choice(item,
--- idx), or nil, nil when cancelled), answered in DevHub's own picker. Outside
--- DevHub, Neovim's (or whichever plugin's) vim.ui.select as it was.
function M.select(items, opts, on_choice)
  local c = core()
  if c and c.select then
    return c.select(items, opts, on_choice)
  end
  return (M._ui_select or vim.ui.select)(items, opts, on_choice)
end

--- vim.ui.input in DevHub's quick pick: on_confirm(text), or nil when cancelled.
function M.input(opts, on_confirm)
  local c = core()
  if c and c.input then
    return c.input(opts, on_confirm)
  end
  return (M._ui_input or vim.ui.input)(opts, on_confirm)
end

--- Make vim.ui.select and vim.ui.input DevHub's quick pick (setup{
--- quick_pick = true }). Installed again once Neovim has started and at
--- every attach, so it wins over a plugin that takes them in its own setup
--- (snacks' ui_select, dressing): in DevHub's GUI a simple choice is DevHub's
--- question, drawn as every other one is. What it replaced is kept and used
--- outside DevHub.
function M.quick_pick()
  local function install()
    if vim.ui.select ~= M.select then
      M._ui_select = vim.ui.select
      vim.ui.select = M.select
    end
    if vim.ui.input ~= M.input then
      M._ui_input = vim.ui.input
      vim.ui.input = M.input
    end
  end
  install()
  local group = vim.api.nvim_create_augroup('devhub_quick_pick', { clear = true })
  vim.api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = function()
    vim.schedule(install)
  end })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'DevhubGui', callback = install })
end

return M
