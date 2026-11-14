-- The quickfix and location-list windows drawn natively in DevHub's GUI.
--
-- Neovim keeps everything: the window, the buffer and its lines, the keys
-- (`<CR>`, your qf mappings and ftplugin), `:copen`/`:cnext`/`:colder`/
-- `:cdo`, `quickfixtextfunc` and every plugin that fills a list. Only the
-- drawing changes: the qf buffer becomes a `gui.view` — one row per buffer
-- line, so the cursor, `/`, `5j` and `<CR>` are Neovim's own on the same
-- line — painted over each window that shows it. The rows are made from the
-- list itself (`getqflist`/`getloclist`), not from the lines:
--
--   * a run of items in one file is a group: a heading above its first
--     item (the file's icon, its name, its directory dimmed, how many
--     items), held at the top while the group scrolls. A heading is not a
--     line (DevHub draws it above the item, outside its focus), so line N
--     is still item N;
--   * an item is its position, its type as the diagnostic sign your config
--     uses (E/W/I/N) in its colour, and its text — code in the grid's face
--     with the match marked for a grep's or a reference's item, a message
--     in the UI's face;
--   * the list's current item (`:cc`, `:cnext`) is marked; the title row
--     says the list's title, which of the lists it is and the position.
--
-- A double click is `<CR>` there (your mapping, else Neovim's). Outside
-- DevHub's GUI, or with `vim.g.devhub_native_qf = false`, nothing changes.

local M = {}

M.ROW_HEIGHT = 22
M.GAP = 6
-- The room before an item under its file's heading, in pixels.
M.INDENT = 14

-- buf -> { view = handle }
local attached = {}
-- buf -> the list as last read (M.snapshot)
local snapshots = {}

local function ui()
  return require('devhub.gui').ui
end

--- Whether the qf windows are drawn natively (`vim.g.devhub_native_qf`).
function M.active()
  return vim.g.devhub_native_qf ~= false
end

-- Which list a qf buffer shows: 0 for the quickfix list, a window for a
-- location list (its own window, or the window it is for), nil for none.
local function list_of(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    if info and info.quickfix == 1 then
      return info.loclist == 1 and win or 0
    end
  end
  if vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr == buf then
    return 0
  end
  return nil
end
M._list_of = list_of

local function get(which, what)
  if which == 0 then
    return vim.fn.getqflist(what)
  end
  return vim.fn.getloclist(which, what)
end

-- The list's state that decides what is drawn, cheap to read: compared at
-- every SafeState, so a `:cnext` (no change to the buffer) is drawn too.
local function state_of(which)
  local s = get(which, { id = 0, changedtick = 0, idx = 0, title = 0, nr = 0 })
  return table.concat({ tostring(s.id), tostring(s.changedtick), tostring(s.idx), tostring(s.nr), s.title or '' }, '\0')
end

-- A grep's pattern from the list's title, for the items that give only
-- where a match starts (rg --vimgrep): `rg foo -g '*.lua'`, `ripgrep: foo
-- (3)` (qfwatch), `:rg --vimgrep foo` (:grep). Checked against the text at
-- the item's column, so a wrong guess marks nothing.
function M.pattern_of(title)
  if type(title) ~= 'string' or title == '' then
    return nil
  end
  local p = title:match '^ripgrep: (.-) %(%d+%)$'
  if p then
    return p
  end
  local cmd = title:gsub('^:', '')
  local prog = cmd:match '^(%S+)'
  if not prog then
    return nil
  end
  local base = vim.fn.fnamemodify(prog, ':t')
  if not (base == 'rg' or base == 'grep' or base == 'ag' or base == 'ack' or base == 'git') then
    return nil
  end
  -- The first argument that is not an option (nor the value of one that
  -- takes it), unquoted.
  local words = vim.split(cmd, '%s+', { trimempty = true })
  local takes = { ['-g'] = true, ['--glob'] = true, ['-t'] = true, ['--type'] = true, ['-T'] = true }
  local function unquote(w)
    return (w:gsub([[^(['"])(.*)%1$]], '%2'))
  end
  local i = base == 'git' and 3 or 2
  while i <= #words do
    local w = words[i]
    if w == '--' or w == '-e' or w == '--regexp' then
      return words[i + 1] and unquote(words[i + 1]) or nil
    elseif takes[w] then
      i = i + 2
    elseif w:sub(1, 1) == '-' then
      i = i + 1
    else
      return unquote(w)
    end
  end
  return nil
end

--- The list a qf buffer shows, read once per change: { which, loclist,
--- title, idx, size, nr, last, items, group = { [i] = first item of i's
--- group }, count = { [first] = files' items in it }, pattern, lines_match }.
function M.snapshot(buf)
  local which = list_of(buf)
  if which == nil then
    return snapshots[buf]
  end
  local key = state_of(which) .. '\0' .. tostring(vim.api.nvim_buf_get_changedtick(buf)) .. '\0' .. tostring(which)
  local snap = snapshots[buf]
  if snap and snap.key == key then
    return snap
  end
  local info = get(which, { id = 0, items = 0, title = 0, idx = 0, nr = 0, size = 0, context = 0 })
  local last = get(which, { nr = '$' }).nr or 0
  local items = info.items or {}
  snap = {
    key = key,
    which = which,
    loclist = which ~= 0,
    title = info.title or '',
    idx = info.idx or 0,
    size = info.size or #items,
    nr = info.nr or 0,
    last = last,
    items = items,
    group = {},
    count = {},
    width = 0,
    pattern = M.pattern_of(info.title),
  }
  -- Line N is item N: Neovim writes one line per item (an empty list is
  -- one empty line). Otherwise (a plugin wrote lines of its own into the
  -- buffer) the lines are drawn as they are.
  local lines = vim.api.nvim_buf_line_count(buf)
  snap.lines_match = lines == #items or (#items == 0 and lines == 1)
  -- Groups: a run of items in one file; a line without a file (a
  -- compiler's continuation) stays in the group it follows.
  local first, bufnr
  for i, item in ipairs(items) do
    if item.bufnr and item.bufnr > 0 then
      if item.bufnr ~= bufnr then
        first, bufnr = i, item.bufnr
        snap.count[first] = 0
      end
      snap.count[first] = snap.count[first] + 1
    end
    snap.group[i] = first
  end
  -- The widest position, so the positions line up down the list.
  snap.width = 0
  for _, item in ipairs(items) do
    snap.width = math.max(snap.width, #M.position(item))
  end
  snapshots[buf] = snap
  -- What is drawn now: M.refresh draws again when the list moves on from it.
  if attached[buf] then
    attached[buf].state = state_of(which)
  end
  return snap
end

--- An item's position as drawn: `12:5`, `12`, or '' (none).
function M.position(item)
  if not item.lnum or item.lnum <= 0 then
    return ''
  end
  if item.col and item.col > 0 then
    return ('%d:%d'):format(item.lnum, item.col)
  end
  return tostring(item.lnum)
end

-- What an item's type is, as vim.diagnostic names it.
local SEVERITY = { E = 'ERROR', W = 'WARN', I = 'INFO', N = 'HINT', H = 'HINT' }
local GROUP = { ERROR = 'Error', WARN = 'Warn', INFO = 'Info', HINT = 'Hint' }
-- Codicons (DevHub ships them), where your config has no sign of its own.
local CODICON = { ERROR = '\u{ea87}', WARN = '\u{ea6c}', INFO = '\u{ea74}', HINT = '\u{ea61}' }

--- The type's sign as your diagnostics draw it: { text, hl } or nil.
function M.sign(kind)
  local name = SEVERITY[(kind or ''):upper()]
  if not name then
    return nil
  end
  local severity = vim.diagnostic.severity[name]
  local text
  local ok, config = pcall(vim.diagnostic.config)
  local signs = ok and type(config) == 'table' and config.signs or nil
  if type(signs) == 'function' then
    signs = nil
  end
  if type(signs) == 'table' and type(signs.text) == 'table' then
    text = signs.text[severity] or signs.text[name]
  end
  if type(text) ~= 'string' or vim.trim(text) == '' then
    text = CODICON[name]
  end
  local group = 'DiagnosticSign' .. GROUP[name]
  if vim.fn.hlexists(group) == 0 then
    group = 'Diagnostic' .. GROUP[name]
  end
  return { text = vim.trim(text), hl = group }
end

--- The match in an item's text as drawn (leading blanks gone): first and
--- last byte (1-based), or nil. From the item's end column when it has one
--- on its line (`:vimgrep`, LSP references), else from the list's pattern
--- found at its column.
function M.match(item, text, lead, pattern)
  if (item.type or '') ~= '' or item.vcol == 1 or not item.col or item.col <= 0 then
    return nil
  end
  local s, e
  local same_line = not item.end_lnum or item.end_lnum == 0 or item.end_lnum == item.lnum
  if same_line and item.end_col and item.end_col > item.col then
    s, e = item.col - lead, item.end_col - 1 - lead
  elseif pattern and pattern ~= '' then
    s = item.col - lead
    e = s + #pattern - 1
    if text:sub(s, e):lower() ~= pattern:lower() then
      return nil
    end
  else
    return nil
  end
  if s < 1 or e < s or e > #text then
    return nil
  end
  return s, e
end

-- A file's icon: nvim-web-devicons', else mini.icons', else a codicon.
local function file_icon(path)
  local name = vim.fn.fnamemodify(path, ':t')
  local ok, devicons = pcall(require, 'nvim-web-devicons')
  if ok and devicons.get_icon then
    local icon, hl = devicons.get_icon(name, vim.fn.fnamemodify(name, ':e'), { default = true })
    if icon then
      return icon, hl
    end
  end
  local mini = rawget(_G, 'MiniIcons')
  if mini and mini.get then
    local okm, icon, hl = pcall(mini.get, 'file', name)
    if okm and icon then
      return icon, hl
    end
  end
  return '\u{ea7b}', 'Comment'
end

local function heading(snap, first)
  local u = ui()
  local item = snap.items[first]
  local path = vim.fn.bufname(item.bufnr)
  if path == '' then
    path = item.module ~= '' and item.module or ('#' .. item.bufnr)
  end
  path = vim.fn.fnamemodify(path, ':~:.')
  local name, dir = vim.fn.fnamemodify(path, ':t'), vim.fn.fnamemodify(path, ':h')
  local icon, icon_hl = file_icon(path)
  return u.hstack {
    gap = 8,
    align = 'center',
    u.text({ { vim.trim(icon), hl = icon_hl, mono = true } }, { mono = true }),
    u.text({ { name, bold = true }, { (dir ~= '.' and dir ~= '') and ('  ' .. dir) or '', dim = true } }, { grow = true }),
    u.badge(tostring(snap.count[first] or 0), { hl = 'Comment', size = 'sm' }),
  }
end

-- A list line as one row.
local function row(snap, i)
  local u = ui()
  local item = snap.items[i]
  local current = i == snap.idx
  local raw = (item.text or ''):gsub('\n', ' ')
  local lead = #(raw:match '^%s*')
  local text = raw:sub(lead + 1)
  local children = {}
  if snap.group[i] then
    table.insert(children, u.spacer(M.INDENT))
  end
  -- The current item: a bar in the accent's colour, in the grid's face so
  -- every row keeps the same room for it.
  table.insert(children, u.text({ { current and '▎' or ' ', hl = 'Function', mono = true } }, { mono = true }))
  local pos = M.position(item)
  local width = snap.width
  if width > 0 then
    table.insert(
      children,
      u.text({ { ('%' .. width .. 's'):format(pos), hl = current and 'Function' or 'LineNr', mono = true, bold = current or nil } }, {
        mono = true,
      })
    )
  end
  local sign = M.sign(item.type)
  if sign then
    table.insert(children, u.text({ { sign.text, hl = sign.hl, mono = true } }, { mono = true }))
  end
  local runs
  if not item.valid or item.valid == 0 or (not item.bufnr or item.bufnr == 0) then
    -- A line of the tool's output, not a place.
    runs = { { text, dim = true, mono = true } }
  elseif sign then
    -- A message: the UI's face.
    runs = { { text } }
  else
    -- Code (a grep's line, a reference): the grid's face, the match marked.
    local s, e = M.match(item, text, lead, snap.pattern)
    if s then
      runs = {
        { text:sub(1, s - 1), mono = true },
        { text:sub(s, e), hl = 'Search', mark = true, mono = true },
        { text:sub(e + 1), mono = true },
      }
    else
      runs = { { text, mono = true } }
    end
  end
  if current then
    for _, r in ipairs(runs) do
      r.bold = true
    end
  end
  if text == '' then
    runs = { { ' ' } }
  end
  table.insert(children, u.text(runs, { grow = true, mono = not sign or nil }))
  if item.nr and item.nr > 0 then
    table.insert(children, u.text({ { ('[%d]'):format(item.nr), dim = true, mono = true } }, { mono = true }))
  end
  return u.hstack { gap = M.GAP, align = 'center', unpack(children) }
end

--- Line lnum of a qf buffer as a view item: { node, heading? }, or nil
--- (the line drawn as it is).
function M.item(buf, lnum)
  local snap = (lnum == 1 or not snapshots[buf]) and M.snapshot(buf) or snapshots[buf]
  if not snap or not snap.lines_match then
    return nil
  end
  local item = snap.items[lnum]
  if not item then
    return nil
  end
  local node = row(snap, lnum)
  if snap.group[lnum] == lnum then
    return { node = node, heading = heading(snap, lnum) }
  end
  return { node = node }
end

--- The title row: which list, its title, which of the lists it is, and the
--- position.
function M.header(buf)
  local snap = snapshots[buf] or M.snapshot(buf)
  if not snap then
    return nil
  end
  local u = ui()
  local children = {
    u.text(snap.loclist and 'Location List' or 'Quickfix', { size = 'sm', bold = true, dim = true, upper = true }),
    u.text(snap.title ~= '' and snap.title or '(untitled)', { grow = true, dim = snap.title == '' or nil }),
  }
  if snap.last > 1 then
    table.insert(children, u.text(('list %d of %d'):format(snap.nr, snap.last), { size = 'sm', dim = true }))
  end
  table.insert(children, u.badge(snap.size > 0 and ('%d / %d'):format(snap.idx, snap.size) or '0', { hl = 'Comment', size = 'sm' }))
  return u.hstack { gap = 8, align = 'center', unpack(children) }
end

-- A double click is <CR> there: your mapping, else Neovim's jump.
local function on_click(_, clicks)
  if clicks ~= 2 then
    return
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'm', false)
end

--- Draw qf buffer buf natively (once: a view follows its buffer into every
--- window that shows it).
function M.attach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if attached[buf] or not M.active() or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= 'quickfix' then
    return
  end
  local gui = require 'devhub.gui'
  if not gui.available() then
    return
  end
  attached[buf] = {}
  local view = gui.view {
    buf = buf,
    row_height = M.ROW_HEIGHT,
    sticky_headings = true,
    header = function()
      local ok, node = pcall(M.header, buf)
      return ok and node or nil
    end,
    items = function(lnum)
      local ok, item = pcall(M.item, buf, lnum)
      return ok and item or nil
    end,
    on_click = on_click,
  }
  if not view then
    attached[buf] = nil
    return
  end
  attached[buf].view = view
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      attached[buf] = nil
      snapshots[buf] = nil
    end,
  })
end

--- Stop drawing buf natively.
function M.detach(buf)
  local a = attached[buf]
  attached[buf] = nil
  snapshots[buf] = nil
  if a and a.view then
    a.view:close()
  end
end

--- Draw again each view whose list changed without its buffer: the
--- current item (`:cnext`, `setqflist({}, 'a', { idx })`), the title.
function M.refresh()
  for buf, a in pairs(attached) do
    if a.view and vim.api.nvim_buf_is_valid(buf) then
      local which = list_of(buf)
      if which ~= nil then
        local s = state_of(which)
        if a.state ~= nil and a.state ~= s then
          a.state = s
          a.view:update()
          -- Neovim moved the qf window's cursor to the item itself.
          a.view:redraw()
        end
      end
    end
  end
end

local installed = false

--- Draw every qf window natively from now on (devhub.nvim does this in
--- DevHub's GUI).
function M.install()
  if installed then
    return
  end
  installed = true
  local group = vim.api.nvim_create_augroup('devhub_qf', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'qf',
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'SafeState', 'QuickFixCmdPost', 'BufWinEnter' }, {
    group = group,
    callback = function()
      if next(attached) ~= nil then
        M.refresh()
      end
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == 'quickfix' then
      M.attach(b)
    end
  end
end

M._attached = attached
M._snapshots = snapshots

return M
