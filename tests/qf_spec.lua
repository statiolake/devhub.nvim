-- nvim --headless: the quickfix and location-list windows as DevHub views,
-- over a stand-in for DevHub's `devhub_gui`: the list → rows mapping (one
-- row per qf line, a heading per file), the cursor and <CR>, and the
-- updates. Leaves Neovim with an error on failure.
local failures = {}
local function check(condition, message)
  if not condition then
    table.insert(failures, message)
  end
end

-- Text of a component tree, runs joined.
local function text_of(node, out)
  out = out or {}
  if type(node) ~= 'table' then
    return out
  end
  if node.type == 'text' then
    if node.text then
      table.insert(out, node.text)
    end
    local line = {}
    for _, r in ipairs(node.runs or {}) do
      table.insert(line, r.text)
    end
    if #line > 0 then
      table.insert(out, table.concat(line))
    end
  elseif node.type == 'badge' then
    table.insert(out, '[' .. node.text .. ']')
  end
  for _, child in ipairs(node.children or {}) do
    text_of(child, out)
  end
  return out
end
local function flat(node)
  return table.concat(text_of(node), ' ')
end
local function runs_of(node, out)
  out = out or {}
  if type(node) ~= 'table' then
    return out
  end
  for _, r in ipairs(node.runs or {}) do
    table.insert(out, r)
  end
  for _, child in ipairs(node.children or {}) do
    runs_of(child, out)
  end
  return out
end

-- 0. Outside DevHub: a qf window is Neovim's.
local qf = require 'devhub.qf'
vim.fn.setqflist({}, ' ', { title = 'outside', lines = { 'x.lua:1:1:a' }, efm = '%f:%l:%c:%m' })
vim.cmd 'copen'
qf.attach(0)
check(next(qf._attached) == nil, 'outside DevHub: no view')
vim.cmd 'cclose'

-- DevHub's GUI, as a stand-in that records the views.
vim.g.devhub_gui = true
local views = {}
local core = { _chan = 1 }
function core.view(opts)
  local v = { opts = opts, updates = 0, redraws = 0, closed = false }
  function v.update()
    v.updates = v.updates + 1
  end
  function v.redraw()
    v.redraws = v.redraws + 1
  end
  function v.close()
    v.closed = true
  end
  views[opts.buf] = v
  return { id = #vim.tbl_keys(views), buf = opts.buf, update = v.update, redraw = v.redraw, close = v.close }
end
package.loaded['devhub_gui'] = core
qf.install()

-- The world: two files.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. '/src', 'p')
local a = dir .. '/src/a.lua'
local b = dir .. '/b.lua'
vim.fn.writefile({ 'local needle = 1', '  return needle + 2', 'x' }, a)
vim.fn.writefile({ 'print(needle)' }, b)
vim.cmd.cd(dir)

-- 1. A grep's result (rg --vimgrep: a column, no end).
vim.fn.setqflist({}, ' ', {
  title = 'rg needle -g *.lua',
  efm = '%f:%l:%c:%m',
  lines = { 'src/a.lua:1:7:local needle = 1', 'src/a.lua:2:10:  return needle + 2', 'b.lua:1:7:print(needle)' },
})
vim.cmd 'copen'
local qbuf = vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr
local view = views[qbuf]
check(view ~= nil, ':copen: the qf buffer is a view')
check(view and view.opts.sticky_headings == true, 'its headings are held at the top')
check(view and view.opts.row_height == qf.ROW_HEIGHT, 'dense rows')
check(vim.api.nvim_buf_line_count(qbuf) == 3, 'Neovim still writes one line per item')

local function item(lnum)
  return view.opts.items(lnum, vim.api.nvim_buf_get_lines(qbuf, lnum - 1, lnum, false)[1])
end
local i1, i2, i3 = item(1), item(2), item(3)
check(i1 and i1.heading and flat(i1.heading):find('a.lua', 1, true), 'item 1: under its file\'s heading')
check(i1 and flat(i1.heading):find('src', 1, true), 'the heading says the directory')
check(i1 and flat(i1.heading):find('[2]', 1, true), 'and how many items: ' .. (i1 and flat(i1.heading) or ''))
check(i2 and i2.heading == nil, 'item 2: the same file, no heading')
check(i3 and i3.heading and flat(i3.heading):find('b.lua', 1, true), 'item 3: the next file\'s heading')
check(i3 and flat(i3.heading):find('[1]', 1, true), 'b.lua has one item')
check(i1 and flat(i1.node):find('1:7', 1, true), 'the position: ' .. (i1 and flat(i1.node) or ''))
check(i2 and flat(i2.node):find('2:10', 1, true), 'item 2 position')
-- the match from the title's pattern, at the column (the leading blanks gone)
local function marked(it)
  for _, r in ipairs(runs_of(it.node)) do
    if r.mark then
      return r.text
    end
  end
