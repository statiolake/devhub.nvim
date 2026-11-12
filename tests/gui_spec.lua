-- nvim --headless: the component builders and the GUI facade over a
-- stand-in for DevHub's `devhub_gui`. Leaves Neovim with an error on failure.
local failures = {}
local function check(condition, message)
  if not condition then
    table.insert(failures, message)
  end
end

-- What DevHub would inject: records the calls.
local calls = { view = {}, inline = {}, notify = {}, cleared = {} }
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
function core.notify(opts)
  table.insert(calls.notify, opts)
end
function core.history()
  return { { msg = 'kept' } }
end
function core.clear_history()
  calls.cleared_history = true
end
function core.notifications()
  calls.notifications = true
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
check(#gui.history() == 0, 'no history outside DevHub')
check(pcall(gui.notifications), 'notifications outside DevHub: :messages')
check(gui.popup { component = ui.md 'x' } == nil, 'a popup outside DevHub is nil')
check(gui.statusline(function() end) == false, 'statusline outside DevHub: nothing')
check(not gui.has_statusline(), 'no footers outside DevHub')
check(not gui.has_cmdline_popup(), 'no command-line popups outside DevHub')
check(not pcall(gui.statusline, 42), 'statusline takes a function, a choice or nil')
check(not pcall(gui.statusline, nil, { events = 'BufAdd' }), 'statusline events are a list')
-- The LSP float hook leaves Neovim's own float outside DevHub.
gui.hook_floats()
local util = vim.lsp.util
local obuf, owin = util.open_floating_preview({ '# hi' }, 'markdown', {})
check(vim.api.nvim_win_is_valid(owin) and not vim.api.nvim_win_get_config(owin).hide, 'outside DevHub: Neovim\'s float')
check(vim.api.nvim_buf_get_lines(obuf, 0, -1, false)[1] ~= nil, 'its buffer')
vim.api.nvim_win_close(owin, true)

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

-- A list, a pane, a small badge, an anchored node.
local list = ui.stack {
  selected = 2, band = 'PmenuSel',
  ui.hstack { ui.badge('f', { size = 'sm', hl = 'Function' }), ui.text('useState', { anchor = true, mono = true }) },
  ui.hstack { ui.badge('v', { size = 'sm' }), ui.text 'user' },
}
check(list.selected == 2 and list.band == 'PmenuSel' and #list.children == 2, 'a list: selected and band')
check(list.children[1].children[1].size == 'sm', 'a small badge')
check(list.children[1].children[2].anchor == true, 'an anchored node')
local pane = ui.stack { pane = 'doc', max_height = 240, ui.md 'doc' }
check(pane.pane == 'doc' and pane.max_height == 240, 'a pane')
check(ui.validate(ui.stack { list, pane }), 'a list and a pane validate')
check(not pcall(ui.stack, { selected = 'two' }), 'selected is a number')
check(not pcall(ui.stack, { pane = 1 }), 'a pane is named')
check(not pcall(ui.text, 'x', { anchor = 'yes' }), 'anchor is a boolean')

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
check(gui.history()[1].msg == 'kept', 'history forwarded')
gui.clear_history()
check(calls.cleared_history, 'clear_history forwarded')
vim.cmd 'Notifications'
check(calls.notifications, ':Notifications opens DevHub\'s pager')

-- Footers: forwarded to a DevHub that has them; a DevHub from before them
-- (no core.statusline) leaves Neovim's cells.
check(gui.statusline(function() end) == false and not gui.has_statusline(), 'an older DevHub: no footers')
local footer_calls = {}
function core.statusline(fn, opts)
  table.insert(footer_calls, { fn = fn, opts = opts })
end
function core.statusline_refresh()
  calls.refreshed = true
end
local stl = function(_, ctx)
  return ui.hstack { align = 'center', ui.line { grow = true }, ui.hstack { bg = 'Pmenu', pad = { 0, 6 }, round = true, ui.text 'a.ts' } }
end
check(gui.statusline(stl, { events = { 'BufAdd' } }) == true and gui.has_statusline(), 'statusline handed to DevHub')
check(footer_calls[1] and footer_calls[1].fn == stl and footer_calls[1].opts.events[1] == 'BufAdd', 'statusline forwarded')
check(gui.statusline 'default' and footer_calls[2].fn == 'default', "statusline('default') forwarded")
gui.statusline_refresh()
check(calls.refreshed, 'statusline_refresh forwarded')
local tree = stl(1, {})
check(ui.validate(tree), 'a footer tree validates')
check(tree.children[1].type == 'line' and tree.children[2].round == true, 'line and a round chip')
check(ui.position({ format = 'Ln %l' }).slot == 'position' and ui.mode().slot == 'mode' and ui.showcmd().slot == 'showcmd', 'slots')
check(not ui.validate { type = 'slot', slot = 'clock' }, 'an unknown slot is wrong')
check(not pcall(ui.hstack, { round = 'yes' }), 'round is a boolean')

-- A framed view: its parts checked, then forwarded.
calls.view = {}
local framed = gui.view { buf = 0, win = 2, items = function() end, frame = { win = 1, title = ui.badge 'Files' } }
check(#calls.view == 1 and calls.view[1].frame.win == 1 and framed.id == 1, 'a framed view forwarded')
check(not pcall(gui.view, { buf = 0, frame = { win = 1, title = { type = 'nope' } } }), 'a frame\'s bad title is an error')
check(not pcall(gui.view, { buf = 0, frame = {} }), 'a frame needs its window')

-- A tree: items as { node, depth, sticky } are checked by their node.
calls.view = {}
gui.view { buf = 0, indent = 16, row_height = 22, items = { [1] = { node = ui.text 'root', sticky = true, depth = 0 }, [2] = { node = ui.text 'a', depth = 1 } } }
check(#calls.view == 1 and calls.view[1].indent == 16 and calls.view[1].row_height == 22, 'a tree view forwarded')
check(not pcall(gui.view, { buf = 0, items = { [1] = { node = { type = 'nope' }, depth = 1 } } }), 'a tree item\'s bad node is an error')

-- LSP floats as popups: hover, signature help, diagnostics.
calls.popup = {}
local function fake_popup(opts)
  local p = { opts = opts, open = true, focused = 0, updates = 0 }
  table.insert(calls.popup, p)
  local h = { id = #calls.popup }
  function h.is_open() return p.open end
  function h.close()
    if p.open then
      p.open = false
      if opts.on_close then opts.on_close(h) end
    end
  end
  function h.focus() p.focused = p.focused + 1 end
  function h.update(component) p.updates = p.updates + 1; p.component = component end
  return h
end
core.popup = fake_popup
local lp = gui.popup { component = ui.stack { list, pane }, min_width = 36, close_on = {} }
check(lp and calls.popup[1].opts.min_width == 36, 'min_width forwarded')
check(calls.popup[1].opts.component.children[1].band == 'PmenuSel', 'the list forwarded')
check(not gui.has_cmdline_popup(), 'a DevHub before command-line popups')
core.popup_cmdline = true
check(gui.has_cmdline_popup(), 'a DevHub that puts popups on its command line')
local cp = gui.popup { anchor = { cmdline = 3 }, component = ui.text 'x' }
check(cp and calls.popup[#calls.popup].opts.anchor.cmdline == 3, 'the command-line anchor forwarded')
calls.popup = {}
local hover = { '```python', '(method) def detect() -> Literal[...]', '```', '', 'Detect the platform.' }
local pbuf, pwin = util.open_floating_preview(hover, 'markdown', { focus_id = 'textDocument/hover', max_width = 60 })
local first = calls.popup[1]
check(first and first.opts.component.type == 'markdown', 'hover is a popup of markdown')
check(first and first.opts.component.text:find('def detect', 1, true), 'with the hover text')
check(first and first.opts.max_width == 60, 'max sizes kept')
check(vim.api.nvim_win_is_valid(pwin) and vim.api.nvim_win_get_config(pwin).hide == true, 'a hidden window answers')
check(vim.api.nvim_buf_get_lines(pbuf, 0, 1, false)[1] == '```python', 'its buffer has the lines')
-- K K: into the popup, not a second one.
local again_buf = util.open_floating_preview(hover, 'markdown', { focus_id = 'textDocument/hover' })
check(#calls.popup == 1 and first.focused == 1 and again_buf == pbuf, 'asked again: focused')
-- Its caller closing the window closes the popup.
vim.api.nvim_win_close(pwin, true)
check(not first.open, 'the window closed: the popup closed')
-- A diagnostic float: plain text in the colours its caller gives the buffer.
local dbuf = util.open_floating_preview({ 'Diagnostics:', '1. undefined name' }, 'plaintext', { focus_id = 'cursor' })
vim.api.nvim_buf_set_extmark(dbuf, vim.api.nvim_create_namespace '', 1, 3, { end_col = 17, hl_group = 'DiagnosticError' })
local diag = calls.popup[2]
check(vim.wait(1000, function() return diag and diag.updates > 0 end), 'the diagnostic popup coloured')
local runs = diag and diag.component and diag.component.children[2].runs or {}
check(runs[2] and runs[2].hl == 'DiagnosticError' and runs[2].text == 'undefined name', 'a run in the diagnostic colour')
check(ui.validate(diag.component), 'the diagnostic component validates')
diag.opts.on_close()
-- A popup that fails: Neovim's float after all.
core.popup = function() error 'boom' end
local _, fwin = util.open_floating_preview({ 'x' }, 'markdown', {})
check(vim.api.nvim_win_is_valid(fwin) and not vim.api.nvim_win_get_config(fwin).hide, 'an error: Neovim\'s float')
vim.api.nvim_win_close(fwin, true)
core.popup = fake_popup

-- vim.ui.select / input: forwarded to DevHub's quick pick when it is there,
-- installed over what was there, and that kept for outside DevHub.
do
  local asked
  core.select = function(items, _, on_choice)
    asked = items
    on_choice(items[2], 2)
  end
  core.input = function(_, on_confirm)
    on_confirm('typed')
  end
  local before = vim.ui.select
  gui.quick_pick()
  check(vim.ui.select == gui.select and gui._ui_select == before, 'quick_pick installs vim.ui.select')
  local got
  vim.ui.select({ 'a', 'b' }, {}, function(item, idx)
    got = { item, idx }
  end)
  check(asked and got and got[1] == 'b' and got[2] == 2, 'select goes to the quick pick')
  local text
  vim.ui.input({}, function(t)
    text = t
  end)
  check(text == 'typed', 'input goes to the quick pick')
end

if #failures > 0 then
  io.stderr:write('FAIL\n  ' .. table.concat(failures, '\n  ') .. '\n')
  vim.cmd 'cquit 1'
end
io.stdout:write 'gui: ok\n'
vim.cmd 'qall!'
