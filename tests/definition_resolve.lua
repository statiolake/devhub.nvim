-- The cell to the word (devhub.definition.resolve), in the child Neovim of
-- tests/definition_spec.lua: wrap, conceal, folds, inline virtual text.
-- Answers the failures.
local failures = {}
local function check(condition, message)
  if not condition then
    table.insert(failures, message)
  end
end
local def = require 'devhub.definition'
local win, buf = WIN, BUF
vim.cmd 'redraw'

-- Row 1 (line 2), col 7 is in `alpha` (cols 6-10).
local at = def.resolve(win, 1, 7)
check(at and at.lnum == 2 and at.s == 7 and at.e == 11, 'line 2, bytes 7-11')
check(at and #at.spans == 1 and at.spans[1].row == 1 and at.spans[1].col0 == 6 and at.spans[1].col1 == 10, 'its cells')
local pos = vim.api.nvim_win_get_position(win)
local same = def.resolve_screen(win, pos[1] + 2, pos[2] + 8)
check(same and same.key == (at and at.key), 'by the screen: the same word')
check(def.resolve(win, 1, 5) == nil, 'a parenthesis is no word')
check(def.resolve(win, 1, 30) == nil, 'past the line: nothing')
check(def.resolve(win, 15, 0) == nil, 'past the buffer: nothing')

-- Wrap: `alpha` on line 4 starts at col 37 and wraps onto row 4.
at = def.resolve(win, 4, 1)
check(at and at.lnum == 4 and at.s == 38, 'wrapped: the second row is the same word')
check(at and #at.spans == 2 and at.spans[1].row == 3 and at.spans[1].col0 == 37 and at.spans[2].row == 4 and at.spans[2].col0 == 0, 'wrapped: a span per row, got ' .. vim.inspect(at and at.spans))
-- Concealed characters before the word move its cells. screenpos() puts
-- `alpha` where it would be unconcealed: the screen shows other cells there,
-- so it is no link; and what is drawn there is not taken for the concealed
-- `x`s either.
vim.api.nvim_win_set_cursor(win, { 1, 0 })
vim.cmd [[syntax match Hidden /xxxxx/ conceal]]
vim.wo[win].conceallevel = 3
vim.cmd 'redraw'
check(def.resolve(win, 4, 1) == nil, 'concealed: no link where the screen shows something else')
check(def.resolve(win, 3, 0) == nil or def.resolve(win, 3, 0).s ~= 1, 'concealed text is no word')
vim.wo[win].conceallevel = 0
vim.cmd 'syntax clear Hidden'
vim.cmd 'redraw'

-- A closed fold is no symbol; the lines after it are where they are.
vim.wo[win].foldmethod = 'manual'
vim.cmd '5,6fold'
vim.cmd 'redraw'
check(def.resolve(win, 5, 7) == nil, 'a closed fold: nothing')
at = def.resolve(win, 6, 7)
check(at and at.lnum == 7 and at.s == 7, 'after the fold: line 7')
vim.cmd 'normal! zE'
vim.cmd 'redraw'

-- Inline virtual text: its cells are no word; the word after it moves.
local ns = vim.api.nvim_create_namespace 'spec'
vim.api.nvim_buf_set_extmark(buf, ns, 1, 6, { virt_text = { { 'HINT', 'Comment' } }, virt_text_pos = 'inline' })
vim.cmd 'redraw'
check(def.resolve(win, 1, 7) == nil, 'inline virtual text is no word')
at = def.resolve(win, 1, 11)
check(at and at.s == 7 and at.spans[1].col0 == 10, 'the word after inline virtual text')
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
vim.cmd 'redraw'

return failures
