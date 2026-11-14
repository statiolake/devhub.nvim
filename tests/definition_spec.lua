-- nvim --headless: the pointer's go to definition (lua/devhub/definition.lua)
-- as DevHub drives it: a child Neovim (tests/definition_child.lua: a fake
-- language server, a stand-in for DevHub's `devhub_gui` that records the
-- overlays) is sent mouse input over RPC with nvim_input_mouse, so the
-- <A-MouseMove> and <A-LeftMouse> mappings run as they do in DevHub's GUI.
local failures = {}
local function check(condition, message)
  if not condition then
    table.insert(failures, message)
    if vim.env.DEBUG then
      io.stderr:write('FAIL ' .. message .. '\n')
    end
  end
end

local root = vim.fn.getcwd()
local ch = vim.fn.jobstart({
  vim.v.progpath,
  '--embed',
  '--headless',
  '--clean',
  '--cmd',
  'set rtp^=' .. root,
  '-c',
  'luafile ' .. root .. '/tests/definition_child.lua',
}, { rpc = true })
local function R(method, ...)
  local value = vim.rpcrequest(ch, method, ...)
  if value == vim.NIL then
    return nil
  end
  return value
end
--- Lua in the child.
local function lua(code, ...)
  return R('nvim_exec_lua', code, { ... })
end
-- Grid 0 is the screen; the window is at its top left, so a screen cell is
-- the window's.
local function move(mods, row, col)
  R('nvim_input_mouse', 'move', '', mods, 0, row, col)
end
local function click(mods, row, col)
  R('nvim_input_mouse', 'left', 'press', mods, 0, row, col)
  R('nvim_input_mouse', 'left', 'release', mods, 0, row, col)
end
local function wait_for(fn, what)
  -- The input is taken in between the requests: ask again until it is.
  local ok = vim.wait(1500, function()
    return fn()
  end, 10)
  check(ok, 'timed out: ' .. what)
  return ok
end
--- Let the input be taken (and an answer come) when nothing should happen.
local function settle(ms)
  vim.wait(ms or 60)
  R('nvim_get_mode')
end
local function overlays()
  return lua 'return OVERLAYS'
