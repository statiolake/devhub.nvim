-- nvim --headless: devhub.source, the which-file-at-which-revision convention.
local failures = {}
local function check(condition, message)
  if not condition then
    table.insert(failures, message)
  end
end

local source = require 'devhub.source'
local repo = vim.fn.tempname()
vim.fn.mkdir(repo .. '/src', 'p')
vim.fn.system { 'git', '-C', repo, 'init', '-q' }
vim.fn.writefile({ 'one' }, repo .. '/src/a.txt')
local root = vim.uv.fs_realpath(repo)

-- An ordinary file buffer is the work tree's, derived.
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/src/a.txt'))
local file = vim.api.nvim_get_current_buf()
local got = source.get(file)
check(got and got.root == root and got.path == 'src/a.txt' and got.rev == 'worktree', 'file buffer: ' .. vim.inspect(got))
check(source.is_worktree(got), 'file buffer is the work tree')

-- Outside a repository, and scratch buffers: none.
vim.cmd 'enew'
check(source.get(0) == nil, 'scratch buffer has no source')
vim.cmd('edit ' .. vim.fn.fnameescape(vim.fn.tempname()))
check(source.get(0) == nil, 'file outside git has no source')

-- A producer's revision buffer, and the event.
local events = {}
vim.api.nvim_create_autocmd('User', {
  pattern = source.event,
  callback = function(ev)
    table.insert(events, ev.data)
  end,
})
local rev = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(rev, 'example://' .. string.rep('a', 40) .. '/src/a.txt')
local sha = string.rep('a', 40)
source.set(rev, { root = repo, path = 'src/a.txt', rev = sha, label = 'main' })
check(#events == 1 and events[1].buf == rev and events[1].source.rev == sha, 'event: ' .. vim.inspect(events))
check(source.get(rev).root == root, 'root resolved')
check(not source.is_worktree(source.get(rev)), 'revision is not the work tree')
local snap = vim.api.nvim_create_buf(false, true)
source.set(snap, { root = root, path = 'src/a.txt', blob = string.rep('b', 40) })
check(source.get(snap).rev == nil and source.get(snap).blob ~= nil, 'blob-only source')

local all = source.list { root = repo, path = 'src/a.txt' }
check(#all == 3, 'list finds the file and both revisions: ' .. #all)
check(#source.list { rev = 'worktree' } == 1, 'list by rev')

-- Malformed sources are refused; clearing fires with nil.
check(not pcall(source.set, rev, { root = 'rel', path = 'a' }), 'relative root refused')
check(not pcall(source.set, rev, { root = root, path = 'a', rev = 'HEAD' }), 'symbolic rev refused')
check(not pcall(source.set, rev, { root = root, path = 'a' }), 'rev or blob required')
source.set(rev, nil)
check(source.get(rev) == nil and events[#events].source == nil, 'cleared')

vim.fn.delete(repo, 'rf')
if #failures > 0 then
  error(table.concat(failures, '\n  '))
end
print 'source: ok'
