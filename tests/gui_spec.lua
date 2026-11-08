-- nvim --headless: the component builders, the GUI facade over a stand-in
-- for DevHub's `devhub_gui`, and the review-relay adapter against a fake
-- CLI (tests/fixtures/review-relay). Leaves Neovim with an error on failure.
local failures = {}
local function check(condition, message)
  if not condition then
    table.insert(failures, message)
  end
end

-- What DevHub would inject: records the calls.
local calls = { view = {}, inline = {}, notify = {}, decorate = {}, cleared = {} }
local core = { _chan = 1 }
function core.view(opts)
  table.insert(calls.view, opts)
  return { id = 1, buf = opts.buf, update = function() calls.view_updates = (calls.view_updates or 0) + 1 end }
end
function core.inline(opts)
  table.insert(calls.inline, opts)
  return {
    id = #calls.inline,
    clear = function()
      table.insert(calls.cleared, opts.id)
    end,
  }
end
function core.decorate(opts)
  table.insert(calls.decorate, opts)
  return { id = 9, clear = function() end }
end
function core.notify(opts)
  table.insert(calls.notify, opts)
end

-- 1. Outside DevHub: harmless.
local gui = require('devhub').gui
local ui = gui.ui
check(not gui.available(), 'available outside DevHub')
local h = gui.view { buf = 0, items = {} }
check(h and h.pending, 'a view outside DevHub is a pending handle')
h:update()
h:close()
check(gui.override_notify() == false, 'override_notify outside DevHub')

