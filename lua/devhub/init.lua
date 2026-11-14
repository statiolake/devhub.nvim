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
-- This module wears it, as DevHub itself does in the Neovims it draws: the
-- theme's own Neovim colorscheme (`neovim.colorscheme`, e.g. `min-dark`) when
-- `:colorscheme` finds it, else that table as `devhub`. Startup and every
-- live change go through `wear(theme)`, so the first frame and a switch an hour
-- later are coloured from the same value.

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
  -- In DevHub's GUI, vim.ui.select and vim.ui.input drawn as DevHub's quick
  -- pick (DevHub's docs/native-picker.md). Off until it has been tried.
  quick_pick = false,
  -- In DevHub's GUI, what the modifier-click on a symbol runs, with the
  -- cursor already on it: function(ctx) with ctx = { buf, win, lnum, col }
  -- (lnum 1-based, col 0-based, as nvim_win_get_cursor). nil:
  -- vim.lsp.buf.definition(). Set it to what your own definition key runs
  -- (a picker's), so the click and the key are one action.
  definition_jump = nil,
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

--- Whether the colorscheme worn now is DevHub's to change: none chosen yet,
--- the generated `devhub`, or a theme's own colorscheme DevHub put on
--- (`g:devhub_colorscheme`). A colorscheme your config chose is never.
local function ours()
  local chosen = vim.g.colors_name
  return chosen == nil or chosen == 'devhub' or (chosen ~= '' and chosen == vim.g.devhub_colorscheme)
end
M.ours = ours

--- Say once per Neovim that a theme's own colorscheme is not installed. The
--- same record as DevHub's own apply path keeps, so it is said once in all.
local function hint(theme, name)
  local said = vim.g.devhub_colorscheme_missing or ''
  if said:find('|' .. name .. '|', 1, true) then
    return
  end
  vim.g.devhub_colorscheme_missing = said .. '|' .. name .. '|'
  local plugin = type(theme.neovim.plugin) == 'string' and theme.neovim.plugin or 'a plugin that has it'
  vim.schedule(function()
    vim.notify(
      string.format(
        "DevHub: %s is meant to be worn as the colorscheme %s (%s). Install it to wear it; until then DevHub's generated colours are worn.",
        theme.name,
        name,
        plugin
      ),
      vim.log.levels.INFO
    )
  end)
end

--- Wear `theme`: its own Neovim colorscheme (`theme.neovim.colorscheme`) when
--- `:colorscheme` finds it — lazy.nvim loads a `lazy = true` plugin that has
--- it at that moment — else DevHub's generated one, `:colorscheme devhub`.
--- Either way through `:colorscheme`, so your ColorScheme autocommands run.
--- Returns whether the theme's own colorscheme is worn.
function M.wear(theme)
  local scheme = theme.neovim
  local own = scheme.colorscheme
  if type(own) == 'string' and own ~= '' then
    if vim.g.colors_name == own and vim.o.background == scheme.background then
      M.current = theme
      return true
    end
    -- Before it, so a colorscheme that sets its own terminal colours wins.
    for index, color in ipairs(scheme.terminal) do
      vim.g['terminal_color_' .. (index - 1)] = color
    end
    -- Unset first: setting 'background' while a colorscheme is named reloads it.
    vim.g.colors_name = nil
    vim.o.termguicolors = true
    vim.o.background = scheme.background
    if pcall(vim.cmd.colorscheme, own) then
      vim.g.devhub_colorscheme = own
      M.current = theme
      if M.config.on_apply then
        M.config.on_apply(theme)
      end
      return true
    end
    hint(theme, own)
  end
  vim.g.devhub_colorscheme = nil
  M.pending = theme
  vim.cmd.colorscheme 'devhub'
  return false
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
  if not ours() or not theme then
    return
  end
  if M.current and vim.deep_equal(M.current, theme) then
    return
  end
  -- As at startup: the same code, and your ColorScheme autocommands run
  -- after it the same way.
  M.wear(theme)
end

local function follow()
  if followed then
    return
  end
  followed = true
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DevhubTheme',
    -- Nested: the :colorscheme it runs fires ColorScheme, for your autocommands.
    nested = true,
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
    if M.config.quick_pick then
      M.gui.quick_pick()
    end
  end
  if not M.inside() then
    return
  end
  if M.config.follow then
    follow()
  end
  if M.config.auto and vim.g.colors_name ~= 'devhub' then
    local theme = M.read()
    if theme then
      M.wear(theme)
    else
      vim.cmd.colorscheme 'devhub'
    end
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
    local theme = M.read()
    if theme then
      M.wear(theme)
    end
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
