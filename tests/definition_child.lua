-- The Neovim tests/definition_spec.lua drives over RPC, as DevHub drives
-- its Neovim: a stand-in for DevHub's `devhub_gui` that records the
-- overlays, a fake language server, and a buffer to point at.
_G.OVERLAYS = {}
package.loaded['devhub_gui'] = {
  _chan = 1,
  overlay = function(opts)
    table.insert(OVERLAYS, vim.deepcopy(opts))
  end,
}

-- A language server in this process: `alpha` (anywhere) is defined at line
-- 1, column 6; `twice` has two definitions; nothing else has one. Answers
-- come on the next tick, or after `delay` ms.
_G.SERVER = { requests = {}, cancelled = {}, delay = 0 }
function _G.FAKE(dispatchers)
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
        table.insert(SERVER.requests, params)
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
          if SERVER.cancelled[this] then
            callback({ code = -32800, message = 'cancelled' }, nil)
          else
            callback(nil, result)
          end
        end
        if SERVER.delay > 0 then
          vim.defer_fn(answer, SERVER.delay)
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
        SERVER.cancelled[params.id] = true
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

-- Clicks a test makes apart are never one double click.
vim.o.mousetime = 20
vim.o.columns = 40
vim.o.lines = 20
vim.wo.number = false
vim.wo.signcolumn = 'no'
vim.wo.wrap = true
_G.BUF = vim.api.nvim_get_current_buf()
_G.WIN = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_name(BUF, vim.fn.tempname() .. '.lua')
vim.api.nvim_buf_set_lines(BUF, 0, -1, false, {
  'local alpha = 1', -- 1
  'print(alpha)', -- 2
  'print(twice, beta)', -- 3
  string.rep('x', 36) .. ' alpha', -- 4: alpha wraps onto the next row
  'folded alpha', -- 5
  'folded too', -- 6
  'after alpha', -- 7
})
vim.cmd 'redraw'

-- As devhub.nvim does at the first LspAttach in DevHub's GUI.
require('devhub.definition').map()
