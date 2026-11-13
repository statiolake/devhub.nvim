-- Go to definition with the pointer, as VS Code's Cmd-click: DevHub's half
-- (docs/neovim-editor.md, "Go to definition with the pointer").
--
-- While the person holds the modifier (`[editor] definition_modifier`,
-- Option/Alt by default) DevHub asks, for the cell under the pointer, whether
-- it is a symbol with a definition (`M.hover`); a symbol that has one is drawn
-- as a link by DevHub itself, over the cells this answers — nothing is put in
-- the buffer. A click with the modifier on it is `M.jump`: the cursor is put
-- on the symbol and `vim.lsp.buf.definition()` runs, so it is the same jump
-- as `:lua vim.lsp.buf.definition()` from there — the jumplist (`<C-o>`), the
-- tag stack (`<C-t>`), several results in the quickfix list, another file in
-- the same window.
--
-- Neovim's own: the screen cell is mapped to the buffer with `screenpos()`
-- (wrap, folds, conceal, inline virtual text and horizontal scrolling as
-- Neovim lays them out), the word is `iskeyword`'s, and the question is
-- `textDocument/definition` to every client of the buffer that has it. One
-- request at a time: a new word cancels the one in flight. Answers are kept
-- by buffer `changedtick` and word, so going back and forth over a line asks
-- each word once.
--
-- DevHub requires nothing of this module's presence: it asks
-- `package.loaded['devhub.definition']`, which devhub.nvim loads at the
-- first LspAttach in DevHub's GUI (`gui.hook_floats_on_lsp`). Without it (or
-- with `vim.g.devhub_definition_links = false`) the modifier's click is
-- Neovim's, as before.

local M = {}

local api = vim.api
local METHOD = 'textDocument/definition'

--- buf -> { tick = changedtick, words = { [key] = has_definition } }
local cache = {}
--- The request in flight: { buf, key, at, seq, cancel, jump }.
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
  local buf = api.nvim_win_get_buf(win)
  return api.nvim_win_call(win, function()
    local pos = api.nvim_win_get_position(win)
    local R, C = pos[1] + row + 1, pos[2] + col + 1
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

local function tell(payload)
  local core = package.loaded['devhub_gui']
  if core and core._chan and core._event then
    pcall(core._event, 'definition_link', payload)
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
  -- jump `vim.lsp.buf.definition()` makes from there.
  api.nvim_win_set_cursor(win, { at.lnum, at.s - 1 })
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

local function ask(win, at, seq)
  M.cancel()
  local buf = at.buf
  local tick = api.nvim_buf_get_changedtick(buf)
  local request = { buf = buf, key = at.key, at = at, seq = seq, win = win }
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
    if inflight ~= request then
      return
    end
    inflight = nil
    tell { seq = request.seq, win = request.win, link = has, spans = at.spans }
    if has and request.jump then
      go(request.win, at)
    end
  end)
  return request
end

--- Whether window `win`'s cell is a symbol with a definition, for the link
--- DevHub draws while the modifier is held. Answers false when it is not a
--- keyword in a buffer with a definition provider (or not in Normal or
--- Insert mode): the modifier's click is then Neovim's. Else
--- { seq, spans, link = true | false }, or { seq, spans, pending = true }
--- and later the GUI event `definition_link` { seq, win, spans, link }.
function M.hover(seq, win, row, col)
  if not enabled() or not mode_ok() then
    M.cancel()
    return false
  end
  local ok, at = pcall(M.resolve, win, row, col)
  if not ok or not at or #clients(at.buf) == 0 then
    M.cancel()
    return false
  end
  local known = cached(at.buf, at.key)
  if known ~= nil then
    M.cancel()
    return { seq = seq, spans = at.spans, link = known }
  end
  if inflight and inflight.buf == at.buf and inflight.key == at.key then
    -- The same word, asked again: the answer goes to the newest ask.
    inflight.seq = seq
    inflight.win = win
    return { seq = seq, spans = at.spans, pending = true }
  end
  ask(win, at, seq)
  return { seq = seq, spans = at.spans, pending = true }
end

--- The modifier's click on window `win`'s cell: the jump, when it is a
--- symbol with a definition (at once when known, else when the answer
--- comes). Answers whether the click is taken (it is a symbol in a buffer
--- with a definition provider); DevHub has already decided whether it
--- passed the click to Neovim.
function M.jump(win, row, col)
  if not enabled() or not mode_ok() then
    return false
  end
  local ok, at = pcall(M.resolve, win, row, col)
  if not ok or not at or #clients(at.buf) == 0 then
    return false
  end
  local known = cached(at.buf, at.key)
  if known == true then
    M.cancel()
    go(win, at)
    return true
  end
  if known == false then
    return false
  end
  local request = inflight
  if not (request and request.buf == at.buf and request.key == at.key) then
    request = ask(win, at, 0)
  end
  request.jump = true
  request.win = win
  return true
end

--- Forget every answer kept (the tests; a server restarted).
function M.clear()
  M.cancel()
  cache = {}
end

vim.api.nvim_create_autocmd({ 'LspDetach', 'BufWipeout' }, {
  group = vim.api.nvim_create_augroup('devhub_definition', { clear = true }),
  callback = function(event)
    cache[event.buf] = nil
  end,
})

return M
