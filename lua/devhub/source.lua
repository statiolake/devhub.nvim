-- require('devhub.source'): which file, at which revision, a buffer shows.
--
-- A convention between plugins that show files (diff views, history
-- browsers, blame) and plugins that attach things to a file's lines (review
-- threads, coverage, notes), so neither has to know the other:
--
--   * A buffer that shows a file at a revision holds exactly that file's
--     lines, one buffer line per file line. Anything else it shows (deleted
--     lines of an inline diff, banners, cards) is extmarks / virt_lines,
--     never real lines. So line N of the buffer is line N of the file there.
--   * It carries b:devhub_source = { root, path, rev, blob?, label? }:
--       root  absolute path of the repository's work tree (symlinks resolved)
--       path  the file, relative to root, '/'-separated
--       rev   a full commit id, 'index' or 'worktree'; nil when the content
--             is a bare blob that is in no commit (a saved snapshot)
--       blob  the content's blob id, when known
--       label a short human name for the revision ('origin/main'), optional
--     An ordinary file buffer needs none: get() derives
--     { root, path, rev = 'worktree' } for it.
--   * Whoever sets or changes it calls set(), which fires
--     `User DevhubSource` with data = { buf = <bufnr>, source = <desc|nil> }.
--     Fire it again once the lines are in (set() twice is fine): a consumer
--     can simply (re)decorate the buffer on every event.
--
-- A producer: source.set(buf, { root = r, path = 'src/a.ts', rev = sha }).
-- A consumer: autocmd User DevhubSource + BufReadPost, then source.get(buf).

local M = {}

M.event = 'DevhubSource'

local uv = vim.uv or vim.loop

local function real(path)
  return (uv.fs_realpath(path) or path):gsub('/+$', '')
end

-- The work tree that contains dir, by directory (false: none). git is asked
-- once per directory; forget() drops what was learnt.
local roots = {}

local function work_tree(dir)
  local known = roots[dir]
  if known ~= nil then
    return known or nil
  end
  local out = vim.fn.systemlist { 'git', '-C', dir, 'rev-parse', '--show-toplevel' }
  local root = vim.v.shell_error == 0 and out[1] and out[1] ~= '' and real(out[1]) or false
  roots[dir] = root
  return root or nil
end

--- Forget the work trees learnt so far (a repository created or moved).
function M.forget()
  roots = {}
end

--- Whether desc is a well-formed source. Answers true, or false and why.
function M.validate(desc)
  if type(desc) ~= 'table' then
    return false, 'a source is a table'
  end
  if type(desc.root) ~= 'string' or desc.root:sub(1, 1) ~= '/' then
    return false, 'root must be an absolute path'
  end
  if type(desc.path) ~= 'string' or desc.path == '' or desc.path:sub(1, 1) == '/' then
    return false, 'path must be relative to root'
  end
  local rev = desc.rev
  if rev ~= nil and rev ~= 'worktree' and rev ~= 'index' and not (type(rev) == 'string' and rev:match '^%x+$' and #rev >= 40) then
    return false, "rev must be a full commit id, 'index' or 'worktree'"
  end
  if desc.blob ~= nil and not (type(desc.blob) == 'string' and desc.blob:match '^%x+$') then
    return false, 'blob must be an object id'
  end
  if rev == nil and desc.blob == nil then
    return false, 'a source needs a rev or a blob'
  end
  if desc.label ~= nil and type(desc.label) ~= 'string' then
    return false, 'label must be a string'
  end
  return true
end

local function fire(buf, desc)
  vim.api.nvim_exec_autocmds('User', { pattern = M.event, modeline = false, data = { buf = buf, source = desc } })
end

--- Say which file and revision buf shows (nil: none any more) and tell
--- whoever listens. Raises on a malformed source.
function M.set(buf, desc)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if desc ~= nil then
    local ok, err = M.validate(desc)
    if not ok then
      error('devhub.source.set: ' .. err, 2)
    end
    desc = vim.deepcopy(desc)
    desc.root = real(desc.root)
  end
  vim.b[buf].devhub_source = desc
  fire(buf, desc)
end

--- The source buf shows: its b:devhub_source, or for an ordinary file
--- buffer in a git work tree { root, path, rev = 'worktree' }; else nil.
function M.get(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local own = vim.b[buf].devhub_source
  if own ~= nil then
    return M.validate(own) and own or nil
  end
  if vim.bo[buf].buftype ~= '' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or name:match '^%a[%w+.-]*://' then
    return nil
  end
  local file = real(name)
  local dir = vim.fn.fnamemodify(file, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    return nil
  end
  local root = work_tree(dir)
  if not root or file:sub(1, #root + 1) ~= root .. '/' then
    return nil
  end
  return { root = root, path = file:sub(#root + 2), rev = 'worktree' }
end

--- Whether desc is the work tree's own file (editable, saved to disk).
function M.is_worktree(desc)
  return desc ~= nil and desc.rev == 'worktree'
end

--- Whether desc matches filter: every field given in filter is equal
--- (filter.root is compared with symlinks resolved).
function M.matches(desc, filter)
  if desc == nil then
    return false
  end
  for key, value in pairs(filter or {}) do
    if key == 'root' then
      value = real(value)
    end
    if desc[key] ~= value then
      return false
    end
  end
  return true
end

--- The loaded buffers that show a source matching filter (see matches), as
--- { { buf = n, source = desc }, ... }.
function M.list(filter)
  local found = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local desc = M.get(buf)
      if desc and M.matches(desc, filter) then
        table.insert(found, { buf = buf, source = desc })
      end
    end
  end
  return found
end

return M
