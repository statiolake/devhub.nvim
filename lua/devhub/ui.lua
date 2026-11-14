-- require('devhub').gui.ui: declarative components for DevHub's GUI.
--
-- A component is data — a table with a `type` — that DevHub draws in its own
-- type with Neovim's colours: every colour is a highlight group's name (or a
-- tone, which names one), resolved by Neovim. There is no HTML and no
-- JavaScript in it; `on_click = function() … end` on any node runs in Neovim
-- when the node is clicked. These builders check their arguments and fill in
-- the shape; `validate` checks a tree made by hand.
--
--   local ui = require('devhub').gui.ui
--   ui.card {
--     accent = 'keyword',
--     ui.hstack { ui.avatar 'claude', ui.text { { 'claude', bold = true } }, ui.badge('agent', { tone = 'keyword' }) },
--     ui.md 'Yes — `os.Rename` is atomic, but …',
--     ui.hstack { ui.button('Reply', { key = 'r', on_click = reply }), ui.spacer(), ui.button('Resolve', { key = 's', tone = 'ok' }) },
--   }

local M = {}

--- Tones a node may name instead of a group (DevHub maps them to groups).
M.tones = {
  'info', 'warn', 'error', 'ok', 'hint', 'muted', 'accent', 'special', 'keyword', 'string', 'title',
  'added', 'changed', 'removed',
}

local TYPES = {
  stack = true, hstack = true, text = true, markdown = true, badge = true, kbd = true, button = true,
  checkbox = true, progress = true, icon = true, avatar = true, spacer = true, divider = true,
  sparkline = true, chart = true, image = true, line = true, slot = true,
}

local function fail(where, message)
  error('devhub.ui.' .. where .. ': ' .. message, 3)
end

local function check(where, value, kind, name, optional)
  if value == nil and optional ~= false then
    return
  end
  if type(value) ~= kind then
    fail(where, name .. ' must be a ' .. kind .. ', not ' .. type(value))
  end
end

-- The options every node takes, copied from opts into node.
-- anchor = true: in a popup, the node lined up with the anchor's column.
local COMMON = {
  on_click = 'function', grow = 'boolean', tip = 'string', hl = 'string', tone = 'string', anchor = 'boolean',
}

local function with(where, node, opts, fields)
  opts = opts or {}
  if type(opts) ~= 'table' then
    fail(where, 'options must be a table')
  end
  for key, kind in pairs(COMMON) do
    check(where, opts[key], kind, key)
    if opts[key] ~= nil then
      node[key] = opts[key]
    end
  end
  for key, kind in pairs(fields or {}) do
    check(where, opts[key], kind, key)
    if opts[key] ~= nil then
      node[key] = opts[key]
    end
  end
  return node
end

local CONTAINER = {
  gap = 'number', pad = nil, align = 'string', justify = 'string', wrap = 'boolean', card = 'boolean',
  accent = 'string', bg = 'string', indent = 'number', round = 'boolean',
  -- a list: the selected child (1-based) with one band behind it, in band's ground
  selected = 'number', band = 'string',
  -- a pane: scrolls inside past max_height (pixels); popup:scroll(by, pane)
  pane = 'string', max_height = 'number',
}

local function container(kind)
  return function(t)
    local where = kind
    check(where, t, 'table', 'the argument', false)
    local node = { type = kind, children = {} }
    for _, child in ipairs(t.children or t) do
      if type(child) == 'string' then
        child = { type = 'text', text = child }
      end
      if type(child) ~= 'table' or not TYPES[child.type] then
        fail(where, 'a child is not a component: ' .. vim.inspect(child):sub(1, 60))
      end
      table.insert(node.children, child)
    end
    for key, kind2 in pairs(CONTAINER) do
      check(where, t[key], kind2, key)
      node[key] = t[key]
    end
    if t.pad ~= nil then
      local ok = type(t.pad) == 'number' or (type(t.pad) == 'table' and type(t.pad[1]) == 'number' and type(t.pad[2]) == 'number')
      if not ok then
        fail(where, 'pad must be a number or { vertical, horizontal }')
      end
      node.pad = t.pad
    end
    return with(where, node, t)
  end
end

--- A column of components: ui.stack{ gap = 4, a, b, c }.
--- A list: ui.stack{ selected = 2, band = 'PmenuSel', row1, row2 } — one band
--- behind the selected row, gliding to the next (a popup's :select(n) moves
--- it without sending the tree). A pane: ui.stack{ pane = 'doc',
--- max_height = 240, … } scrolls inside past max_height pixels, by the wheel
--- or by its popup's :scroll(by, 'doc').
M.stack = container 'stack'
--- A row of components: ui.hstack{ gap = 6, align = 'center', a, b }.
M.hstack = container 'hstack'

