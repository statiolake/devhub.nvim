-- nvim --headless: the pointer's go to definition (lua/devhub/definition.lua)
-- against a fake language server: the screen cell to the word, the word to
-- `textDocument/definition`, the answers kept by changedtick and word, the
-- request in flight cancelled by the next word, and the jump.
local failures = {}
local function check(condition, message)
  if not condition then
    table.insert(failures, message)
  end
end

-- What DevHub would inject: the GUI events, recorded.
local events = {}
package.loaded['devhub_gui'] = {
  _chan = 1,
  _event = function(kind, payload)
    if kind == 'definition_link' then
      table.insert(events, payload)
    end
  end,
}

-- A language server in this process: `alpha` (anywhere) is defined at line
-- 1, column 6; `twice` has two definitions; nothing else has one. Answers
-- come on the next tick, or after `delay` ms.
local server = { requests = {}, cancelled = {}, delay = 0 }
local function fake(dispatchers)
  local closing = false
  local id = 0
  return {
    request = function(method, params, callback)
      id = id + 1
      local this = id
      if method == 'initialize' then
        vim.schedule(function()
          callback(nil, { capabilities = { definitionProvider = true, positionEncoding = 'utf-16' } })
        end)
        return true, this
      end
      if method == 'textDocument/definition' then
        table.insert(server.requests, params)
        local uri = params.textDocument.uri
        local buf = vim.uri_to_bufnr(uri)
        local line = vim.api.nvim_buf_get_lines(buf, params.position.line, params.position.line + 1, false)[1] or ''
        local word = line:sub(params.position.character + 1):match '^[%w_]+'
        local result = nil
        if word == 'alpha' then
          result = { uri = uri, range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 11 } } }
        elseif word == 'twice' then
          result = {
            { uri = uri, range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 } } },
            { uri = uri, range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 5 } } },
          }
        end
        local function answer()
          if server.cancelled[this] then
            callback({ code = -32800, message = 'cancelled' }, nil)
          else
            callback(nil, result)
          end
        end
        if server.delay > 0 then
          vim.defer_fn(answer, server.delay)
        else
          vim.schedule(answer)
        end
        return true, this
      end
      vim.schedule(function()
        callback(nil, nil)
      end)
      return true, this
    end,
    notify = function(method, params)
      if method == '$/cancelRequest' then
        server.cancelled[params.id] = true
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

local def = require 'devhub.definition'

vim.o.columns = 40
vim.o.lines = 20
vim.wo.number = false
vim.wo.signcolumn = 'no'
vim.wo.wrap = true
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '.lua')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  'local alpha = 1', -- 1
  'print(alpha)', -- 2
  'print(twice, beta)', -- 3
  string.rep('x', 36) .. ' alpha', -- 4: alpha wraps onto the next row
  'folded alpha', -- 5
  'folded too', -- 6
  'after alpha', -- 7
})
local win = vim.api.nvim_get_current_win()
-- What the screen shows is checked against the buffer (conceal): drawn.
vim.cmd 'redraw'

local function wait_for(fn, what)
  if not vim.wait(1000, fn, 5) then
    table.insert(failures, 'timed out: ' .. what)
    return false
  end
  return true
end

-- No client yet: the modifier's click is Neovim's.
check(def.hover(1, win, 1, 7) == false, 'no client: false')

local client = vim.lsp.start { name = 'fake', cmd = fake, root_dir = vim.fn.getcwd() }
wait_for(function()
  return #vim.lsp.get_clients { bufnr = buf, method = 'textDocument/definition' } > 0
end, 'the fake client attaches')