end
check(marked(i1) == 'needle', 'the match is marked: ' .. tostring(marked(i1)))
check(marked(i2) == 'needle', 'the match after leading blanks is marked: ' .. tostring(marked(i2)))
check(i1 and flat(i1.node):find('local needle = 1', 1, true), 'the text')
-- the current item marked, the others not
local function bar(it)
  return runs_of(it.node)[1] and runs_of(it.node)[1].text
end
check(bar(i1) == '▎' and bar(i2) == ' ', 'the current item is marked')

-- the title row
local header = flat(view.opts.header())
check(header:find('Quickfix', 1, true) and header:find('rg needle', 1, true), 'the title row: ' .. header)
check(header:find('[1 / 3]', 1, true), 'the position in the title row: ' .. header)

-- 2. The cursor and <CR>: a double click is <CR> on the line clicked.
local qwin = vim.fn.getqflist({ winid = 0 }).winid
vim.api.nvim_set_current_win(qwin)
vim.api.nvim_win_set_cursor(qwin, { 3, 0 })
view.opts.on_click(3, 1)
vim.api.nvim_feedkeys('', 'x', false)
check(vim.api.nvim_get_current_win() == qwin, 'a single click only moves the cursor')
local before, redraws = view.updates, view.redraws
view.opts.on_click(3, 2)
vim.api.nvim_feedkeys('', 'x', false)
check(vim.fn.expand '%:t' == 'b.lua', 'a double click jumps (<CR>): ' .. vim.fn.expand '%:t')
check(vim.fn.getqflist({ idx = 0 }).idx == 3, 'to that item')
-- the list's state changed with no change to the buffer: drawn again
qf.refresh()
check(view.updates > before and view.redraws > redraws, 'the current item moved: drawn again, the focus placed again')
-- (a draw asks for the lines in order, the first first)
local n1, n3 = item(1), item(3)
check(bar(n3) == '▎' and bar(n1) == ' ', 'the new current item is marked')
check(flat(view.opts.header()):find('[3 / 3]', 1, true), 'the title row follows')
before = view.updates
vim.cmd 'cfirst'
qf.refresh()
check(view.updates == before + 1, ':cfirst: drawn again')
item(1)
qf.refresh()
check(view.updates == before + 1, 'nothing changed: not drawn again')
-- a user mapping of <CR> in qf is what a double click runs
local mapped
vim.api.nvim_set_current_win(qwin)
vim.keymap.set('n', '<CR>', function()
  mapped = vim.fn.line '.'
end, { buffer = qbuf })
vim.api.nvim_win_set_cursor(qwin, { 2, 0 })
view.opts.on_click(2, 2)
vim.api.nvim_feedkeys('', 'x', false)
check(mapped == 2, 'your <CR> mapping runs: ' .. tostring(mapped))
vim.keymap.del('n', '<CR>', { buffer = qbuf })

-- 3. :vimgrep's items carry their end: the match from it.
vim.cmd 'silent vimgrep /return/j src/a.lua'
check(vim.api.nvim_buf_line_count(qbuf) == 1, 'the new list rewrote the buffer')
local v1 = item(1)
check(marked(v1) == 'return', ':vimgrep: the match from the end column: ' .. tostring(marked(v1)))
check(flat(view.opts.header()):find('list 3 of 3', 1, true), 'the title row says which list: ' .. flat(view.opts.header()))

-- 4. :colder / :cnewer: the buffer is the other list's, and so are the rows.
vim.cmd 'silent colder'
check(flat(item(1).heading):find('a.lua', 1, true) and item(3) ~= nil, ':colder: the grep again')
check(flat(view.opts.header()):find('list 2 of 3', 1, true), ':colder: the list before')
vim.cmd 'silent cnewer'
local c1 = item(1)
check(item(2) == nil and marked(c1) == 'return', ':cnewer: the vimgrep again')

-- 5. Diagnostics: the type as your signs, in their colour; a message in the UI's face.
vim.diagnostic.config { signs = { text = { [vim.diagnostic.severity.ERROR] = 'X', [vim.diagnostic.severity.WARN] = 'Y' } } }
vim.fn.setqflist({}, ' ', {
  title = 'Diagnostics',
  items = {
    { filename = a, lnum = 1, col = 7, end_col = 13, type = 'E', text = 'undefined global' },
    { filename = a, lnum = 3, col = 1, type = 'W', text = 'unused' },
    { filename = b, lnum = 1, col = 1, type = 'I', text = 'info here' },
  },
})
local d1, d2, d3 = item(1), item(2), item(3)
local function sign(it)
  for _, r in ipairs(runs_of(it.node)) do
    if r.hl and r.hl:match '^Diagnostic' then
      return r.text, r.hl
    end
  end
