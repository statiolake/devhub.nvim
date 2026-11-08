-- Inside a DevHub terminal, wear DevHub's theme before the first redraw: the
-- published file is read here, synchronously, while Neovim loads its plugins,
-- so no frame is drawn in another colorscheme first. Set
-- `vim.g.devhub_auto = false` to choose the moment yourself (`:colorscheme
-- devhub`, or require('devhub').setup()). Outside DevHub this does nothing.
require('devhub')._startup()

-- :ReviewRelay — review-relay's review panel (lua/devhub/review_relay.lua).
vim.api.nvim_create_user_command('ReviewRelay', function(o)
  local rr = require 'devhub.review_relay'
  if o.fargs[1] == 'stop' and #o.fargs == 1 then
    rr.stop()
  elseif o.fargs[1] == 'refresh' and #o.fargs == 1 then
    rr.refresh()
  else
    -- git diff arguments for a viewer it starts (none: the files).
    rr.open_panel(o.fargs)
  end
end, {
  nargs = '*',
  complete = function()
    return { 'refresh', 'stop', 'main...HEAD', 'HEAD~', '--cached' }
  end,
  desc = "review-relay's review: the panel, threads under their lines; [git diff args] for a viewer it starts",
})