-- 1. The cell to the word: row 1 (line 2), col 7 is in `alpha` (cols 6-10).
local at = def.resolve(win, 1, 7)
check(at and at.lnum == 2 and at.s == 7 and at.e == 11, 'resolve: line 2, bytes 7-11')
check(at and #at.spans == 1 and at.spans[1].row == 1 and at.spans[1].col0 == 6 and at.spans[1].col1 == 10, 'resolve: its cells')
check(def.resolve(win, 1, 5) == nil, 'a parenthesis is no word')
check(def.resolve(win, 1, 30) == nil, 'past the line: nothing')
check(def.resolve(win, 15, 0) == nil, 'past the buffer: nothing')

-- 2. A symbol with a definition: asked, then told.
local answer = def.hover(1, win, 1, 7)
check(type(answer) == 'table' and answer.pending == true and answer.seq == 1, 'first ask is pending')
wait_for(function()
  return #events == 1
end, 'the definition_link event')
check(events[1] and events[1].seq == 1 and events[1].link == true and events[1].win == win, 'told: a link')
check(events[1] and events[1].spans[1].col0 == 6, 'told with its cells')
check(#server.requests == 1, 'one request')
check(server.requests[1] and server.requests[1].position.line == 1 and server.requests[1].position.character == 6, 'asked at the word')

-- 3. Asked again, anywhere on the word: kept, no request.
answer = def.hover(2, win, 1, 10)
check(type(answer) == 'table' and answer.link == true and answer.seq == 2 and not answer.pending, 'kept: a link at once')
check(#server.requests == 1, 'no second request for the same word')

-- 4. A word with no definition.
events = {}
answer = def.hover(3, win, 1, 2)
check(answer and answer.pending, '`print` is asked')
wait_for(function()
  return #events == 1
end, 'print answered')
check(events[1] and events[1].link == false, '`print` has no definition')
answer = def.hover(4, win, 1, 0)
check(answer and answer.link == false and not answer.pending, 'kept: no definition')

-- 5. The next word cancels the request in flight; only the newest is told.
events = {}
server.delay = 60
local before = #server.requests
def.hover(5, win, 2, 7) -- `twice`
def.hover(6, win, 2, 14) -- `beta`
check(#server.requests == before + 2, 'each word asked')
wait_for(function()
  return #events >= 1
end, 'the newest answered')
vim.wait(150)
check(#events == 1 and events[1].seq == 6 and events[1].link == false, 'only the newest ask is told')
local cancels = 0
for _ in pairs(server.cancelled) do
  cancels = cancels + 1
end
check(cancels >= 1, 'the stale request cancelled')
-- Its answer was not kept either (it was cancelled): asked again.
events = {}
answer = def.hover(7, win, 2, 7)
check(answer and answer.pending, 'a cancelled word is asked again')
wait_for(function()
  return #events == 1
end, 'twice answered')
check(events[1] and events[1].link == true, '`twice` has definitions')
server.delay = 0

-- 6. An edit: the answers are asked again.
before = #server.requests
vim.api.nvim_buf_set_lines(buf, 7, 7, false, { '' })
answer = def.hover(8, win, 1, 7)
check(answer and answer.pending, 'a new changedtick asks again')
wait_for(function()
  return #server.requests == before + 1
end, 'asked after the edit')
vim.api.nvim_buf_set_lines(buf, 7, 8, false, {})
vim.wait(50)

-- 7. Wrap: `alpha` on line 4 starts at col 37 and wraps onto row 4.
at = def.resolve(win, 4, 1)
check(at and at.lnum == 4 and at.s == 38, 'wrapped: the second row is the same word')
check(at and #at.spans == 2 and at.spans[1].row == 3 and at.spans[1].col0 == 37 and at.spans[2].row == 4 and at.spans[2].col0 == 0, 'wrapped: a span per row, got ' .. vim.inspect(at and at.spans))
-- Concealed characters before the word move its cells.
vim.api.nvim_win_set_cursor(win, { 1, 0 })
vim.cmd [[syntax match Hidden /xxxxx/ conceal]]
vim.wo.conceallevel = 3
vim.cmd 'redraw'
-- screenpos() puts `alpha` where it would be unconcealed: the screen shows
-- other cells there, so it is no link; and what is drawn there is not taken
-- for the concealed `x`s either.
check(def.resolve(win, 4, 1) == nil, 'concealed: no link where the screen shows something else')
check(def.resolve(win, 3, 0) == nil or def.resolve(win, 3, 0).s ~= 1, 'concealed text is no word')
vim.wo.conceallevel = 0
vim.cmd 'syntax clear Hidden'
vim.cmd 'redraw'

-- 8. A closed fold is no symbol; the lines after it are where they are.
vim.wo.foldmethod = 'manual'
vim.cmd '5,6fold'
vim.cmd 'redraw'
check(def.resolve(win, 5, 7) == nil, 'a closed fold: nothing')
at = def.resolve(win, 6, 7)
check(at and at.lnum == 7 and at.s == 7, 'after the fold: line 7')
vim.cmd 'normal! zE'
vim.cmd 'redraw'

-- 9. Inline virtual text: its cells are no word; the word after it moves.
local ns = vim.api.nvim_create_namespace 'spec'
vim.api.nvim_buf_set_extmark(buf, ns, 1, 6, { virt_text = { { 'HINT', 'Comment' } }, virt_text_pos = 'inline' })
vim.cmd 'redraw'
check(def.resolve(win, 1, 7) == nil, 'inline virtual text is no word')
at = def.resolve(win, 1, 11)
check(at and at.s == 7 and at.spans[1].col0 == 10, 'the word after inline virtual text')
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
vim.cmd 'redraw'

-- 10. Visual mode: Neovim's click.
vim.cmd 'normal! v'
check(def.hover(9, win, 1, 7) == false, 'Visual: false')
vim.cmd 'normal! \27'

-- 11. The jump: as vim.lsp.buf.definition from the word, with the jumplist.
vim.api.nvim_win_set_cursor(win, { 3, 0 })
check(def.jump(win, 1, 7) == true, 'jump taken')
wait_for(function()
  local c = vim.api.nvim_win_get_cursor(win)
  return c[1] == 1 and c[2] == 6
end, 'the cursor at the definition')
vim.cmd 'normal! \15' -- <C-o>
local c = vim.api.nvim_win_get_cursor(win)
check(c[1] == 2 and c[2] == 6, '<C-o> back to the clicked word, got ' .. vim.inspect(c))
-- Several definitions: the quickfix list, as vim.lsp.buf.definition.
def.jump(win, 2, 7)
wait_for(function()
  return #vim.fn.getqflist() == 2
end, 'two definitions in the quickfix list')
vim.cmd 'cclose'
vim.api.nvim_set_current_win(win)
-- No definition: nothing taken, the cursor kept.
vim.api.nvim_win_set_cursor(win, { 3, 0 })
def.jump(win, 1, 2) -- `print`, not known since the edit: asked
vim.wait(50)
c = vim.api.nvim_win_get_cursor(win)
check(c[1] == 3 and c[2] == 0, 'no definition: the cursor kept')
check(def.jump(win, 1, 2) == false, 'known to have no definition: not taken')
-- A jump asked before the hover's answer: made when it comes.
def.clear()
vim.api.nvim_win_set_cursor(win, { 3, 0 })
check(def.jump(win, 1, 8) == true, 'a jump before the answer is taken')
wait_for(function()
  local cur = vim.api.nvim_win_get_cursor(win)
  return cur[1] == 1 and cur[2] == 6
end, 'jumped when the answer came')

-- 12. setup{ definition_jump }: called with the cursor on the symbol,
-- instead of vim.lsp.buf.definition (no request, the cursor stays there).
local seen
local devhub = require 'devhub'
devhub.config.definition_jump = function(ctx)
  seen = { ctx = ctx, cursor = vim.api.nvim_win_get_cursor(0) }
end
before = #server.requests
vim.api.nvim_win_set_cursor(win, { 3, 0 })
check(def.jump(win, 1, 8) == true, 'a custom jump is taken')
wait_for(function()
  return seen ~= nil
end, 'the custom jump called')
check(seen and seen.ctx.buf == buf and seen.ctx.win == win and seen.ctx.lnum == 2 and seen.ctx.col == 6, 'ctx: buf, win, lnum, col, got ' .. vim.inspect(seen and seen.ctx))
check(seen and seen.cursor[1] == 2 and seen.cursor[2] == 6, 'called with the cursor on the symbol')
vim.wait(50)
local c2 = vim.api.nvim_win_get_cursor(win)
check(c2[1] == 2 and c2[2] == 6, 'vim.lsp.buf.definition not run as well')
-- An error in it is said, not raised into DevHub's call.
devhub.config.definition_jump = function()
  error 'boom'
end
check(pcall(def.jump, win, 1, 8), 'a failing custom jump does not raise')
devhub.config.definition_jump = nil

-- 13. Turned off: Neovim's click.
vim.g.devhub_definition_links = false
check(def.hover(10, win, 1, 7) == false, 'turned off: false')
vim.g.devhub_definition_links = nil

vim.lsp.get_client_by_id(client):stop(true)

if #failures > 0 then
  error(table.concat(failures, '\n  '), 0)
end
print 'definition: ok'