-- 2. Builders and validation.
local card = ui.card {
  accent = 'keyword',
  ui.hstack { ui.avatar 'claude', ui.text { { 'claude', bold = true } }, ui.badge('agent', { tone = 'keyword' }) },
  ui.md 'Yes — `os.Rename` is atomic',
  ui.hstack { ui.button('Reply', { key = 'r', on_click = function() end }), ui.spacer(), ui.pill(2, { tone = 'warn' }) },
  ui.progress(1.4),
  ui.checkbox 'mixed',
  ui.icon(0xf09b),
  ui.sparkline({ 1, 3, 2 }, { kind = 'bar' }),
  ui.chart { { values = { 1, 2 }, tone = 'ok', label = 'passed' } },
  'a plain string child',
}
check(card.type == 'stack' and card.card == true and #card.children == 9, 'card shape')
check(card.children[1].children[1].text == 'C', 'avatar initial')
check(card.children[4].value == 1, 'progress clamped')
check(card.children[6].glyph == vim.fn.nr2char(0xf09b), 'icon codepoint')
check(card.children[9].type == 'text', 'a string child is text')
check(ui.validate(card), 'a built card validates')
local ok, err = ui.validate { type = 'stack', children = { { type = 'badge' } } }
check(not ok and err:match 'badge needs a string text', 'validate names the bad node: ' .. tostring(err))
check(not pcall(ui.badge, 3 == 3 and {} or nil), 'badge refuses a table')
check(not pcall(ui.checkbox, 'maybe'), 'checkbox refuses a fourth state')
check(not pcall(gui.inline, { buf = 0, lnum = 1, component = { type = 'nope' } }), 'inline refuses a bad component')
local runs = ui.text({ 'a ', { 'b', tone = 'muted', mono = true } }, { size = 'sm' })
check(runs.runs[2].hl == 'muted' and runs.runs[2].mono and runs.size == 'sm', 'text runs')

-- 3. In DevHub: forwarded to the core.
vim.g.devhub_gui = true
package.loaded['devhub_gui'] = core
local handle = gui.view { buf = 0, items = function() return ui.text 'x' end }
check(#calls.view == 1 and handle.id == 1, 'view forwarded')
handle:update()
check(calls.view_updates == 1, 'a handle forwards its methods')
check(gui.override_notify() == true, 'override_notify in DevHub')
vim.notify('hello', vim.log.levels.WARN, { title = 'test' })
check(calls.notify[1] and calls.notify[1].msg == 'hello' and calls.notify[1].group == 'test', 'vim.notify forwarded')

-- 4. review-relay, against the fake CLI.
local fixtures = vim.fn.getcwd() .. '/tests/fixtures/review-relay'
local root = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(root .. '/internal/store', 'p')
local lines = {}
for i = 1, 20 do
  lines[i] = 'line ' .. i
end
vim.fn.writefile(lines, root .. '/internal/store/store.go')
local log = vim.env.RR_LOG or vim.fn.tempname()
vim.env.REVIEW_RELAY_TEST_LOG = log
vim.env.REVIEW_RELAY_TEST_ROOT = root
local rr = require('devhub.review_relay').setup {
  cmd = fixtures .. '/fake-review-relay',
  curl = fixtures .. '/fake-curl',
  endpoint = 'http://127.0.0.1:1',
}
local threads = rr.threads(vim.json.decode(table.concat(vim.fn.readfile(fixtures .. '/comments.json'), '\n')).comments)
check(#threads == 3, 'three threads')
check(threads[1].path == 'internal/server/events.go' and threads[1].status == 'waiting', 'waiting thread')
check(threads[2].status == 'answered' and #threads[2].comments == 2, 'answered thread')
check(threads[3].status == 'resolved', 'resolved thread')
check(rr.ago('2026-11-07T10:00:00Z', os.time { year = 2026, month = 11, day = 7, hour = 10, min = 12, isdst = false } + (os.time() - os.time(os.date '!*t'))) == '12 min ago', 'ago')

vim.cmd('cd ' .. root)
vim.cmd 'ReviewRelay'
local done = vim.wait(3000, function()
  return #rr._state.entries > 5
end)
check(done, 'the panel was drawn')
local panel = rr._state.panel
local text = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
local joined = table.concat(text, '\n')
check(joined:find('store.go:4–7 [AI replied]', 1, true), 'a thread line: ' .. joined)
check(joined:find('3 / 6 reviewed', 1, true) or joined:find('2 / 6 reviewed', 1, true), 'progress line')
check(calls.view[2] and calls.view[2].buf == panel.buf, 'the panel is a view')
local items = calls.view[2].items
for lnum = 1, #text do
  local node = items(lnum)
  check(node == nil or ui.validate(node), 'panel item ' .. lnum .. ' validates')
end
-- <Space> on store.go marks it reviewed at its hash.
local store_line
for i, e in ipairs(rr._state.entries) do
  if e.kind == 'file' and e.file.path == 'internal/store/store.go' then
    store_line = i
  end
end
vim.api.nvim_win_set_cursor(0, { store_line, 0 })
vim.api.nvim_feedkeys(vim.keycode and vim.keycode '<Space>' or ' ', 'x', false)
local function logged(pattern)
  return vim.wait(3000, function()
    local f = io.open(log)
    local t = f and f:read '*a' or ''
    if f then
      f:close()
    end
    return t:find(pattern, 1, true) ~= nil
  end)
end
check(logged 'curl PUT http://127.0.0.1:1/ui/reviewed' and logged '"hash":"h6"', 'reviewed PUT at the hash')
-- s on a thread resolves it through the CLI.
local thread_line
for i, e in ipairs(rr._state.entries) do
  if e.kind == 'thread' and e.thread.status == 'answered' then
    thread_line = i
  end
end
vim.api.nvim_win_set_cursor(0, { thread_line, 0 })
vim.api.nvim_feedkeys('s', 'x', false)
check(logged 'comments resolve 11111111-1111-4111-8111-111111111111', 'resolve via the CLI')

-- The file: threads become cards under their last line, signs on their lines.
vim.cmd 'wincmd p'
vim.cmd('edit ' .. root .. '/internal/store/store.go')
local buf = vim.api.nvim_get_current_buf()
check(vim.wait(2000, function()
  return #calls.inline >= 2
end), 'cards placed')
local by_lnum = {}
for _, c in ipairs(calls.inline) do
  if c.buf == buf then
    by_lnum[c.lnum] = c
  end
end
check(by_lnum[7] and by_lnum[7].range[1] == 4 and ui.validate(by_lnum[7].component), 'the answered card under line 7')
check(by_lnum[13] ~= nil, 'the resolved card under line 13')
local signs = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
check(#signs >= 5, 'signs on the thread lines')
-- r on a thread line replies (vim.ui.input), as a person: HTTP, source human.
vim.ui.input = function(_, cb)
  cb 'thanks!'
end
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.api.nvim_feedkeys('r', 'x', false)
check(logged '"source":"human"', 'a reply as the person')
check(logged 'thanks!', 'the reply body')
-- Elsewhere, r is r.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys('rX', 'x', false)
check(vim.api.nvim_get_current_line() == 'Xine 1', 'r outside a thread replaces a character')
rr.stop()

if #failures > 0 then
  io.stderr:write('FAIL\n  ' .. table.concat(failures, '\n  ') .. '\n')
  vim.cmd 'cquit 1'
end
io.stdout:write 'gui: ok\n'
vim.cmd 'qall!'