--- A raised card (a column): ui.card{ accent = 'warn', a, b }.
function M.card(t)
  check('card', t, 'table', 'the argument', false)
  local node = M.stack(t)
  node.card = true
  node.pad = node.pad or { 8, 12 }
  node.gap = node.gap or 6
  return node
end

-- mark: a mark over the text (a search's match), on its group's ground.
local RUN = { hl = 'string', tone = 'string', mono = 'boolean', bold = 'boolean', italic = 'boolean',
  dim = 'boolean', strike = 'boolean', underline = 'boolean', mark = 'boolean' }

--- Text: ui.text('plain', opts), or runs: ui.text{ 'a ', { 'b', hl = 'Comment', mono = true }, size = 'sm' }.
--- opts: size = 'xs' | 'sm' | 'md' | 'lg', mono, bold, dim, wrap, upper, hl | tone,
--- ink (only hl's colour, not its weight or slant).
function M.text(value, opts)
  local where = 'text'
  local fields = { size = 'string', mono = 'boolean', bold = 'boolean', dim = 'boolean', wrap = 'boolean',
    upper = 'boolean', ink = 'boolean' }
  if type(value) == 'string' or type(value) == 'number' then
    return with(where, { type = 'text', text = tostring(value) }, opts, fields)
  end
  check(where, value, 'table', 'the text', false)
  local runs = {}
  for _, r in ipairs(value) do
    if type(r) == 'string' then
      table.insert(runs, { text = r })
    elseif type(r) == 'table' then
      local text = r.text or r[1]
      check(where, text, 'string', 'a run\'s text', false)
      local run = { text = text }
      for key, kind in pairs(RUN) do
        check(where, r[key], kind, key)
        run[key] = r[key]
      end
      if run.tone and not run.hl then
        run.hl, run.tone = run.tone, nil
      end
      table.insert(runs, run)
    else
      fail(where, 'a run must be a string or a table')
    end
  end
  local options = {}
  for key, v in pairs(value) do
    if type(key) == 'string' then
      options[key] = v
    end
  end
  for key, v in pairs(opts or {}) do
    options[key] = v
  end
  return with(where, { type = 'text', runs = runs }, options, fields)
end

--- Markdown, drawn as DevHub draws a hover: ui.md('**bold** and `code`').
--- opts.marks: ranges of its fenced code in a group's colours, each
--- { line = <1-based line of text>, from = <utf-16 col>, to = <utf-16 col>,
--- hl = 'Group' } (an LSP signature's active parameter).
function M.md(text, opts)
  check('md', text, 'string', 'the text', false)
  return with('md', { type = 'markdown', text = text }, opts, { size = 'string', marks = 'table' })
end
M.markdown = M.md

--- A badge: ui.badge('agent', { tone = 'keyword' }); pill = true for a count;
--- size = 'sm' | 'xs' for a small one in a dense row (a list's kind).
function M.badge(text, opts)
  if type(text) == 'number' then
    text = tostring(text)
  end
  check('badge', text, 'string', 'the text', false)
  return with('badge', { type = 'badge', text = text }, opts, { pill = 'boolean', mono = 'boolean', size = 'string' })
end

--- A count in a pill: ui.pill(2, { tone = 'warn' }).
function M.pill(n, opts)
  local node = M.badge(tostring(n), opts)
  node.pill = true
  return node
end

--- A key cap: ui.kbd('r'), ui.kbd('<C-v>') (shown as a Mac writes it: ⌃V).
function M.kbd(text)
  check('kbd', text, 'string', 'the key', false)
  return { type = 'kbd', text = text }
end

--- A button: ui.button('Resolve', { key = 's', tone = 'ok', icon = '', on_click = fn }).
function M.button(text, opts)
  check('button', text, 'string', 'the label', false)
  return with('button', { type = 'button', text = text }, opts, { key = 'string', icon = 'string' })
end

--- A checkbox: ui.checkbox(true | false | 'mixed', { label = '…' }).
function M.checkbox(state, opts)
  if state ~= true and state ~= false and state ~= 'mixed' and state ~= nil then
    fail('checkbox', "state must be true, false or 'mixed'")
  end
  return with('checkbox', { type = 'checkbox', state = state == nil and false or state }, opts, { label = 'string' })
end

--- A progress bar: ui.progress(0.56, { label = '5 / 9 reviewed', tone = 'accent' }).
function M.progress(value, opts)
  check('progress', value, 'number', 'the value', false)
  return with('progress', { type = 'progress', value = math.max(0, math.min(1, value)) }, opts,
    { label = 'string', width = 'number' })
end

--- An icon: a glyph or a codepoint (a Nerd Font one is drawn in the grid's font).
function M.icon(glyph, opts)
  if type(glyph) == 'number' then
    glyph = vim.fn.nr2char(glyph)
  end
  check('icon', glyph, 'string', 'the glyph', false)
  return with('icon', { type = 'icon', glyph = glyph }, opts, { size = 'string' })
end

--- An avatar: the initial of a name in a disc: ui.avatar('statiolake', { tone = 'info' }).
function M.avatar(name, opts)
  check('avatar', name, 'string', 'the name', false)
  opts = opts or {}
  local text = opts.text or vim.fn.toupper(vim.fn.strcharpart(name, 0, 1))
  local node = with('avatar', { type = 'avatar', text = text, tip = name }, opts, { size = 'number' })
  node.text = text
  return node
end

--- Room: a fixed number of pixels, or (with none) all that is left.
function M.spacer(size)
  check('spacer', size, 'number', 'the size')
  return { type = 'spacer', size = size }
end

--- A hairline: ui.divider(), or ui.divider{ vertical = true }.
function M.divider(opts)
  return with('divider', { type = 'divider' }, opts, { vertical = 'boolean' })
end

local function numbers(where, values)
  check(where, values, 'table', 'the values', false)
  for _, v in ipairs(values) do
    if type(v) ~= 'number' then
      fail(where, 'the values must be numbers')
    end
  end
  return values
end

--- A sparkline: ui.sparkline({ 3, 5, 2, 8 }, { kind = 'bar', tone = 'ok', width = 64, height = 16 }).
function M.sparkline(values, opts)
  local node = with('sparkline', { type = 'sparkline', values = numbers('sparkline', values) }, opts,
    { kind = 'string', width = 'number', height = 'number' })
  node.kind = node.kind or 'line'
  return node
end

--- A small line chart: ui.chart({ { values = {…}, tone = 'ok', label = 'passed' }, … }, { width = 240, height = 64 }).
function M.chart(series, opts)
  check('chart', series, 'table', 'the series', false)
  local list = {}
  for _, s in ipairs(series) do
    check('chart', s, 'table', 'a series', false)
    table.insert(list, { values = numbers('chart', s.values or s), hl = s.hl or s.tone, label = s.label })
  end
  return with('chart', { type = 'chart', series = list }, opts, { width = 'number', height = 'number' })
end

--- An image: a path on this Neovim's machine, an https URL or a data URL.
function M.image(src, opts)
  check('image', src, 'string', 'the source', false)
  return with('image', { type = 'image', src = src }, opts, { width = 'number', height = 'number' })
end

--- A line through the middle of the row (a footer's `─`), in its group's
--- foreground: ui.line{ grow = true, hl = 'StatusLine' }. In a footer it is
--- at the height of the window boundaries' lines, so one ending beside it
--- meets it.
function M.line(opts)
  return with('line', { type = 'line' }, opts)
end

local function slot(kind, fields)
  return function(opts)
    return with(kind, { type = 'slot', slot = kind }, opts, fields)
  end
end

--- Values DevHub fills from Neovim's own redraw at every key, so no Lua
--- runs for them (in a gui.statusline footer, of its window):
--- ui.position{ format = 'Ln %l, Col %c' } — the cursor (%l line, %c
--- column, %L lines, %p percent); ui.mode{} — the mode (NORMAL, INSERT,
--- …); ui.showcmd{} — the pending command.
M.position = slot('position', { format = 'string', ink = 'boolean' })
M.mode = slot('mode', { ink = 'boolean' })
M.showcmd = slot('showcmd', { ink = 'boolean' })

--- Check a tree made by hand: answers true, or false and what is wrong where.
function M.validate(node, path)
  path = path or 'root'
  if type(node) == 'string' then
    return true
  end
  if type(node) ~= 'table' then
    return false, path .. ': a component is a table or a string'
  end
  if not TYPES[node.type] then
    return false, path .. ': unknown type ' .. tostring(node.type)
  end
  if node.on_click ~= nil and type(node.on_click) ~= 'function' then
    return false, path .. ': on_click must be a function'
  end
  local need = {
    markdown = 'text', badge = 'text', kbd = 'text', button = 'text', avatar = 'text', image = 'src',
    icon = 'glyph',
  }
  if need[node.type] and type(node[need[node.type]]) ~= 'string' then
    return false, path .. ': ' .. node.type .. ' needs a string ' .. need[node.type]
  end
  if node.type == 'slot' and node.slot ~= 'position' and node.slot ~= 'mode' and node.slot ~= 'showcmd' then
    return false, path .. ': slot must be position, mode or showcmd'
  end
  if node.type == 'progress' and type(node.value) ~= 'number' then
    return false, path .. ': progress needs a number value'
  end
  if node.type == 'stack' or node.type == 'hstack' then
    for index, child in ipairs(node.children or node) do
      local ok, err = M.validate(child, path .. '.' .. node.type .. '[' .. index .. ']')
      if not ok then
        return false, err
      end
    end
  end
  return true
end

return M
