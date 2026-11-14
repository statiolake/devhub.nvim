-- Go to definition with the pointer, as VS Code's Cmd-hover and Cmd-click,
-- as ordinary Neovim mappings (docs/neovim-editor.md in DevHub, "Go to
-- definition with the pointer").
--
--   * `M.click`, mapped to <A-LeftMouse>: the symbol under the mouse
--     (`getmousepos()`) is a definition's, and the cursor is put on it and
--     `vim.lsp.buf.definition()` runs (or `require('devhub').setup {
--     definition_jump = fn }`'s), so it is the same jump as typed there:
--     the jumplist (<C-o>), the tag stack, the quickfix list for several,
--     another file in the same window. Anywhere else the press is what
--     Neovim does with it unmapped (fed again, `noremap`): with Alt, a
--     blockwise Visual start.
--   * `M.hover`, mapped to <A-MouseMove>: while Alt is held DevHub sends the
--     pointer's moves as mouse moves with it, and a symbol with a
--     definition under it is drawn as a link (`gui.overlay`: underlined in
--     `@markup.link`'s ink, the hand over it, `held` so it goes in the frame
--     Alt goes up). Any other key — the plain <MouseMove> that says Alt went
--     up among them — takes it away (`vim.on_key`).
--
-- Both are mapped in Normal and Insert mode, in DevHub's GUI, unless you
-- mapped the key yourself (`M.map`); map others to them for another
-- modifier (`<D-LeftMouse>`, `<D-MouseMove>`), or set
-- `vim.g.devhub_definition_links = false` before the first LspAttach for
-- none. Loaded at the first LspAttach in DevHub's GUI
-- (`gui.hook_floats_on_lsp`).
--
-- Neovim's own: the screen cell is mapped to the buffer with `screenpos()`
-- (wrap, folds, conceal, inline virtual text and horizontal scrolling as
-- Neovim lays them out), the word is `iskeyword`'s, and the question is
-- `textDocument/definition` to every client of the buffer that has it. One
-- request at a time: a new word cancels the one in flight. Answers are kept
-- by buffer `changedtick` and word, so going back and forth over a line asks
-- each word once.

local M = {}

local api = vim.api
local METHOD = 'textDocument/definition'

--- buf -> { tick = changedtick, words = { [key] = has_definition } }
local cache = {}
--- The request in flight: { buf, key, at, win, cancel, done, has, clicked }.
local inflight

--- How many requests were sent, for the tests.
M._sent = 0

local function enabled()
  return vim.g.devhub_definition_links ~= false
end

local function clients(buf)
  return vim.lsp.get_clients { bufnr = buf, method = METHOD }
end

--- Normal and Insert mode only: in Visual, Operator-pending, the command
--- line and the rest, the modifier's click is Neovim's.
local function mode_ok()
  local mode = api.nvim_get_mode().mode
  return mode == 'n' or mode:sub(1, 1) == 'i'
end

local function char_end(text, b)
  return b + vim.str_utf_end(text, b)
end

local function prev_start(text, b)
  if b <= 1 then
    return nil
  end
  return b - 1 + vim.str_utf_start(text, b - 1)
end

--- The rows line `l` takes on the screen (1-based, the screen's), from the
--- first and last of its characters Neovim shows; nil when none is shown.
local function line_rows(win, l, text, leftcol)
  local first = vim.fn.screenpos(win, l, 1).row
  if first == 0 and leftcol > 0 then
    local b = vim.fn.virtcol2col(win, l, leftcol + 1)
    if b > 0 then
      first = vim.fn.screenpos(win, l, b).row
    end
  end
  local last = #text > 0 and vim.fn.screenpos(win, l, #text).row or first
  if first == 0 then
    first = last
  end
  if last == 0 then
    last = first
  end
  if first == 0 then
    return nil
  end
  return first, last
end

--- Window `win`'s grid cell (`row`, `col`, 0-based, as DevHub's grid for the
--- window has it) as the keyword there: { buf, lnum, s, e (byte columns,
--- 1-based, inclusive), key, spans (the cells it is drawn in, by row) }, or
--- nil when no keyword's character is drawn in that cell.
function M.resolve(win, row, col)
  if not api.nvim_win_is_valid(win) then
    return nil
  end
  local pos = api.nvim_win_get_position(win)
  return M.resolve_screen(win, pos[1] + row + 1, pos[2] + col + 1)
end

--- The same for the screen's cell `R`, `C` (1-based, as `getmousepos()`'s
--- screenrow and screencol) in window `win`.
function M.resolve_screen(win, R, C)
  if not api.nvim_win_is_valid(win) then
    return nil
  end
  local buf = api.nvim_win_get_buf(win)
  return api.nvim_win_call(win, function()
    local pos = api.nvim_win_get_position(win)
    local info = vim.fn.getwininfo(win)[1]
    if not info then
      return nil
    end
    local leftcol = vim.fn.winsaveview().leftcol
    local count = api.nvim_buf_line_count(buf)
    local last = math.min(count, info.botline + 1)
    local l, lnum, text = info.topline, nil, nil
    while l <= last do
      local fold_end = vim.fn.foldclosedend(l)
      if fold_end ~= -1 then
        -- A closed fold's line is no symbol.
        local r = vim.fn.screenpos(win, l, 1).row
        if r >= R then
          return nil
        end
        l = fold_end + 1
      else
        local t = api.nvim_buf_get_lines(buf, l - 1, l, true)[1]
        local first, final = line_rows(win, l, t, leftcol)
        if first then
          if R < first then
            return nil
          end
          if R <= final then
            lnum, text = l, t
            break
          end
        end
        l = l + 1
      end
    end
    if not lnum then
      return nil
    end
    -- A character's own cells: screenpos() counts the inline virtual text
    -- before it as its own (`col` is where that text starts), so they are
    -- the last of its `col`..`endcol`, as wide as the character (a tab is
    -- all of them).
    local function cells(b)
      local sp = vim.fn.screenpos(win, lnum, b)
      if sp.row == 0 then
        return nil
      end
      local ch = text:sub(b, char_end(text, b))
      local first = sp.col
      if ch ~= '\t' then
        first = math.max(sp.col, sp.endcol - vim.fn.strdisplaywidth(ch) + 1)
      end
      return sp.row, first, sp.endcol, ch
    end
    -- The character drawn in the cell.
    local hit
    local b = 1
    while b <= #text do
      local r, c0, c1 = cells(b)
      if r == R and C >= c0 and C <= c1 then
        hit = b
        break
      end
      if r and r > R then
        break
      end
      b = char_end(text, b) + 1
    end
    if not hit then
      return nil
    end
    local function keyword(at)
      local ch = text:sub(at, char_end(text, at))
      return vim.fn.match(ch, [[^\k\+$]]) == 0
    end
    if not keyword(hit) then
      return nil
    end
    local s, e = hit, hit
    while true do
      local p = prev_start(text, s)
      if not p or not keyword(p) then
        break
      end
      s = p
    end
    while true do
      local n = char_end(text, e) + 1
      if n > #text or not keyword(n) then
        break
      end
      e = n
    end
    -- Its cells, row by row (a word can wrap), in the window's grid.
    -- screenpos() does not know concealed text: a character shown as
    -- something else (or not at all) is no link, by what the screen shows.
    local spans = {}
    local c = s
    local drawn, blank = true, true
    while c <= e do
      local sr, sc0, sc1, ch = cells(c)
      if sr then
        local shown = vim.fn.screenstring(sr, sc0)
        if shown ~= '' and shown ~= ' ' then
          blank = false
        end
        if shown ~= ch then
          drawn = false
        end
        local r, c0, c1 = sr - 1 - pos[1], sc0 - 1 - pos[2], sc1 - 1 - pos[2]
        local prev = spans[#spans]
        if prev and prev.row == r and prev.col1 + 1 >= c0 then
          prev.col1 = math.max(prev.col1, c1)
        else
          table.insert(spans, { row = r, col0 = c0, col1 = c1 })
        end
      end
      c = char_end(text, c) + 1
    end
    -- A screen with nothing on it (not drawn yet) says nothing either way.
    if not drawn and not blank then
      return nil
    end
    return {
      buf = buf,
      lnum = lnum,
      s = s,
      e = e,
      key = lnum .. ':' .. s .. ':' .. text:sub(s, e),
      spans = spans,
    }
  end)
end

local function cached(buf, key)
  local entry = cache[buf]
  if not entry then
    return nil
  end
  if entry.tick ~= api.nvim_buf_get_changedtick(buf) then
    cache[buf] = nil
    return nil
  end
  return entry.words[key]
end

local function remember(buf, tick, key, has)
  local entry = cache[buf]
  if not entry or entry.tick ~= tick then
    entry = { tick = tick, words = {} }
    cache[buf] = entry
  end
  entry.words[key] = has
end

local function has_location(result)
  if type(result) ~= 'table' then
    return false
  end
  return result.uri ~= nil or result.targetUri ~= nil or #result > 0
end

--- The overlay's id (`gui.overlay`).
local ID = 'devhub.definition'
--- How long a click waits for an answer still coming before it is
--- Neovim's click after all.
M.click_wait_ms = 500

--- The link is drawn; the mouse is over windows with the modifier held.
local shown, hovering = false, false
--- The last key typed, as `vim.on_key` saw it before its mapping ran: the
--- press a click falls back to.
local last_typed
--- The press that was a jump, while its drag and release are to be dropped.
local swallow

local function overlay(opts)
  local gui = package.loaded['devhub.gui'] or require 'devhub.gui'
  if gui.overlay then
    pcall(gui.overlay, opts)
  end
end

--- `@markup.link`'s ink, else `Underlined`'s, underlined.
local function link_hl()
  for _, name in ipairs { '@markup.link', 'Underlined' } do
    local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl.fg then
      return { fg = hl.fg, underline = true }
    end
  end
  return { underline = true }
end

local function draw(win, at)
  shown = true
  local spans = {}
  for _, s in ipairs(at.spans) do
    table.insert(spans, { row = s.row, col0 = s.col0, col1 = s.col1 })
  end
  overlay { id = ID, win = win, spans = spans, hl = link_hl(), pointer = 'pointer', held = true }
end
M._draw = draw

local function undraw()
  if shown then
    shown = false
    overlay { id = ID }
  end
end

local function go(win, at)
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= at.buf then
    return
  end
  if not mode_ok() then
    return
  end
  if api.nvim_get_current_win() ~= win then
    api.nvim_set_current_win(win)
  end
  -- The cursor on the symbol, as a click there would put it, and then the
  -- jump from there: setup{ definition_jump } (your definition key's
  -- action), else `vim.lsp.buf.definition()`.
  api.nvim_win_set_cursor(win, { at.lnum, at.s - 1 })
  local devhub = package.loaded['devhub']
  local jump = devhub and devhub.config and devhub.config.definition_jump
  if type(jump) == 'function' then
    local ok, err = pcall(jump, { buf = at.buf, win = win, lnum = at.lnum, col = at.s - 1 })
    if not ok then
      vim.notify('devhub: definition_jump: ' .. tostring(err), vim.log.levels.WARN)
    end
    return
  end
  vim.lsp.buf.definition()
end
M._go = go

--- The request in flight, cancelled (its answer is dropped).
function M.cancel()
  local current = inflight
  inflight = nil
  if current and current.cancel then
    pcall(current.cancel)
  end
end

local function ask(win, at)
  M.cancel()
  local buf = at.buf
  local tick = api.nvim_buf_get_changedtick(buf)
  local request = { buf = buf, key = at.key, at = at, win = win }
  inflight = request
  M._sent = M._sent + 1
  request.cancel = vim.lsp.buf_request_all(buf, METHOD, function(client)
    return {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = {
        line = at.lnum - 1,
        character = vim.lsp.util.character_offset(buf, at.lnum - 1, at.s - 1, client.offset_encoding),
      },
    }
  end, function(results)
    local has, failed = false, false
    for _, res in pairs(results or {}) do
      if res and has_location(res.result) then
        has = true
      elseif res and (res.err or res.error) then
        failed = true
      end
    end
    -- An error (a cancelled request among them) is not an answer to keep.
    if api.nvim_buf_is_valid(buf) and (has or not failed) then
      remember(buf, tick, at.key, has)
    end
    request.done, request.has = true, has
    if inflight ~= request then
      return
    end
    inflight = nil
    if has and hovering and not request.clicked then
      draw(request.win, at)
    end
  end)
  return request
end

--- The symbol under the mouse: (win, at), or nil when it is no word of a
--- buffer with a definition provider.
local function under_mouse()
  local p = vim.fn.getmousepos()
  if p.winid == 0 then
    return nil
  end
  local ok, at = pcall(M.resolve_screen, p.winid, p.screenrow, p.screencol)
  if not ok or not at or #clients(at.buf) == 0 then
    return nil
  end
  return p.winid, at
end

--- The link taken away; with `keep`, the request in flight is kept (a
--- click is coming that wants its answer).
function M.leave(keep)
  hovering = false
  undraw()
  if not keep then
    M.cancel()
  end
end

--- <A-MouseMove>: the symbol under the mouse drawn as a link when it has a
--- definition (at once when known, else when the answer comes).
function M.hover()
  if not enabled() or not mode_ok() then
    return M.leave()
  end
  hovering = true
  local win, at = under_mouse()
  if not win then
    M.cancel()
    return undraw()
  end
  local known = cached(at.buf, at.key)
  if known ~= nil then
    M.cancel()
    if known then
      return draw(win, at)
    end
    return undraw()
  end
  if inflight and inflight.buf == at.buf and inflight.key == at.key then
    inflight.win = win
    return
  end
  undraw()
  ask(win, at)
end

--- What Neovim does with the press unmapped: the key typed, fed again
--- without mappings (Alt's: a blockwise Visual start), at the mouse
--- position it has.
local function neovims_click()
  local key = last_typed
  if not key or not vim.fn.keytrans(key):match 'Mouse>$' then
    key = vim.keycode '<A-LeftMouse>'
  end
  api.nvim_feedkeys(key, 'n', false)
end

--- <A-LeftMouse>: the jump, when the symbol under the mouse has a
--- definition; else Neovim's own click. An answer still coming is waited
--- for (`M.click_wait_ms` at most), so the press is one or the other before
--- the drag and the release that follow it are taken.
function M.click()
  if not enabled() or not mode_ok() then
    return neovims_click()
  end
  local win, at = under_mouse()
  if not win then
    return neovims_click()
  end
  local known = cached(at.buf, at.key)
  if known == nil then
    local request = inflight
    if not (request and request.buf == at.buf and request.key == at.key) then
      request = ask(win, at)
    end
    request.clicked = true
    vim.wait(M.click_wait_ms, function()
      return request.done == true
    end, 5)
    if not request.done then
      M.cancel()
    end
    known = request.has == true
  end
  if not known then
    return neovims_click()
  end
  M.leave()
  -- The press was the jump: its drag and release are nothing (Neovim's own
  -- would start a Visual from the symbol while the jump is on its way).
  swallow = last_typed
  go(win, at)
end

--- The defaults, in Normal and Insert mode, unless the key is mapped
--- already: <A-LeftMouse> to `M.click`, <A-MouseMove> to `M.hover`.
function M.map()
  for _, mode in ipairs { 'n', 'i' } do
    if vim.fn.maparg('<A-LeftMouse>', mode) == '' then
      vim.keymap.set(mode, '<A-LeftMouse>', M.click, { desc = 'devhub: go to definition' })
    end
    if vim.fn.maparg('<A-MouseMove>', mode) == '' then
      vim.keymap.set(mode, '<A-MouseMove>', M.hover, { desc = 'devhub: definition link' })
    end
  end
end

--- Forget every answer kept (the tests; a server restarted).
function M.clear()
  M.leave()
  cache = {}
end

-- Any key but a move with a modifier takes the link away: the plain
-- <MouseMove> DevHub sends when the modifier goes up, a key typed, a
-- click, the wheel. A press keeps the request (its click wants it).
local ns = api.nvim_create_namespace 'devhub_definition'
vim.on_key(function(key, typed)
  local k = (typed and typed ~= '') and typed or key
  if swallow then
    local name = vim.fn.keytrans(k)
    local button = name:match '(%a+)Drag>$' or name:match '(%a+)Release>$'
    if button and vim.fn.keytrans(swallow):match(button .. 'Mouse>$') then
      if name:match 'Release>$' then
        swallow = nil
      end
      return ''
    end
    swallow = nil
  end
  last_typed = k
  if not hovering then
    return
  end
  local name = vim.fn.keytrans(k)
  if name:match '^<[%a%-]+%-MouseMove>$' then
    return
  end
  pcall(M.leave, name:match 'Mouse>$' ~= nil)
end, ns)

vim.api.nvim_create_autocmd({ 'LspDetach', 'BufWipeout' }, {
  group = vim.api.nvim_create_augroup('devhub_definition', { clear = true }),
  callback = function(event)
    cache[event.buf] = nil
  end,
})

return M
