-- Runs the spec, and leaves Neovim with its result: an error is a failure,
-- not a prompt that waits for ever.
local ok, error = pcall(dofile, 'tests/startup_spec.lua')
if not ok then
  io.stderr:write('FAIL\n  ' .. tostring(error) .. '\n')
  vim.cmd 'cquit 1'
end
