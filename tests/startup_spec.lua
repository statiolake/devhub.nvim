-- nvim --headless: the highlights at startup are the theme file's generated
-- table (`neovim`), every group as it says, before any `User DevhubTheme`; the
-- same theme told live gives the same highlights; a change to the file is
-- followed.
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

local scheme = theme.neovim

--- What a group should read back as: its spec, its colours as numbers and
--- without the attributes it turns off.
local function expected(spec)
  local out = {}
  for key, value in pairs(spec) do
    if value ~= false then
      out[key] = (key == 'fg' or key == 'bg' or key == 'sp') and tonumber(value:sub(2), 16) or value
    end
  end
  return out
end
-- 1. Before the first redraw, with no event: DevHub's table, as it is.
local at_enter = vim.g.devhub_test_at_enter or {}
check(at_enter.colors_name == 'devhub', 'not devhub at VimEnter: ' .. tostring(at_enter.colors_name))
check(at_enter.normal_bg == scheme.highlights.Normal.bg, 'Normal bg at VimEnter: ' .. tostring(at_enter.normal_bg))
check(at_enter.events == 0, 'an event came before VimEnter')
check(vim.o.background == scheme.background, 'background')
for index = 0, 15 do
  check(vim.g['terminal_color_' .. index] == scheme.terminal[index + 1], 'terminal_color_' .. index)
end

-- 2. Every group is the table's: a link is that link, any other spec those
-- attributes and no more.
local mismatched = {}
for name, spec in pairs(scheme.highlights) do
  local hl = vim.api.nvim_get_hl(0, { name = name })
  local want = expected(spec)
  hl.default, hl.cterm = nil, nil
  if not vim.deep_equal(hl, want) then
    table.insert(mismatched, name)
  end
end
table.sort(mismatched)
check(#mismatched == 0, 'groups not as the table says: ' .. table.concat(mismatched, ', '))

local function snapshot()
  local all = {}
  for name in pairs(scheme.highlights) do
    all[name] = vim.api.nvim_get_hl(0, { name = name })
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
check(hex(vim.api.nvim_get_hl(0, { name = 'Normal' }).bg) == other.neovim.highlights.Normal.bg, 'live Normal bg')
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
  return hex(vim.api.nvim_get_hl(0, { name = 'Normal' }).bg) == other.neovim.highlights.Normal.bg
end, 20)
check(switched, 'the file change was not followed (' .. directory .. ')')
os.remove(copy)

-- 5. A file without DevHub's generated table (an older DevHub's) is not worn.
local bare = vim.fn.tempname() .. '.json'
local without = vim.deepcopy(theme)
without.neovim = nil
write(bare, vim.json.encode(without))
vim.env.DEVHUB_THEME_FILE = bare
check(devhub.read() == nil, 'a theme without `neovim` was read')
os.remove(bare)

-- 6. Outside DevHub, setup does nothing.
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
