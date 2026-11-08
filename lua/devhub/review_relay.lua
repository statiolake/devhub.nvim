-- require('devhub.review_relay'): review-relay's review, in Neovim.
--
-- A thin adapter. review-relay keeps the review (its viewer serves it on
-- 127.0.0.1); this module reads it with review-relay's own commands
-- (`review-relay comments list`, `/ui/files`) and writes through them
-- (`comments resolve`, a reply, a reviewed mark), and follows the viewer's
-- event stream to refresh. Nothing about a review is decided here.
--
-- * :ReviewRelay opens a panel: a buffer, one line per file / thread
--   (`review-relay://…`), which DevHub draws as the review panel (gui.view):
--   a progress meter, the file tree with reviewed checkboxes and thread
--   counts, Waiting / Answered / All, the threads.
--   Keys: <CR> open, <Space> reviewed, r reply, s resolve, f filter,
--   R refresh, q close.
-- * In a file of the review, each thread is a card under its lines
--   (gui.inline): the comments in markdown, who wrote them, Reply and
--   Resolve; r and s on the thread's lines do the same.
--
-- Outside DevHub's GUI the panel is the same buffer, as text, and the keys
-- work; threads show as signs. When no review-relay viewer holds the
-- workspace, :ReviewRelay [git diff args] starts one without a window
-- (`review-relay --no-window`) and stops it again on :ReviewRelay stop or
-- when Neovim exits.

local M = {}

M.config = {
  -- The review-relay executable; curl for the endpoints the CLI has no
  -- command for (the file list, reviewed marks, a human's reply, events).
  cmd = 'review-relay',
  curl = 'curl',
  -- Your name on a reply; nil: `git config user.name` in the workspace.
  author = nil,
  -- The viewer's endpoint; nil: found from the current directory, as the
  -- CLI finds it ($REVIEW_RELAY_ENDPOINT first).
  endpoint = nil,
  -- The panel's width, in columns.
  width = 54,
  -- Threads as cards under their lines (in DevHub's GUI), signs elsewhere.
  inline = true,
  -- Keys on a thread's lines in a file buffer (false: none).
  inline_keys = { reply = 'r', resolve = 's' },
  -- How a reply is written: 'input' (vim.ui.input) or 'buffer' (a scratch
  -- markdown buffer; :w sends it).
  reply_with = 'input',
  -- A notification when the agent answers.
  notify = true,
  -- The highlight groups (or tones) the review wears: the agent, the person,
  -- a thread waiting for the agent, a resolved one, the Resolve button.
  colors = {
    agent = 'Function',
    human = 'DiagnosticInfo',
    waiting = 'DiagnosticWarn',
    resolved = 'Comment',
    ok = 'DiagnosticOk',
  },
}

local state = {
  endpoint = nil,
  root = nil,
  diff = false,
  diff_args = {},
  files = {},
  reviewed = {},
  comments = {},
  overall = '',
  filter = 'all',
  collapsed = {},
  panel = nil, -- { buf, view }
  entries = {},
  cards = {}, -- buf -> { [thread id] = handle }
  events = nil,
  seen = nil,
  server = nil, -- the --no-window viewer this adapter started: its job id
}
M._state = state

local gui = require('devhub').gui
local ui = gui.ui
local ns = vim.api.nvim_create_namespace 'devhub_review_relay'

-- Running commands -------------------------------------------------------------

--- Run argv; cb(ok, stdout, stderr) on the main loop. stdin: text to send.
local function run(argv, cb, stdin)
  local out, err = {}, {}
  local ok, job = pcall(vim.fn.jobstart, argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      out = data
    end,
    on_stderr = function(_, data)
      err = data
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        cb(code == 0, table.concat(out, '\n'), table.concat(err, '\n'))
      end)
    end,
  })
  if not ok or job <= 0 then
    vim.schedule(function()
      cb(false, '', 'cannot run ' .. tostring(argv[1]))
    end)
    return
  end
  if stdin then
    vim.fn.chansend(job, stdin)
  end
  vim.fn.chanclose(job, 'stdin')
end
M._run = run

local function decode(text)
  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok and type(value) == 'table' then
    return value
  end
  return nil
end

local function warn(message)
  if vim.trim(message or '') == '' then
    return
  end
  vim.notify('review-relay: ' .. message, vim.log.levels.WARN, { title = 'review-relay' })
end

local function cli(args, cb)
  local argv = { M.config.cmd, '--endpoint', state.endpoint }
  vim.list_extend(argv, args)
  run(argv, function(ok, out, err)
    -- Not once the review is stopped: what was in flight then fails quietly.
    if not ok and state.endpoint then
      warn(vim.trim(err ~= '' and err or out))
    end
    cb(ok, ok and decode(out) or nil)
  end)
