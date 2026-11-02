-- nvim --headless: the highlights at startup are the theme file's, before any
-- `User DevhubTheme`; the same theme told live gives the same highlights; a
-- change to the file is followed.
local failures = {}
local function check(condition, message)
  if not condition then
    table.insert(failures, message)
  end
end
local function hex(value)
  return value and string.format('#%06x', value) or nil
end
local function read(path)
  local file = assert(io.open(path))
  local text = file:read '*a'
  file:close()
  return vim.json.decode(text)
end

local devhub = require 'devhub'
local path = vim.env.DEVHUB_THEME_FILE
local theme = read(path)

-- 1. Before the first redraw, with no event.
local at_enter = vim.g.devhub_test_at_enter or {}
check(at_enter.colors_name == 'devhub', 'not devhub at VimEnter: ' .. tostring(at_enter.colors_name))
check(at_enter.normal_bg == theme.editor['editor.background'], 'Normal bg at VimEnter: ' .. tostring(at_enter.normal_bg))
check(at_enter.events == 0, 'an event came before VimEnter')
check(vim.o.background == theme.background, 'background')

local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
check(hex(normal.fg) == theme.editor['editor.foreground'], 'Normal fg')
for index = 0, 15 do
  check(vim.g['terminal_color_' .. index] == theme.colors.ansi[index + 1], 'terminal_color_' .. index)
end
local comment = vim.api.nvim_get_hl(0, { name = 'Comment' })
check(hex(comment.fg) == theme.tokens.comment.fg, 'Comment fg')
check((comment.italic == true) == (theme.tokens.comment.italic == true), 'Comment italic')
local ts_comment = vim.api.nvim_get_hl(0, { name = '@comment', link = false })
check(hex(ts_comment.fg) == theme.tokens.comment.fg, '@comment fg')
if theme.tokens.keyword then
  local keyword = vim.api.nvim_get_hl(0, { name = 'Keyword' })
  check(hex(keyword.fg) == theme.tokens.keyword.fg, 'Keyword fg')
end
if theme.tokens['entity.name.function'] then
  local func = vim.api.nvim_get_hl(0, { name = '@function.call', link = false })
  check(hex(func.fg) == theme.tokens['entity.name.function'].fg, '@function.call fg')
end
local err = vim.api.nvim_get_hl(0, { name = 'DiagnosticError' })
check(hex(err.fg) == theme.editor['editorError.foreground'], 'DiagnosticError fg')

-- 2. Every group, as the startup left it.
local function snapshot()
  local all = {}
  for name in pairs(devhub.highlights(theme)) do
    all[name] = vim.api.nvim_get_hl(0, { name = name, link = false })
  end
  for index = 0, 15 do
    all['terminal_color_' .. index] = vim.g['terminal_color_' .. index]
  end
  return all
end
local startup = snapshot()

-- 3. Live: another theme over RPC's event, then this one again — identical.
local other = read(vim.env.DEVHUB_TEST_OTHER)
vim.api.nvim_exec_autocmds('User', { pattern = 'DevhubTheme', data = other })
check(vim.o.background == other.background, 'the live switch did not happen')
check(hex(vim.api.nvim_get_hl(0, { name = 'Normal' }).bg) == other.editor['editor.background'], 'live Normal bg')
vim.api.nvim_exec_autocmds('User', { pattern = 'DevhubTheme', data = theme })
check(vim.deep_equal(snapshot(), startup), 'live highlights differ from the startup ones')

-- 4. The file changing (replaced by a rename, as DevHub writes it).
local copy = vim.fn.tempname() .. '.json'
vim.env.DEVHUB_THEME_FILE = nil
local directory = vim.fn.fnamemodify(copy, ':h')
local function write(path_, text)
  local file = assert(io.open(path_ .. '.tmp', 'w'))
  file:write(text)
  file:close()
  os.rename(path_ .. '.tmp', path_)
end
-- A Neovim started on this copy would watch it; here the watcher is started
-- on the copy through setup().
write(copy, vim.json.encode(theme))
vim.env.DEVHUB_THEME_FILE = copy
package.loaded.devhub = nil
devhub = require 'devhub'
devhub.setup {}
write(copy, vim.json.encode(other))
local switched = vim.wait(3000, function()
  return hex(vim.api.nvim_get_hl(0, { name = 'Normal' }).bg) == other.editor['editor.background']
end, 20)
check(switched, 'the file change was not followed (' .. directory .. ')')
os.remove(copy)

-- 5. Outside DevHub, setup does nothing.
vim.env.DEVHUB_THEME_FILE = nil
vim.env.DEVHUB_THEME_COLORS = nil
package.loaded.devhub = nil
vim.cmd 'highlight clear'
vim.g.colors_name = nil
require('devhub').setup {}
check(vim.g.colors_name == nil, 'setup outside DevHub chose a colorscheme')

if #failures > 0 then
  io.stderr:write('FAIL\n  ' .. table.concat(failures, '\n  ') .. '\n')
  vim.cmd 'cquit 1'
else
  io.stdout:write 'ok\n'
  vim.cmd 'qall!'
end
