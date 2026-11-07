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
--
-- It also installs the hook that lets DevHub draw LSP hover and signature
-- help natively (see M.hook_floats).

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
--- opts: { title, html | url, win = 'vsplit' | 'split' | 'float' | 'tab' | 'current' }.
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

--- A native toast: notify{ title = 'Build', msg = 'done', level = 'info' }.
--- level: 'info' | 'warn' | 'error' | 'debug' or vim.log.levels.*.
--- Outside DevHub: vim.notify(msg, level, { title = title }).
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
  vim.notify(tostring(opts.msg or opts.body or ''), level, { title = opts.title })
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

--- Draw a float's markdown natively (what the hook below does for LSP).
function M.rich_float(win, markdown)
  local c = core()
  return c and c.rich_float and c.rich_float(win, markdown) or nil
end

local hooked = false

--- hook_floats() at the first LspAttach: vim.lsp stays unloaded until then.
function M.hook_floats_on_lsp()
  vim.api.nvim_create_autocmd('LspAttach', {
    group = vim.api.nvim_create_augroup('devhub_gui_floats', { clear = true }),
    once = true,
    callback = function()
      M.hook_floats()
    end,
  })
end

--- Hook vim.lsp.util.open_floating_preview so that a markdown float (LSP
--- hover, signature help) is drawn by DevHub: headings, lists, fenced code
--- highlighted, links clickable. The float stays Neovim's — its keys scroll
--- and close it, DevHub follows — and anything unexpected leaves Neovim's
--- own rendering. Installed by setup() and at startup in DevHub's GUI; set
--- vim.g.devhub_rich_floats = false to keep Neovim's.
function M.hook_floats()
  if hooked or vim.g.devhub_rich_floats == false then
    return
  end
  local util = vim.lsp and vim.lsp.util
  if not util or type(util.open_floating_preview) ~= 'function' then
    return
  end
  hooked = true
  local original = util.open_floating_preview
  util.open_floating_preview = function(contents, syntax, opts, ...)
    local buf, win = original(contents, syntax, opts, ...)
    if
      syntax == 'markdown'
      and vim.g.devhub_rich_floats ~= false
      and core()
      and win
      and vim.api.nvim_win_is_valid(win)
      and buf
      and vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].filetype == 'markdown'
    then
      pcall(M.rich_float, win, contents)
    end
    return buf, win
  end
end

return M