end

local function http(method, path, body, cb)
  local argv = { M.config.curl, '-sS', '--fail-with-body', '-X', method, state.endpoint .. path }
  local stdin
  if body ~= nil then
    vim.list_extend(argv, { '-H', 'Content-Type: application/json', '--data-binary', '@-' })
    stdin = vim.json.encode(body)
  end
  run(argv, function(ok, out, err)
    if not ok and state.endpoint then
      warn(vim.trim(out ~= '' and out or err))
    end
    cb(ok, ok and decode(out) or nil)
  end, stdin)
end

-- Finding the viewer -----------------------------------------------------------

local function contains(root, path)
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

--- The viewer's endpoint and root for dir, as `review-relay` finds them: the
--- live descriptor in $TMPDIR/review-relay/sessions whose root is the
--- deepest one holding dir.
function M.find(dir)
  if M.config.endpoint or vim.env.REVIEW_RELAY_ENDPOINT then
    return M.config.endpoint or vim.env.REVIEW_RELAY_ENDPOINT, nil
  end
  dir = vim.fn.resolve(vim.fn.fnamemodify(dir or vim.fn.getcwd(), ':p')):gsub('/$', '')
  local tmp = (vim.env.TMPDIR or '/tmp'):gsub('/$', '')
  local best
  for _, file in ipairs(vim.fn.glob(tmp .. '/review-relay/sessions/*.json', false, true)) do
    local f = io.open(file)
    local d = f and decode(f:read '*a')
    if f then
      f:close()
    end
    if
      d
      and d.version == 2
      and type(d.endpoint) == 'string'
      and d.endpoint:match '^http://127%.0%.0%.1:%d+$'
      and type(d.root) == 'string'
      and contains(d.root, dir)
    then
      local health = vim.fn.system { M.config.curl, '-s', '--max-time', '1', d.endpoint .. '/health' }
      if vim.v.shell_error == 0 and health:find('"ok":true', 1, true) and (not best or #d.root > #best.root) then
        best = d
      end
    end
  end
  if best then
    return best.endpoint, best.root
  end
  return nil, nil
end

-- The review, as data ----------------------------------------------------------

--- Threads from the flat comment list: the root, its replies, a status.
function M.threads(comments)
  local by_id, list = {}, {}
  for _, c in ipairs(comments or {}) do
    if not c.parentId then
      local t = { id = c.id, root = c, comments = { c }, path = c.path, line = c.line, endLine = c.endLine }
      by_id[c.id] = t
      table.insert(list, t)
    end
  end
  for _, c in ipairs(comments or {}) do
    local t = c.parentId and by_id[c.parentId]
    if t then
      table.insert(t.comments, c)
    end
  end
  for _, t in ipairs(list) do
    local last = t.comments[#t.comments]
    t.status = t.root.resolved and 'resolved' or (last.source == 'agent' and 'answered' or 'waiting')
  end
  table.sort(list, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  return list
end

local LABELS = { waiting = 'Waiting for AI', answered = 'AI replied', resolved = 'Resolved' }

-- A status's label and colour (a group, from config.colors).
local function status(name)
  local c = M.config.colors
  local group = name == 'waiting' and c.waiting or name == 'answered' and c.agent or c.resolved
  return { label = LABELS[name], tone = group, sign = group }
end
local STATUS = setmetatable({}, {
  __index = function(_, name)
    return status(name)
  end,
})

local function loc(t)
  local name = vim.fn.fnamemodify(t.path, ':t')
  if t.endLine ~= t.line then
    return ('%s:%d–%d'):format(name, t.line + 1, t.endLine + 1)
  end
  return ('%s:%d'):format(name, t.line + 1)
end

local function first_line(text)
  return (text or ''):gsub('\n.*', ''):gsub('`', '')
end

-- RFC 3339 to seconds since the epoch.
local function epoch(stamp)
  local y, mo, d, h, mi, s, rest = (stamp or ''):match '^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*(.*)$'
  if not y then
    return nil
  end
  local t = os.time { year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }
  local utc_offset = os.time() - os.time(os.date '!*t')
  t = t + utc_offset
  local sign, oh, om = rest:match '^([+-])(%d+):(%d+)$'
  if sign then
    t = t - (sign == '+' and 1 or -1) * (oh * 3600 + om * 60)
  end
  return t
end

function M.ago(stamp, now)
  local t = epoch(stamp)
  if not t then
    return ''
  end
  local d = math.max(0, (now or os.time()) - t)
  if d < 60 then
    return 'just now'
  elseif d < 3600 then
    return math.floor(d / 60) .. ' min ago'
  elseif d < 86400 then
    return math.floor(d / 3600) .. ' h ago'
  end
  return math.floor(d / 86400) .. ' d ago'
end

local function is_agent(c)
  return c.source == 'agent'
end

-- Components ---------------------------------------------------------------------

local function avatar(c)
  return ui.avatar(c.author or '?', { tone = is_agent(c) and M.config.colors.agent or M.config.colors.human, size = 20 })
end

--- A thread as a card: its comments (markdown), who wrote them, Reply and
--- Resolve. Resolved threads fold to one line.
function M.thread_card(t, actions)
  actions = actions or {}
  local st = STATUS[t.status]
  if t.status == 'resolved' then
    return ui.hstack {
      card = true,
      pad = { 4, 12 },
      gap = 8,
      ui.text({ { '✓ Resolved', bold = true } }, { tone = M.config.colors.ok }),
      ui.text(('L%d'):format(t.line + 1), { mono = true, dim = true, size = 'sm' }),
      ui.text(first_line(t.root.body), { grow = true, dim = true }),
      ui.text(#t.comments > 1 and ('+' .. (#t.comments - 1)) or '', { dim = true, size = 'sm' }),
      ui.button('Reopen', { key = M.config.inline_keys and M.config.inline_keys.resolve or nil, on_click = actions.resolve }),
    }
  end
  local range = t.endLine ~= t.line and ('L%d–%d'):format(t.line + 1, t.endLine + 1) or ('L%d'):format(t.line + 1)
  local children = {
    ui.hstack {
      gap = 8,
      ui.text(range, { mono = true, dim = true, size = 'sm' }),
      ui.badge(st.label, { tone = st.tone }),
      ui.spacer(),
      ui.text(#t.comments == 1 and '1 comment' or (#t.comments .. ' comments'), { dim = true, size = 'sm' }),
    },
  }
  for index, c in ipairs(t.comments) do
    if index > 1 then
      table.insert(children, ui.divider())
    end
    table.insert(
      children,
      ui.hstack {
        align = 'start',
        gap = 10,
        avatar(c),
        ui.stack {
          grow = true,
          gap = 2,
          ui.hstack {
            gap = 7,
            ui.text({ { c.author or '?', bold = true } }),
            ui.badge(is_agent(c) and 'agent' or 'you', { tone = is_agent(c) and M.config.colors.agent or M.config.colors.human }),
            ui.text(M.ago(c.createdAt), { dim = true, size = 'sm' }),
          },
          ui.md(c.body or ''),
        },
      }
    )
  end
  table.insert(
    children,
    ui.hstack {
      pad = { 2, 0 },
      ui.spacer(30),
      ui.button('Reply', { icon = '↩', key = M.config.inline_keys and M.config.inline_keys.reply or nil, on_click = actions.reply }),
      ui.spacer(),
      ui.button('Resolve', {
        icon = '✓',
        key = M.config.inline_keys and M.config.inline_keys.resolve or nil,
        tone = M.config.colors.ok,
        on_click = actions.resolve,
      }),
    }
  )
  children.card = true
  children.gap = 8
  children.pad = { 8, 12 }
  return ui.stack(children)
end

local STATUS_TONE = { M = 'changed', A = 'added', D = 'removed', R = 'info', C = 'info', T = 'changed', U = 'error' }

local function counts(threads)
  local c = { waiting = 0, answered = 0, resolved = 0 }
  for _, t in ipairs(threads) do
    c[t.status] = c[t.status] + 1
  end
  return c
end

local function pills(c)
  local out = {}
  if c.waiting > 0 then
    table.insert(out, ui.pill(c.waiting, { tone = M.config.colors.waiting }))
  end
  if c.answered > 0 then
    table.insert(out, ui.pill(c.answered, { tone = M.config.colors.agent }))
  end
  if c.resolved > 0 then
    table.insert(out, ui.pill(c.resolved, { tone = M.config.colors.resolved }))
  end
  return out
end

local function reviewed(file)
  return file.hash ~= nil and file.hash ~= '' and state.reviewed[file.path] == file.hash
end

-- The panel ---------------------------------------------------------------------

--- The panel's entries: { text = buffer line, node = component, kind, … }.
function M.entries()
  local entries = {}
  local function add(e)
    table.insert(entries, e)
  end
  local threads = M.threads(state.comments)
  local by_path = {}
  for _, t in ipairs(threads) do
    by_path[t.path] = by_path[t.path] or {}
    table.insert(by_path[t.path], t)
  end
  local title = state.diff and table.concat(state.diff_args, ' ') or 'files'
  if title == '' then
    title = 'git diff'
  end
  add {
    kind = 'header',
    text = 'Review  ' .. title,
    node = ui.hstack {
      gap = 8,
      pad = { 6, 2 },
      ui.text('Review', { size = 'lg', bold = true, tone = 'title' }),
      ui.badge(title, { mono = true, tone = 'muted' }),
      state.diff and ui.badge('diff', { tone = 'info' }) or ui.spacer(0),
      ui.spacer(),
      ui.text(vim.fn.fnamemodify(state.root or '', ':t'), { dim = true, size = 'sm' }),
    },
  }
  local total, done = 0, 0
  for _, f in ipairs(state.files) do
    if f.hash and f.hash ~= '' then
      total = total + 1
      if reviewed(f) then
        done = done + 1
      end
    end
  end
  if state.diff then
    add {
      kind = 'progress',
      text = ('%d / %d reviewed'):format(done, total),
      node = ui.hstack {
        gap = 10,
        pad = { 2, 2 },
        ui.progress(total > 0 and done / total or 0, { grow = true }),
        ui.text(done == total and total > 0 and 'All reviewed' or ('%d / %d reviewed'):format(done, total), { dim = true, size = 'sm' }),
      },
    }
  end
  add {
    kind = 'section',
    text = 'FILES',
    node = ui.hstack { pad = { 6, 2 }, ui.text('Files', { upper = true, dim = true }), ui.spacer(), ui.text('threads', { dim = true, size = 'xs' }) },
  }
  -- Files by directory, one level: "internal/server" then its files.
  local dirs, order = {}, {}
  for _, f in ipairs(state.files) do
    local dir = f.path:match '^(.*)/[^/]+$' or ''
    if not dirs[dir] then
      dirs[dir] = {}
      table.insert(order, dir)
    end
    table.insert(dirs[dir], f)
  end
  table.sort(order, function(a, b)
    if (a == '') ~= (b == '') then
      return a ~= ''
    end
    return a < b
  end)
  for _, dir in ipairs(order) do
    local files = dirs[dir]
    local indent = 0
    if dir ~= '' then
      local n, all = 0, 0
      for _, f in ipairs(files) do
        if f.hash and f.hash ~= '' then
          all = all + 1
          if reviewed(f) then
            n = n + 1
          end
        end
      end
      local check = all > 0 and n == all or (n > 0 and 'mixed' or false)
      local open = not state.collapsed[dir]
      add {
        kind = 'dir',
        dir = dir,
        files = files,
        text = (open and '▾ ' or '▸ ') .. dir .. '/',
        node = ui.hstack {
          gap = 8,
          pad = { 3, 2 },
          state.diff and ui.checkbox(check, {
            on_click = function()
              M.toggle_reviewed { kind = 'dir', files = dirs[dir] }
            end,
          }) or ui.spacer(0),
          ui.text((open and '▾ ' or '▸ ') .. dir, { dim = true, grow = true }),
        },
      }
      indent = 22
      if not open then
        files = {}
      end
    end
    for _, f in ipairs(files) do
      local name = dir ~= '' and f.path:sub(#dir + 2) or f.path
      local c = counts(by_path[f.path] or {})
      local row = {
        gap = 8,
        pad = { 3, 2 },
        indent = indent,
      }
      if state.diff then
        table.insert(
          row,
          ui.checkbox(reviewed(f), {
            on_click = function()
              M.toggle_reviewed { kind = 'file', file = f }
            end,
          })
        )
        table.insert(row, ui.text(f.status or ' ', { mono = true, bold = true, tone = STATUS_TONE[f.status] or 'muted' }))
      end
      local label = { { name, strike = f.status == 'D' or nil } }
      if f.oldPath then
        table.insert(label, { '  ← ' .. vim.fn.fnamemodify(f.oldPath, ':t'), dim = true })
      end
      table.insert(row, ui.text(label, { grow = true, dim = reviewed(f) or nil }))
      vim.list_extend(row, pills(c))
      local tail = (c.waiting + c.answered + c.resolved > 0) and ('  ' .. (c.waiting + c.answered + c.resolved)) or ''
      add {
        kind = 'file',
        file = f,
        text = (dir ~= '' and '  ' or '') .. (f.status and (f.status .. ' ') or '') .. f.path .. tail,
        node = ui.hstack(row),
      }
    end
  end
  local c = counts(threads)
  local filters = {
    { 'waiting', 'Waiting', c.waiting },
    { 'answered', 'Answered', c.answered },
    { 'all', 'All', #threads },
  }
  local segs = { gap = 4, pad = { 8, 0 } }
  for _, f in ipairs(filters) do
    local on = state.filter == f[1]
    table.insert(
      segs,
      ui.hstack {
        grow = true,
        justify = 'center',
        gap = 4,
        pad = { 3, 0 },
        bg = on and 'CursorLine' or nil,
        on_click = function()
          M.set_filter(f[1])
        end,
        ui.text(f[2], { bold = on or nil, dim = not on or nil }),
        ui.text(tostring(f[3]), { dim = true, size = 'sm' }),
      }
    )
  end
  add {
    kind = 'filter',
    text = ('Waiting %d · Answered %d · All %d'):format(c.waiting, c.answered, #threads),
    node = ui.hstack(segs),
  }
  for _, t in ipairs(threads) do
    if state.filter == 'all' or state.filter == t.status then
      local st = STATUS[t.status]
      local who, seen = { gap = 3 }, {}
      for _, cm in ipairs(t.comments) do
        local key = (cm.source or '') .. (cm.author or '')
        if not seen[key] then
          seen[key] = true
          table.insert(who, avatar(cm))
        end
      end
      add {
        kind = 'thread',
        thread = t,
        text = ('%s [%s] %s'):format(loc(t), st.label, first_line(t.root.body)),
        node = ui.stack {
          card = true,
          pad = { 7, 12 },
          gap = 3,
          ui.hstack {
            gap = 6,
            ui.text(loc(t), { mono = true, dim = true, size = 'sm' }),
            ui.badge(st.label, { tone = st.tone }),
            ui.spacer(),
            ui.hstack(who),
          },
          ui.text(first_line(t.root.body), { dim = t.status == 'resolved' or nil }),
        },
      }
    end
  end
  if #threads == 0 then
    add { kind = 'empty', text = 'No threads', node = ui.text('No threads yet.', { dim = true }) }
  end
  if state.overall ~= '' then
    add {
      kind = 'overall',
      text = 'Overall: ' .. first_line(state.overall),
      node = ui.stack { card = true, pad = { 6, 10 }, ui.text('Overall: ' .. state.overall, { dim = true, wrap = true, size = 'sm' }) },
    }
  end
  return entries
end

local KEYS = {
  { 'j/k', 'move' },
  { '⏎', 'open' },
  { 'r', 'reply' },
  { 's', 'resolve' },
  { '␣', 'reviewed' },
  { 'f', 'filter' },
  { 'q', 'close' },
}

local function draw_panel()
  local panel = state.panel
  if not panel or not vim.api.nvim_buf_is_valid(panel.buf) then
    return
  end
  local entries = M.entries()
  state.entries = entries
  local lines = {}
  for _, e in ipairs(entries) do
    table.insert(lines, e.text)
  end
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  vim.bo[panel.buf].modified = false
  if panel.view then
    panel.view:update()
  end
end

local function entry_at(lnum)
  return state.entries[lnum or vim.api.nvim_win_get_cursor(0)[1]]
end

-- Inline threads in file buffers ---------------------------------------------------

local function rel(buf)
  if not state.root then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return nil
  end
  name = vim.fn.resolve(name)
  if contains(state.root, name) and name ~= state.root then
    return name:sub(#state.root + 2)
  end
  return nil
end

local function thread_at(buf, lnum)
  local path = rel(buf)
  if not path then
    return nil
  end
  for _, t in ipairs(M.threads(state.comments)) do
    if t.path == path and lnum >= t.line + 1 and lnum <= t.endLine + 1 then
      return t
    end
  end
  return nil
end

local function code_window()
  local panel = state.panel and state.panel.buf
  local prev = vim.fn.win_getid(vim.fn.winnr '#')
  if prev ~= 0 and vim.api.nvim_win_get_buf(prev) ~= panel and vim.api.nvim_win_get_config(prev).relative == '' then
    return prev
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) ~= panel and vim.api.nvim_win_get_config(win).relative == '' then
      return win
    end
  end
  return nil
end

local function map_inline_keys(buf, on)
  local keys = M.config.inline_keys
  if not keys then
    return
  end
  for action, lhs in pairs(keys) do
    if on then
      vim.keymap.set('n', lhs, function()
        local t = thread_at(buf, vim.api.nvim_win_get_cursor(0)[1])
        if not t then
          return lhs
        end
        vim.schedule(function()
          if action == 'reply' then
            M.reply(t)
          else
            M.resolve(t)
          end
        end)
        return ''
      end, { buffer = buf, expr = true, desc = 'review-relay: ' .. action .. ' the thread here' })
    else
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end
  end
end

--- Cards (DevHub) or signs (elsewhere) for the threads of buf.
function M.decorate_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
    return
  end
  local path = rel(buf)
  local threads = {}
  if path then
    for _, t in ipairs(M.threads(state.comments)) do
      if t.path == path then
        table.insert(threads, t)
      end
    end
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(buf)
  local cards = state.cards[buf] or {}
  local keep = {}
  for _, t in ipairs(threads) do
    local first, last = math.min(t.line, count - 1), math.min(t.endLine, count - 1)
    for l = first, last do
      vim.api.nvim_buf_set_extmark(buf, ns, l, 0, { sign_text = '▎', sign_hl_group = STATUS[t.status].sign, priority = 20 })
    end
    if M.config.inline and gui.available() then
      local actions = {
        reply = function()
          M.reply(t)
        end,
        resolve = function()
          M.resolve(t)
        end,
      }
      keep[t.id] = gui.inline {
        buf = buf,
        lnum = last + 1,
        id = 'review-relay:' .. t.id,
        range = { first + 1, last + 1 },
        component = M.thread_card(t, actions),
      }
    end
  end
  for id, handle in pairs(cards) do
    if not keep[id] then
      handle:clear()
    end
  end
  state.cards[buf] = keep
  map_inline_keys(buf, #threads > 0)
end

local function decorate_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and (state.cards[buf] or rel(buf)) then
      M.decorate_buffer(buf)
    end
  end
end

-- Loading and refreshing -------------------------------------------------------------

--- Read the review again: comments (the CLI), files and reviewed marks.
function M.refresh(cb)
  if not state.endpoint then
    return
  end
  local pending = 2
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    draw_panel()
    decorate_all()
    if cb then
      cb()
    end
  end
  cli({ 'comments', 'list' }, function(ok, data)
    if ok and data then
      local comments = data.comments or {}
      -- The agent's comments not seen before (none at the first read).
      local fresh = {}
      for _, c in ipairs(comments) do
        if is_agent(c) and state.seen and not state.seen[c.id] then
          table.insert(fresh, c)
        end
      end
      state.seen = state.seen or {}
      for _, c in ipairs(comments) do
        state.seen[c.id] = true
      end
      if M.config.notify then
        for _, c in ipairs(fresh) do
          gui.notify {
            group = 'review-relay',
            key = 'review-relay:' .. c.id,
            msg = ('%s replied on %s:%d'):format(c.author or 'agent', vim.fn.fnamemodify(c.path, ':t'), c.line + 1),
          }
        end
      end
      state.comments = comments
      state.overall = data.overall or ''
    end
    done()
  end)
  http('GET', '/ui/files', nil, function(ok, data)
    if ok and data then
      state.files = data.files or {}
      state.reviewed = data.reviewed or {}
    end
    done()
  end)
end

local refresh_timer
local function refresh_soon()
  if refresh_timer then
    refresh_timer:stop()
  end
  refresh_timer = vim.defer_fn(function()
    refresh_timer = nil
    M.refresh()
  end, 120)
end

local function jump(path, line)
  local win = code_window()
  if win then
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd('drop ' .. vim.fn.fnameescape(state.root .. '/' .. path))
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line + 1, 0 })
    vim.cmd 'normal! zvzz'
  end
end

--- Follow the viewer's event stream: a change refreshes, a navigate (an
--- agent's `review-relay navigate`) opens the place.
local function follow()
  if state.events then
    return
  end
  local pending_event
  local ok, job = pcall(vim.fn.jobstart, { M.config.curl, '-sN', state.endpoint .. '/ui/events' }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        local name = line:match '^event: (%S+)'
        if name then
          pending_event = name
        end
        local payload = line:match '^data: (.*)$'
        if payload and pending_event then
          local ev = pending_event
          pending_event = nil
          vim.schedule(function()
            if ev == 'state' then
              refresh_soon()
            elseif ev == 'navigate' then
              local target = decode(payload)
              if target and target.path then
                jump(target.path, target.line)
              end
            end
          end)
        end
      end
    end,
    on_exit = function()
      state.events = nil
    end,
  })
  if ok and job > 0 then
    state.events = job
  end
end

--- Start a viewer without a window for dir (default: the current
--- directory): `review-relay --no-window [-- diff_args]` — no diff_args is
--- review-relay's own default, the files of the directory. cb(ok) once it
--- is up (its session found) or has failed. It is stopped by M.stop() and
--- when Neovim exits.
function M.start_server(dir, diff_args, cb)
  dir = dir or vim.fn.getcwd()
  local argv = { M.config.cmd, '--no-window' }
  if diff_args and #diff_args > 0 then
    table.insert(argv, '--')
    vim.list_extend(argv, diff_args)
  end
  local err = {}
  local done = false
  local function finish(ok, message)
    if done then
      return
    end
    done = true
    if not ok then
      warn(message)
    end
    cb(ok)
  end
  local ok, job = pcall(vim.fn.jobstart, argv, {
    cwd = dir,
    on_stderr = function(_, data)
      vim.list_extend(err, data)
    end,
    on_exit = function(id, code)
      vim.schedule(function()
        if state.server == id then
          state.server = nil
        end
        finish(false, 'the viewer it started exited (' .. code .. '): ' .. vim.trim(table.concat(err, '\n')))
      end)
    end,
  })
  if not ok or job <= 0 then
    finish(false, 'cannot run ' .. tostring(M.config.cmd))
    return
  end
  state.server = job
  -- Its session is written once it listens: then it is found as any viewer.
  local tries = 0
  local function look()
    if done then
      return
    end
    if M.find(dir) then
      local what = diff_args and #diff_args > 0 and table.concat(diff_args, ' ') or 'the files'
      vim.notify('started a viewer for ' .. what .. ' (no window)', vim.log.levels.INFO, { title = 'review-relay' })
      finish(true)
      return
    end
    tries = tries + 1
    if tries > 50 then
      M.stop_server()
      finish(false, 'the viewer it started did not come up')
      return
    end
    vim.defer_fn(look, 100)
  end
  look()
end

--- Stop the viewer this adapter started, if it did.
function M.stop_server()
  if state.server then
    pcall(vim.fn.jobstop, state.server)
    state.server = nil
  end
end

--- Connect to the viewer for dir (default: the current directory).
function M.connect(dir)
  local endpoint, root = M.find(dir)
  if not endpoint then
    warn 'no running review-relay viewer contains this directory'
    return false
  end
  state.endpoint = endpoint
  if not root then
    local health = decode(vim.fn.system { M.config.curl, '-s', endpoint .. '/health' })
    root = health and health.root
  end
  state.root = root and vim.fn.resolve(root) or nil
  local session = decode(vim.fn.system { M.config.curl, '-s', endpoint .. '/ui/session' })
  if session then
    state.diff = session.diff == true
    state.diff_args = session.diffArgs or {}
  end
  follow()
  return true
end

-- Actions ------------------------------------------------------------------------------

local function submit_reply(t, body)
  body = vim.trim(body or '')
  if body == '' then
    return
  end
  local payload = { path = t.path, line = t.line, endLine = t.endLine, body = body, source = 'human' }
  local author = M.config.author
  if author == nil then
    -- Who you are to git in the workspace, as the viewer would not know.
    local name = vim.fn.systemlist { 'git', '-C', state.root or '.', 'config', 'user.name' }[1]
    author = vim.v.shell_error == 0 and name and vim.trim(name) ~= '' and vim.trim(name) or nil
  end
  if author then
    payload.author = author
  end
  -- A person's reply: the CLI's `comments reply` speaks for the agent.
  http('POST', '/v1/comments/' .. t.id .. '/replies', payload, function()
    M.refresh()
  end)
end

--- Reply to a thread (the one under the cursor by default).
function M.reply(t)
  t = t or (entry_at() or {}).thread or thread_at(0, vim.api.nvim_win_get_cursor(0)[1])
  if not t then
    return
  end
  if M.config.reply_with == 'buffer' then
    vim.cmd 'botright 8split'
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.bo[buf].buftype = 'acwrite'
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_name(buf, 'review-relay://reply/' .. t.id)
    vim.api.nvim_create_autocmd('BufWriteCmd', {
      buffer = buf,
      callback = function()
        submit_reply(t, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
        vim.bo[buf].modified = false
        vim.api.nvim_buf_delete(buf, { force = true })
      end,
    })
    vim.cmd 'startinsert'
    return
  end
  vim.ui.input({ prompt = 'Reply to ' .. loc(t) .. ': ' }, function(body)
    submit_reply(t, body)
  end)
end

--- Resolve a thread, or reopen a resolved one.
function M.resolve(t)
  t = t or (entry_at() or {}).thread or thread_at(0, vim.api.nvim_win_get_cursor(0)[1])
  if not t then
    return
  end
  cli({ 'comments', t.status == 'resolved' and 'unresolve' or 'resolve', t.id }, function()
    M.refresh()
  end)
end

local function set_reviewed(files, on)
  local pending = #files
  if pending == 0 then
    return
  end
  for _, f in ipairs(files) do
    http('PUT', '/ui/reviewed', { path = f.path, hash = on and f.hash or '' }, function()
      pending = pending - 1
      if pending == 0 then
        M.refresh()
      end
    end)
  end
end

--- Toggle reviewed for the file (or every file of the directory) here.
function M.toggle_reviewed(e)
  e = e or entry_at()
  if not e or not state.diff then
    return
  end
  if e.kind == 'file' and e.file.hash and e.file.hash ~= '' then
    set_reviewed({ e.file }, not reviewed(e.file))
  elseif e.kind == 'dir' then
    local all = true
    local files = {}
    for _, f in ipairs(e.files) do
      if f.hash and f.hash ~= '' then
        table.insert(files, f)
        all = all and reviewed(f)
      end
    end
    set_reviewed(files, not all)
  end
end

--- Open what is under the cursor: a file, a thread at its line, a directory folds.
function M.open(e)
  e = e or entry_at()
  if not e then
    return
  end
  if e.kind == 'file' then
    jump(e.file.path)
  elseif e.kind == 'thread' then
    jump(e.thread.path, e.thread.endLine)
  elseif e.kind == 'dir' then
    state.collapsed[e.dir] = not state.collapsed[e.dir] or nil
    draw_panel()
  elseif e.kind == 'filter' then
    M.set_filter(state.filter == 'all' and 'waiting' or state.filter == 'waiting' and 'answered' or 'all')
  end
end

function M.set_filter(filter)
  state.filter = filter
  draw_panel()
end

--- :ReviewRelay [git diff args] — the panel (opened, or focused when it is
--- open). With no viewer for the directory, one is started without a
--- window, for diff_args (none: review-relay's default, the files).
function M.open_panel(diff_args)
  if not M._setup then
    M.setup()
  end
  if not state.endpoint then
    if not M.find() then
      if state.starting then
        return
      end
      state.starting = true
      M.start_server(nil, diff_args, function(ok)
        state.starting = false
        if ok then
          M.open_panel()
        end
      end)
      return
    end
    if not M.connect() then
      return
    end
  end
  local panel = state.panel
  if panel and vim.api.nvim_buf_is_valid(panel.buf) then
    local win = vim.fn.bufwinid(panel.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
      M.refresh()
      return
    end
  end
  local buf = (panel and vim.api.nvim_buf_is_valid(panel.buf)) and panel.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'review-relay'
  local title = state.diff and table.concat(state.diff_args, ' ') or 'files'
  pcall(vim.api.nvim_buf_set_name, buf, 'review-relay://' .. (title ~= '' and title or 'diff'))
  vim.cmd('botright vertical ' .. M.config.width .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  for option, value in pairs { number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0', wrap = false, winfixwidth = true, cursorline = true } do
    vim.wo[win][option] = value
  end
  state.panel = { buf = buf }
  state.panel.view = gui.view {
    buf = buf,
    items = function(lnum)
      local e = state.entries[lnum]
      return e and e.node or nil
    end,
    keys = KEYS,
    on_click = function(lnum)
      local e = state.entries[lnum]
      if e and (e.kind == 'dir' or e.kind == 'filter') then
        M.open(e)
      end
    end,
  }
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, desc = 'review-relay: ' .. desc })
  end
  map('<CR>', function()
    M.open()
  end, 'open')
  map('<Space>', function()
    M.toggle_reviewed()
  end, 'reviewed')
  map('r', function()
    M.reply()
  end, 'reply')
  map('s', function()
    M.resolve()
  end, 'resolve / reopen')
  map('f', function()
    M.open { kind = 'filter' }
  end, 'filter')
  map('R', function()
    M.refresh()
  end, 'refresh')
  map('q', function()
    vim.api.nvim_win_close(0, true)
  end, 'close')
  draw_panel()
  M.refresh()
end

local group = vim.api.nvim_create_augroup('devhub_review_relay', { clear = true })

-- A viewer this adapter started goes when Neovim does.
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    if state.server then
      state.endpoint = nil
      M.stop_server()
    end
  end,
})

--- Commands and autocommands. Called by plugin/devhub.lua's :ReviewRelay on
--- first use; call it yourself to change the options.
function M.setup(opts)
  M._setup = true
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWinEnter' }, {
    group = group,
    callback = function(ev)
      if state.endpoint and rel(ev.buf) then
        M.decorate_buffer(ev.buf)
      end
    end,
  })
  return M
end

--- Stop following the viewer, and take every card and sign away.
function M.stop()
  if state.events then
    pcall(vim.fn.jobstop, state.events)
    state.events = nil
  end
  for buf, cards in pairs(state.cards) do
    for _, handle in pairs(cards) do
      handle:clear()
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      map_inline_keys(buf, false)
    end
  end
  state.cards = {}
  state.endpoint = nil
  M.stop_server()
end

return M
