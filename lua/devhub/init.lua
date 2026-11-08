-- devhub.nvim: Neovim in the colour theme DevHub wears.
--
-- DevHub publishes the theme it wears to the programs in its terminals (see
-- DevHub's docs/window-and-pages.md, "Terminal programs"), with the Neovim
-- colorscheme it generates from it (`neovim`: `background`, `highlights`,
-- `terminal`; DevHub's docs/themes.md, "Neovim"):
--
--   * $DEVHUB_THEME_FILE, a JSON file rewritten (atomically) on every change;
--   * for the Neovims DevHub draws, `User DevhubTheme` with the same object
--     as its data.
--
-- This module applies that table, as DevHub itself applies it to the Neovims
-- it draws. Startup and every live change go through `apply(theme)`, so the
-- first frame and a switch an hour later are coloured from the same value.

local M = {}

local uv = vim.uv or vim.loop

M.config = {
  -- Apply the theme while Neovim starts (from plugin/devhub.lua), when no
  -- other colorscheme has been chosen yet.
  auto = true,
  -- Follow changes: `User DevhubTheme` and the theme file.
  follow = true,
  -- In DevHub's GUI, vim.notify drawn by DevHub (fidget-like, with LSP progress).
  notify = false,
  -- Run after the highlights are set, with the theme: for your own tweaks.
  on_apply = nil,
}

--- Whether DevHub publishes its theme file to this Neovim (a DevHub terminal
--- on this machine).
function M.inside()
  local path = vim.env.DEVHUB_THEME_FILE
  return path ~= nil and path ~= ''
end

--- A theme DevHub published, with its Neovim colorscheme; else nil.
local function valid(theme)
  return type(theme) == 'table'
      and theme.version == 1
      and type(theme.neovim) == 'table'
      and type(theme.neovim.highlights) == 'table'
      and type(theme.neovim.terminal) == 'table'
      and theme
    or nil
end

local function read_file(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local text = file:read '*a'
  file:close()
  local ok, value = pcall(vim.json.decode, text)
  return ok and valid(value) or nil
end

--- The theme DevHub publishes now, or nil outside DevHub.
function M.read()
  return M.inside() and read_file(vim.env.DEVHUB_THEME_FILE) or nil
end

--- Make `theme` the colours: DevHub's colorscheme for it (`theme.neovim`),
--- applied as a colorscheme file applies itself. Startup and every change
--- come here.
function M.apply(theme)
  local scheme = theme.neovim
  -- Unset first: setting 'background' while a colorscheme is named reloads it.
  vim.g.colors_name = nil
  vim.cmd 'highlight clear'
  if vim.fn.exists 'syntax_on' == 1 then
    vim.cmd 'syntax reset'
  end
  vim.o.termguicolors = true
  vim.o.background = scheme.background
  for name, spec in pairs(scheme.highlights) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  for index, color in ipairs(scheme.terminal) do
    vim.g['terminal_color_' .. (index - 1)] = color
  end
  vim.g.colors_name = 'devhub'
  M.current = theme
  if M.config.on_apply then
    M.config.on_apply(theme)
  end
end

--- `:colorscheme devhub`: the theme DevHub publishes now. Outside DevHub
--- there is none, and that is said rather than painting something else.
function M.load()
  local theme = M.pending or M.read()
  M.pending = nil
  if not theme then
    vim.notify('devhub.nvim: no DevHub theme to wear here (no $DEVHUB_THEME_FILE with a `neovim` table)', vim.log.levels.WARN)
    return false
  end
  M.apply(theme)
  return true
end

--- The fzf `--color=` value for the theme worn, for fzf-lua's `fzf_opts` or a
--- shell. nil outside DevHub.
function M.fzf_colors()
  local theme = M.current or M.read()
  return theme and theme.fzf or nil
end

-- ----------------------------------------------------------------- follow

local group = vim.api.nvim_create_augroup('devhub_theme', { clear = true })
local watcher
local followed = false

local function reapply(theme)
  if vim.g.colors_name ~= 'devhub' or not theme then
    return
  end
  if M.current and vim.deep_equal(M.current, theme) then
    return
  end
  -- Through `:colorscheme`, as at startup: the same code, and your
  -- ColorScheme autocommands run after it the same way.
  M.pending = theme
  vim.cmd.colorscheme 'devhub'
end

local function follow()
  if followed then
    return
  end
  followed = true
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DevhubTheme',
    callback = function(event)
      local theme = valid(event.data) or M.read()
      reapply(theme)
    end,
  })
  -- A Neovim DevHub does not manage (yours, in a pane) learns from the file.
  -- The directory is watched, because the file is replaced by a rename.
  local path = vim.env.DEVHUB_THEME_FILE
  if not path or path == '' or watcher then
    return
  end
  local directory = vim.fn.fnamemodify(path, ':h')
  local name = vim.fn.fnamemodify(path, ':t')
  watcher = uv.new_fs_event()
  if not watcher then
    return
  end
  local ok = pcall(watcher.start, watcher, directory, {}, function(_, filename)
    if filename ~= name then
      return
    end
    vim.schedule(function()
      reapply(read_file(path))
    end)
  end)
  if not ok then
    watcher = nil
  end
end

--- Configure, and inside DevHub apply the theme (`auto`) and follow it
--- (`follow`). Outside DevHub this does nothing at all.
function M.setup(options)
  M.config = vim.tbl_extend('force', M.config, options or {})
  if M.gui.available() then
    M.gui.hook_floats_on_lsp()
    if M.config.notify then
      M.gui.override_notify()
    end
  end
  if not M.inside() then
    return
  end
  if M.config.follow then
    follow()
  end
  if M.config.auto and vim.g.colors_name ~= 'devhub' then
    vim.cmd.colorscheme 'devhub'
  end
end

--- What plugin/devhub.lua does as Neovim starts: inside DevHub, with no
--- colorscheme chosen yet, the theme before the first redraw.
function M._startup()
  if vim.g.devhub_loaded then
    return
  end
  vim.g.devhub_loaded = true
  if vim.env.DEVHUB_NEOVIM_GUI == '1' then
    M.gui.hook_floats_on_lsp()
  end
  if not M.inside() then
    return
  end
  if M.config.follow then
    follow()
  end
  if M.config.auto and vim.g.devhub_auto ~= false and not vim.g.colors_name then
    vim.cmd.colorscheme 'devhub'
  end
end

-- require('devhub').gui: DevHub's GUI (lua/devhub/gui.lua), loaded on use.
return setmetatable(M, {
  __index = function(_, key)
    if key == 'gui' then
      local gui = require 'devhub.gui'
      rawset(M, 'gui', gui)
      return gui
    end
  end,
})
