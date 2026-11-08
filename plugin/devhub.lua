-- Inside a DevHub terminal, wear DevHub's theme before the first redraw: the
-- published file is read here, synchronously, while Neovim loads its plugins,
-- so no frame is drawn in another colorscheme first. Set
-- `vim.g.devhub_auto = false` to choose the moment yourself (`:colorscheme
-- devhub`, or require('devhub').setup()). Outside DevHub this does nothing.
require('devhub')._startup()

-- :ReviewRelay — review-relay's review panel (lua/devhub/review_relay.lua).
vim.api.nvim_create_user_command('ReviewRelay', function(o)
  local rr = require 'devhub.review_relay'
  if o.args == 'stop' then
    rr.stop()
  elseif o.args == 'refresh' then
    rr.refresh()
  else
    rr.open_panel()
  end
end, {
  nargs = '?',
  complete = function()
    return { 'refresh', 'stop' }
  end,
  desc = "review-relay's review: the panel, threads under their lines",
})
