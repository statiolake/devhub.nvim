-- Sourced with --cmd, before any plugin: records what the startup did by the
-- time Neovim entered (before its first redraw), and every DevhubTheme event.
vim.g.devhub_test_events = 0
vim.api.nvim_create_autocmd('User', {
  pattern = 'DevhubTheme',
  callback = function()
    vim.g.devhub_test_events = vim.g.devhub_test_events + 1
  end,
})
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
    vim.g.devhub_test_at_enter = {
      colors_name = vim.g.colors_name or '',
      normal_bg = normal.bg and string.format('#%06x', normal.bg) or '',
      events = vim.g.devhub_test_events,
    }
  end,
})