end
local function last()
  local o = overlays()
  return o[#o]
end
local function reset()
  lua 'OVERLAYS = {}'
end
local function requests()
  return lua 'return #SERVER.requests'
end
local function cursor()
  return lua 'return vim.api.nvim_win_get_cursor(WIN)'
end
local function mode()
  return R('nvim_get_mode').mode
end
local function drawn(o, row, col0, col1)
  return o
    and o.id == 'devhub.definition'
    and o.win == lua 'return WIN'
    and o.spans
    and o.spans[1]
    and o.spans[1].row == row
    and o.spans[1].col0 == col0
    and o.spans[1].col1 == col1
end

-- 0. The defaults, Normal and Insert mode.
for _, m in ipairs { 'n', 'i' } do
  check(lua('return vim.fn.maparg("<A-LeftMouse>", ...)', m) ~= '', '<A-LeftMouse> mapped in ' .. m)
  check(lua('return vim.fn.maparg("<A-MouseMove>", ...)', m) ~= '', '<A-MouseMove> mapped in ' .. m)
end
check(lua 'return vim.fn.maparg("<A-LeftMouse>", "v")' == '', 'not in Visual')

-- 1. No client yet: nothing drawn, and the click is Neovim's (Alt's: a
-- blockwise Visual start at the click).
move('A', 1, 7)
settle()
check(#overlays() == 0, 'no client: nothing drawn')
click('A', 1, 7)
wait_for(function()
  return mode() == '\22'
end, 'no client: Neovim\'s Alt-click, a blockwise Visual')
R('nvim_input', '<Esc>')
settle()

lua [[CLIENT = vim.lsp.start { name = 'fake', cmd = FAKE, root_dir = vim.fn.getcwd() }]]
wait_for(function()
  return lua [[return #vim.lsp.get_clients { bufnr = BUF, method = 'textDocument/definition' } > 0]]
end, 'the fake client attaches')

-- 2. The cell to the word, by the screen: the old checks of resolve().
local resolve_failures = lua('return dofile(...)', root .. '/tests/definition_resolve.lua')
for _, f in ipairs(resolve_failures) do
  table.insert(failures, 'resolve: ' .. f)
end

-- 3. Alt held over `alpha` (line 2, cols 6-10): asked, then drawn as a link.
reset()
-- Not 1, 7: Neovim drops a move to the cell of its last mouse event (the
-- click above), whatever the modifiers.
move('A', 1, 8)
wait_for(function()
  return drawn(last(), 1, 6, 10)
end, 'the link over alpha')
local o = last()
check(o and o.pointer == 'pointer' and o.held == true, 'the hand, and held')
check(o and o.hl and o.hl.underline == true, 'underlined')
check(requests() == 1, 'one request')
local req = lua 'return SERVER.requests[1]'
check(req and req.position.line == 1 and req.position.character == 6, 'asked at the word')

-- 4. Along the same word: no new request.
move('A', 1, 9)
settle()
check(requests() == 1, 'no second request for the same word')
check(drawn(last(), 1, 6, 10), 'still the link')

-- 5. Alt up: DevHub sends a plain move (or feeds <MouseMove> at the same
-- cell): the link taken away.
reset()
move('', 1, 8)
wait_for(function()
  local l = last()
  return l and l.id == 'devhub.definition' and l.win == nil
end, 'a plain move takes the link away')
move('A', 1, 7)
wait_for(function()
  return drawn(last(), 1, 6, 10)
end, 'drawn again, from what is kept')
check(requests() == 1, 'kept: no request')
reset()
lua [[vim.api.nvim_feedkeys(vim.keycode('<MouseMove>'), 'mt', false)]]
wait_for(function()
  local l = last()
  return l and l.win == nil
end, 'a <MouseMove> fed at the same cell takes it away too')
-- And Alt down again with the pointer still: the fed <A-MouseMove>.
reset()
lua [[vim.api.nvim_feedkeys(vim.keycode('<A-MouseMove>'), 'mt', false)]]
wait_for(function()
  return drawn(last(), 1, 6, 10)
end, 'a fed <A-MouseMove> at the same cell draws it')
-- Any other key takes it away.
reset()
R('nvim_input', '<Ignore>l')
wait_for(function()
  local l = last()
  return l and l.win == nil
end, 'a key takes it away')
R('nvim_input', 'h')

-- 6. A word with no definition: the link goes, nothing drawn.
reset()
move('A', 1, 9)
wait_for(function()
  return drawn(last(), 1, 6, 10)
end, 'the link again')
move('A', 1, 2) -- `print`
wait_for(function()
  return requests() == 2
end, '`print` asked')
settle()
local l = last()
check(l and l.win == nil, 'off the link: taken away')
move('A', 1, 0)
settle()
check(requests() == 2, 'kept: no definition, not asked again')

-- 7. The next word cancels the request in flight; only the newest is drawn.
lua 'SERVER.delay = 80'
reset()
move('A', 2, 7) -- `twice`
settle(10)
move('A', 2, 14) -- `beta`
settle(250)
for _, x in ipairs(overlays()) do
  check(x.win == nil, 'the cancelled word is not drawn')
end
check(lua 'local n = 0 for _ in pairs(SERVER.cancelled) do n = n + 1 end return n' >= 1, 'the stale request cancelled')
lua 'SERVER.delay = 0'

-- 8. An edit: asked again.
local before = requests()
lua [[vim.api.nvim_buf_set_lines(BUF, 7, 7, false, { '' })]]
move('A', 1, 8)
wait_for(function()
  return requests() == before + 1
end, 'a new changedtick asks again')
lua [[vim.api.nvim_buf_set_lines(BUF, 7, 8, false, {})]]
move('A', 1, 7)
settle()

-- 9. Visual mode: nothing drawn (the mapping lets it be).
R('nvim_input', 'v')
settle()
reset()
move('A', 1, 9)
settle()
check(#overlays() == 0 or last().win == nil, 'Visual: no link')
R('nvim_input', '<Esc>')
settle()

-- 10. Alt-click on the link: the jump, as vim.lsp.buf.definition from the
-- word, with the jumplist; the drag and the release after it are nothing.
lua 'vim.api.nvim_win_set_cursor(WIN, { 3, 0 })'
move('A', 1, 7)
settle()
R('nvim_input_mouse', 'left', 'press', 'A', 0, 1, 7)
R('nvim_input_mouse', 'left', 'drag', 'A', 0, 2, 3)
R('nvim_input_mouse', 'left', 'release', 'A', 0, 2, 3)
wait_for(function()
  local c = cursor()
  return c[1] == 1 and c[2] == 6
end, 'the cursor at the definition')
settle()
local c = cursor()
check(c[1] == 1 and c[2] == 6 and mode() == 'n', 'no Visual from the drag after the jump, got ' .. vim.inspect(c) .. ' ' .. mode())
R('nvim_input', '<C-o>')
settle()
c = cursor()
check(c[1] == 2 and c[2] == 6, '<C-o> back to the clicked word, got ' .. vim.inspect(c))

-- 11. Several definitions: the quickfix list.
click('A', 2, 7)
wait_for(function()
  return #lua 'return vim.fn.getqflist()' == 2
end, 'two definitions in the quickfix list')
lua 'vim.cmd "cclose" vim.api.nvim_set_current_win(WIN)'

-- 12. No definition, or no word: Neovim's click (a blockwise Visual there).
lua 'vim.api.nvim_win_set_cursor(WIN, { 3, 0 })'
click('A', 1, 2) -- `print`
wait_for(function()
  return mode() == '\22'
end, 'no definition: a blockwise Visual')
c = cursor()
check(c[1] == 2 and c[2] == 2, 'at the click, got ' .. vim.inspect(c))
R('nvim_input', '<Esc>')
settle()
click('A', 1, 5) -- `(`
wait_for(function()
  return mode() == '\22'
end, 'not a word: a blockwise Visual')
R('nvim_input', '<Esc>')
settle()

-- 13. A click before the answer: waited for, then the jump.
lua 'require("devhub.definition").clear() SERVER.delay = 60'
lua 'vim.api.nvim_win_set_cursor(WIN, { 3, 0 })'
click('A', 1, 8)
wait_for(function()
  local cur = cursor()
  return cur[1] == 1 and cur[2] == 6
end, 'jumped when the answer came')
lua 'SERVER.delay = 0'

-- 14. setup{ definition_jump }: called with the cursor on the symbol,
-- instead of vim.lsp.buf.definition (no jump, the cursor stays there).
lua [[
SEEN = nil
require('devhub').config.definition_jump = function(ctx)
  SEEN = { ctx = ctx, cursor = vim.api.nvim_win_get_cursor(0) }
end
vim.api.nvim_win_set_cursor(WIN, { 3, 0 })
]]
click('A', 1, 9)
wait_for(function()
  return lua 'return SEEN ~= nil'
end, 'the custom jump called')
local seen = lua 'return SEEN'
check(seen and seen.ctx.lnum == 2 and seen.ctx.col == 6 and seen.ctx.win == lua 'return WIN' and seen.ctx.buf == lua 'return BUF', 'ctx: buf, win, lnum, col, got ' .. vim.inspect(seen and seen.ctx))
check(seen and seen.cursor[1] == 2 and seen.cursor[2] == 6, 'called with the cursor on the symbol')
settle()
c = cursor()
check(c[1] == 2 and c[2] == 6, 'vim.lsp.buf.definition not run as well')
-- An error in it is said, not raised.
lua [[require('devhub').config.definition_jump = function() error 'boom' end]]
click('A', 1, 10)
settle()
check(mode() == 'n', 'a failing custom jump leaves Neovim as it was')
lua [[require('devhub').config.definition_jump = nil]]

-- 15. Insert mode: the link and the jump too.
lua 'vim.api.nvim_win_set_cursor(WIN, { 3, 0 })'
R('nvim_input', 'i')
settle()
reset()
move('A', 1, 9)
wait_for(function()
  return drawn(last(), 1, 6, 10)
end, 'Insert: the link')
click('A', 1, 9)
wait_for(function()
  local cur = cursor()
  return cur[1] == 1 and cur[2] == 6
end, 'Insert: the jump')
R('nvim_input', '<Esc>')
settle()

-- 16. Turned off: nothing drawn, Neovim's click.
lua 'vim.g.devhub_definition_links = false'
reset()
move('A', 1, 8)
settle()
check(#overlays() == 0 or last().win == nil, 'turned off: no link')
click('A', 1, 8)
wait_for(function()
  return mode() == '\22'
end, 'turned off: Neovim\'s click')
R('nvim_input', '<Esc>')
settle()
lua 'vim.g.devhub_definition_links = nil'

-- 17. Your own mapping is kept; and yours can be another modifier's.
lua [[
vim.keymap.del('n', '<A-LeftMouse>')
vim.keymap.set('n', '<A-LeftMouse>', function() MINE = true end, { desc = 'mine' })
require('devhub.definition').map()
vim.keymap.set('n', '<D-LeftMouse>', require('devhub.definition').click)
vim.keymap.set('n', '<D-MouseMove>', require('devhub.definition').hover)
vim.api.nvim_win_set_cursor(WIN, { 3, 0 })
]]
check(lua 'return vim.fn.maparg("<A-LeftMouse>", "n", false, true).desc' == 'mine', 'a mapping of yours is kept')
reset()
move('D', 1, 7)
wait_for(function()
  return drawn(last(), 1, 6, 10)
end, '<D-MouseMove>: the link')
click('D', 1, 7)
wait_for(function()
  local cur = cursor()
  return cur[1] == 1 and cur[2] == 6
end, '<D-LeftMouse>: the jump')

lua 'vim.lsp.get_client_by_id(CLIENT):stop(true)'
vim.fn.jobstop(ch)

if #failures > 0 then
  error(table.concat(failures, '\n  '), 0)
end
print 'definition: ok'