end
local t1, h1 = sign(d1)
check(t1 == 'X' and h1 == 'DiagnosticSignError', 'an error: your sign, its colour: ' .. tostring(t1) .. ' ' .. tostring(h1))
check(sign(d2) == 'Y', 'a warning: your sign')
check(sign(d3) == '\u{ea74}', 'info, with no sign of yours: the codicon')
check(marked(d1) == nil, 'a message has no match marked')
local mono = false
for _, r in ipairs(runs_of(d1.node)) do
  if r.text == 'undefined global' then
    mono = r.mono == true
  end
end
check(not mono, 'a message is in the UI\'s face')
-- vim.diagnostic.setqflist and its kin go the same way
vim.diagnostic.set(vim.api.nvim_create_namespace 'qf_spec', vim.fn.bufadd(a), {
  { lnum = 0, col = 6, message = 'from the diagnostics', severity = vim.diagnostic.severity.WARN },
})
vim.fn.bufload(vim.fn.bufadd(a))
vim.diagnostic.setqflist { open = false }
check(sign(item(1)) == 'Y' and flat(item(1).node):find('from the diagnostics', 1, true), 'vim.diagnostic.setqflist: ' .. flat(item(1).node))

-- 6. A line without a file stays in the group it follows.
vim.fn.setqflist({}, ' ', {
  title = ':make',
  efm = '%f:%l:%m,%-G%.%#',
  lines = { 'src/a.lua:1:boom', 'src/a.lua:2:again' },
})
vim.fn.setqflist({}, 'a', { items = { { text = '  more about it' }, { filename = a, lnum = 3, text = 'third' } } })
check(vim.api.nvim_buf_line_count(qbuf) == 4, 'four lines')
check(item(1).heading and item(3).heading == nil and item(4).heading == nil, 'a text line does not break the group')
check(flat(item(1).heading):find('[3]', 1, true), 'its file\'s items counted: ' .. flat(item(1).heading))
check(flat(item(3).node):find('more about it', 1, true), 'the text line drawn')

-- 7. A location list: a view of its own, called so.
vim.cmd 'wincmd p'
vim.fn.setloclist(0, {}, ' ', { title = 'refs', items = { { filename = b, lnum = 1, col = 7, end_col = 13, text = 'print(needle)' } } })
vim.cmd 'lopen'
local lbuf = vim.api.nvim_get_current_buf()
check(lbuf ~= qbuf and views[lbuf] ~= nil, ':lopen: its own view')
local lv = views[lbuf]
check(flat(lv.opts.header()):find('Location List', 1, true) and flat(lv.opts.header()):find('refs', 1, true), 'its title row: ' .. flat(lv.opts.header()))
check(marked(lv.opts.items(1, '')) == 'needle', 'an LSP reference\'s range is marked')
vim.cmd 'lclose'

-- 8. :cclose and :copen again: the same buffer, the same view.
vim.cmd 'cclose'
vim.cmd 'copen'
check(vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr == qbuf and views[qbuf] == view and not view.closed, ':copen again: the same view')
vim.cmd 'cclose'

-- 9. vim.g.devhub_native_qf = false: Neovim's cells.
vim.g.devhub_native_qf = false
vim.cmd 'new'
vim.fn.setloclist(0, {}, ' ', { title = 'off', items = { { filename = b, lnum = 1, text = 'x' } } })
vim.cmd 'lopen'
check(views[vim.api.nvim_get_current_buf()] == nil, 'opted out: no view')
vim.cmd 'lclose'
vim.g.devhub_native_qf = nil

-- 10. The pattern from a title.
local cases = {
  { 'rg needle -g *.lua', 'needle' },
  { 'rg --vimgrep -i "two words"', '"two' },
  { "rg -g '*.ts' foo", 'foo' },
  { 'ripgrep: needle (3)', 'needle' },
  { ':rg --vimgrep --smart-case needle', 'needle' },
  { ':grep -n -- -dash', '-dash' },
  { 'git grep -n thing', 'thing' },
  { 'Diagnostics', nil },
  { ':make', nil },
}
for _, c in ipairs(cases) do
  local got = qf.pattern_of(c[1])
  check(got == c[2], 'pattern_of(' .. c[1] .. ') = ' .. tostring(got))
end

if #failures > 0 then
  io.stderr:write('qf: FAIL\n  ' .. table.concat(failures, '\n  ') .. '\n')
  vim.cmd 'cquit 1'
else
  io.stdout:write 'qf: ok\n'
  vim.cmd 'qa!'
end
