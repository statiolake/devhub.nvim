-- Inside a DevHub terminal, wear DevHub's theme before the first redraw: the
-- published file is read here, synchronously, while Neovim loads its plugins,
-- so no frame is drawn in another colorscheme first. Set
-- `vim.g.devhub_auto = false` to choose the moment yourself (`:colorscheme
-- devhub`, or require('devhub').setup()). Outside DevHub this does nothing.
require('devhub')._startup()

-- The notifications DevHub has shown, read again in its pager.
vim.api.nvim_create_user_command('Notifications', function()
  require('devhub').gui.notifications()
end, { desc = "DevHub: the notifications shown, in DevHub's pager" })
