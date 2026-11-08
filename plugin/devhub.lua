-- Inside a DevHub terminal, wear DevHub's theme before the first redraw: the
-- published file is read here, synchronously, while Neovim loads its plugins,
-- so no frame is drawn in another colorscheme first. Set
-- `vim.g.devhub_auto = false` to choose the moment yourself (`:colorscheme
-- devhub`, or require('devhub').setup()). Outside DevHub this does nothing.
require('devhub')._startup()
