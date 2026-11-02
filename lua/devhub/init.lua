-- devhub.nvim: Neovim in the colour theme DevHub wears.
--
-- DevHub publishes the VS Code colour theme it wears to the programs in its
-- terminals (see DevHub's docs/window-and-pages.md, "Terminal programs"):
--
--   * $DEVHUB_THEME_FILE, a JSON file rewritten (atomically) on every change;
--   * $DEVHUB_THEME, $DEVHUB_THEME_COLORS ... in every new pane;
--   * for the Neovim DevHub manages, `User DevhubTheme` with the same object
--     as its data.
--
-- This module turns that object into highlights. Startup and every live
-- change go through `apply(theme)`, so the first frame and a switch an hour
-- later are coloured by the same code from the same value.

local M = {}

local uv = vim.uv or vim.loop

M.config = {
  -- Apply the theme while Neovim starts (from plugin/devhub.lua), when no
  -- other colorscheme has been chosen yet.
  auto = true,
  -- Follow changes: `User DevhubTheme` and the theme file.
  follow = true,
  -- Run after the highlights are set, with the theme: for your own tweaks.
  on_apply = nil,
}

--- Whether this Neovim runs inside a DevHub terminal.
function M.inside()
  return vim.env.DEVHUB_THEME_FILE ~= nil or vim.env.DEVHUB_THEME_COLORS ~= nil
end

local function read_file(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local text = file:read '*a'
  file:close()
  local ok, value = pcall(vim.json.decode, text)
  if ok and type(value) == 'table' and value.version == 1 and type(value.colors) == 'table' then
    return value
  end
  return nil
end

--- The theme from $DEVHUB_THEME_COLORS when there is no file to read (a pane
--- on another machine): the terminal palette only, no editor or syntax colours.
local function read_environment()
  local text = vim.env.DEVHUB_THEME_COLORS
  if not text or text == '' then
    return nil
  end
  local pairs_ = {}
  for key, value in text:gmatch '(%S+)=(#%x+)' do
    pairs_[key] = value
  end
  if not pairs_.bg or not pairs_.fg then
    return nil
  end
  local ansi = {}
  for index = 0, 15 do
    ansi[index + 1] = pairs_['color' .. index] or pairs_.fg
  end
  local background = vim.env.DEVHUB_THEME_BACKGROUND == 'light' and 'light' or 'dark'
  return {
    version = 1,
    name = vim.env.DEVHUB_THEME or 'DevHub',
    kind = vim.env.DEVHUB_THEME_KIND or background,
    background = background,
    colors = {
      background = pairs_.bg,
      foreground = pairs_.fg,
      cursor = pairs_.cursor or pairs_.fg,
      cursorText = pairs_.cursor_text or pairs_.bg,
      selectionBackground = pairs_.selection or pairs_.fg,
      selectionForeground = pairs_.selection_fg,
      ansi = ansi,
    },
    editor = {},
    tokens = {},
    fzf = vim.env.DEVHUB_FZF_COLORS,
  }
end

--- The theme DevHub publishes now, or nil outside DevHub.
function M.read()
  local path = vim.env.DEVHUB_THEME_FILE
  if path and path ~= '' then
    local theme = read_file(path)
    if theme then
      return theme
    end
  end
  return read_environment()
end

-- ------------------------------------------------------------- highlights

local function blank(value)
  return value == nil or value == vim.NIL
end

--- The highlight table for a theme: group name -> nvim_set_hl spec. Pure, so
--- the same theme always gives the same table.
function M.highlights(theme)
  local c = theme.colors
  local e = blank(theme.editor) and {} or theme.editor
  local t = blank(theme.tokens) and {} or theme.tokens
  local a = c.ansi
  local function ed(id, fallback)
    local value = e[id]
    if blank(value) then
      return fallback
    end
    return value
  end
  local bg = ed('editor.background', c.background)
  local fg = ed('editor.foreground', c.foreground)
  local dim = ed('descriptionForeground', a[9])
  local float_bg = ed('editorWidget.background', bg)
  local line = ed('editor.lineHighlightBackground', ed('list.activeSelectionBackground', c.selectionBackground))
  local selection = ed('editor.selectionBackground', c.selectionBackground)
  local error = ed('editorError.foreground', a[2])
  local warn = ed('editorWarning.foreground', a[4])
  local info = ed('editorInfo.foreground', a[5])
  local hint = ed('editorHint.foreground', a[7])

  --- The style the theme gives the first of `scopes` it says anything about,
  --- else `fallback` as the colour.
  local function tok(scopes, fallback)
    if type(scopes) == 'string' then
      scopes = { scopes }
    end
    for _, scope in ipairs(scopes) do
      local style = t[scope]
      if not blank(style) then
        return {
          fg = blank(style.fg) and fallback or style.fg,
          bold = style.bold == true or nil,
          italic = style.italic == true or nil,
          underline = style.underline == true or nil,
          strikethrough = style.strikethrough == true or nil,
        }
      end
    end
    return { fg = fallback }
  end

  local h = {
    -- the editor
    Normal = { fg = fg, bg = bg },
    NormalNC = { fg = fg, bg = bg },
    NormalFloat = { fg = fg, bg = float_bg },
    FloatBorder = { fg = ed('editorWidget.border', a[9]), bg = float_bg },
    FloatTitle = { fg = ed('textLink.foreground', a[5]), bg = float_bg, bold = true },
    Cursor = { fg = bg, bg = ed('editorCursor.foreground', c.cursor) },
    lCursor = { link = 'Cursor' },
    TermCursor = { fg = c.cursorText, bg = c.cursor },
    CursorLine = { bg = line },
    CursorColumn = { bg = line },
    ColorColumn = { bg = line },
    LineNr = { fg = ed('editorLineNumber.foreground', a[9]) },
    CursorLineNr = { fg = ed('editorLineNumber.activeForeground', fg), bold = true },
    SignColumn = { bg = bg },
    FoldColumn = { fg = dim, bg = bg },
    Folded = { fg = dim, bg = line },
    Visual = { bg = selection },
    VisualNOS = { bg = selection },
    Search = { bg = ed('editor.findMatchHighlightBackground', selection) },
    IncSearch = { bg = ed('editor.findMatchBackground', selection), bold = true },
    CurSearch = { link = 'IncSearch' },
    Substitute = { link = 'IncSearch' },
    MatchParen = { bg = ed('editorBracketMatch.background', selection), bold = true },
    Whitespace = { fg = ed('editorWhitespace.foreground', a[9]) },
    NonText = { fg = ed('editorWhitespace.foreground', a[9]) },
    EndOfBuffer = { fg = bg },
    SpecialKey = { fg = ed('editorWhitespace.foreground', a[9]) },
    Conceal = { fg = dim },
    StatusLine = { fg = ed('statusBar.foreground', fg), bg = ed('statusBar.background', line) },
    StatusLineNC = { fg = dim, bg = ed('sideBar.background', bg) },
    TabLine = { fg = ed('tab.inactiveForeground', dim), bg = ed('tab.inactiveBackground', bg) },
    TabLineSel = { fg = ed('tab.activeForeground', fg), bg = ed('tab.activeBackground', bg), bold = true },
    TabLineFill = { bg = ed('sideBar.background', bg) },
    WinSeparator = { fg = ed('panel.border', a[9]) },
    VertSplit = { link = 'WinSeparator' },
    WinBar = { fg = fg, bg = bg },
    WinBarNC = { fg = dim, bg = bg },
    Pmenu = { fg = fg, bg = float_bg },
    PmenuSel = {
      fg = ed('list.activeSelectionForeground', fg),
      bg = ed('list.activeSelectionBackground', selection),
    },
    PmenuSbar = { bg = float_bg },
    PmenuThumb = { bg = ed('scrollbarSlider.background', a[9]) },
    WildMenu = { link = 'PmenuSel' },
    Directory = { fg = a[5] },
    Title = vim.tbl_extend('force', tok('markup.heading', a[5]), { bold = true }),
    ErrorMsg = { fg = error },
    WarningMsg = { fg = warn },
    MoreMsg = { fg = a[3] },
    ModeMsg = { fg = fg, bold = true },
    Question = { fg = a[3] },
    QuickFixLine = { bg = line, bold = true },
    DiffAdd = { bg = ed('diffEditor.insertedTextBackground', line) },
    DiffDelete = { bg = ed('diffEditor.removedTextBackground', line) },
    DiffChange = { bg = line },
    DiffText = { bg = ed('diffEditor.insertedTextBackground', selection) },
    Added = { fg = a[3] },
    Changed = { fg = a[4] },
    Removed = { fg = a[2] },
    SpellBad = { undercurl = true, sp = error },
    SpellCap = { undercurl = true, sp = warn },
    SpellLocal = { undercurl = true, sp = info },
    SpellRare = { undercurl = true, sp = hint },

    -- syntax, from the theme's tokenColors
    Comment = tok('comment', dim),
    String = tok('string', a[3]),
    Character = tok({ 'constant.character', 'string' }, a[3]),
    Number = tok('constant.numeric', a[4]),
    Float = { link = 'Number' },
    Boolean = tok({ 'constant.language.boolean', 'constant.language' }, a[4]),
    Constant = tok({ 'variable.other.constant', 'constant.language', 'constant.other' }, a[4]),
    Identifier = tok('variable', fg),
    Function = tok('entity.name.function', a[5]),
    Statement = tok('keyword', a[6]),
    Conditional = tok({ 'keyword.control', 'keyword' }, a[6]),
    Repeat = tok({ 'keyword.control', 'keyword' }, a[6]),
    Label = tok({ 'entity.name.label', 'keyword.control' }, a[6]),
    Operator = tok({ 'keyword.operator', 'keyword' }, fg),
    Keyword = tok('keyword', a[6]),
    Exception = tok({ 'keyword.control', 'keyword' }, a[6]),
    PreProc = tok({ 'meta.preprocessor', 'entity.name.function.preprocessor', 'keyword.control.import' }, a[6]),
    Include = tok({ 'keyword.control.import', 'keyword.control' }, a[6]),
    Define = { link = 'PreProc' },
    Macro = tok({ 'entity.name.function.preprocessor', 'meta.preprocessor' }, a[5]),
    PreCondit = { link = 'PreProc' },
    Type = tok({ 'entity.name.type', 'support.type', 'storage.type' }, a[7]),
    StorageClass = tok({ 'storage.modifier', 'storage' }, a[6]),
    Structure = tok({ 'entity.name.class', 'entity.name.type' }, a[7]),
    Typedef = { link = 'Type' },
    Special = tok({ 'constant.character.escape', 'support.constant' }, a[6]),
    SpecialChar = tok('constant.character.escape', a[6]),
    Tag = tok('entity.name.tag', a[5]),
    Delimiter = tok('punctuation', fg),
    SpecialComment = tok({ 'comment.block.documentation', 'comment' }, dim),
    Debug = { fg = warn },
    Underlined = { underline = true },
    Ignore = { fg = dim },
    Error = tok('invalid', error),
    Todo = { fg = a[4], bold = true },

    -- Tree-sitter
    ['@comment'] = { link = 'Comment' },
    ['@comment.documentation'] = tok({ 'comment.block.documentation', 'comment' }, dim),
    ['@string'] = { link = 'String' },
    ['@string.regexp'] = tok({ 'string.regexp', 'string' }, a[7]),
    ['@string.escape'] = { link = 'SpecialChar' },
    ['@string.special'] = { link = 'Special' },
    ['@character'] = { link = 'Character' },
    ['@number'] = { link = 'Number' },
    ['@boolean'] = { link = 'Boolean' },
    ['@constant'] = { link = 'Constant' },
    ['@constant.builtin'] = tok({ 'constant.language', 'support.constant' }, a[4]),
    ['@constant.macro'] = { link = 'Macro' },
    ['@variable'] = tok('variable', fg),
    ['@variable.builtin'] = tok({ 'variable.language', 'variable' }, a[6]),
    ['@variable.parameter'] = tok({ 'variable.parameter', 'variable' }, fg),
    ['@variable.member'] = tok({ 'variable.other.property', 'variable' }, fg),
    ['@property'] = { link = '@variable.member' },
    ['@function'] = { link = 'Function' },
    ['@function.call'] = tok({ 'entity.name.function', 'support.function' }, a[5]),
    ['@function.builtin'] = tok({ 'support.function', 'entity.name.function' }, a[5]),
    ['@function.macro'] = { link = 'Macro' },
    ['@function.method'] = { link = '@function' },
    ['@function.method.call'] = { link = '@function.call' },
    ['@constructor'] = tok({ 'entity.name.class', 'entity.name.type' }, a[7]),
    ['@keyword'] = { link = 'Keyword' },
    ['@keyword.function'] = tok({ 'storage.type', 'keyword' }, a[6]),
    ['@keyword.return'] = { link = 'Conditional' },
    ['@keyword.conditional'] = { link = 'Conditional' },
    ['@keyword.repeat'] = { link = 'Repeat' },
    ['@keyword.exception'] = { link = 'Exception' },
    ['@keyword.import'] = { link = 'Include' },
    ['@keyword.operator'] = { link = 'Operator' },
    ['@keyword.modifier'] = { link = 'StorageClass' },
    ['@keyword.type'] = tok({ 'storage.type', 'keyword' }, a[6]),
    ['@operator'] = { link = 'Operator' },
    ['@type'] = { link = 'Type' },
    ['@type.builtin'] = tok({ 'support.type', 'entity.name.type' }, a[7]),
    ['@type.definition'] = { link = 'Type' },
    ['@module'] = tok({ 'entity.name.namespace', 'entity.name.type' }, a[7]),
    ['@label'] = { link = 'Label' },
    ['@attribute'] = tok('entity.other.attribute-name', a[4]),
    ['@tag'] = { link = 'Tag' },
    ['@tag.attribute'] = tok('entity.other.attribute-name', a[4]),
    ['@tag.delimiter'] = tok({ 'punctuation.definition.tag', 'punctuation' }, fg),
    ['@punctuation'] = { link = 'Delimiter' },
    ['@punctuation.bracket'] = tok({ 'meta.brace', 'punctuation' }, fg),
    ['@punctuation.delimiter'] = { link = 'Delimiter' },
    ['@punctuation.special'] = { link = 'Special' },
    ['@markup.heading'] = { link = 'Title' },
    ['@markup.strong'] = vim.tbl_extend('force', tok('markup.bold', fg), { bold = true }),
    ['@markup.italic'] = vim.tbl_extend('force', tok('markup.italic', fg), { italic = true }),
    ['@markup.strikethrough'] = { strikethrough = true },
    ['@markup.underline'] = { underline = true },
    ['@markup.link'] = tok('markup.underline.link', a[5]),
    ['@markup.link.url'] = vim.tbl_extend('force', tok('markup.underline.link', a[5]), { underline = true }),
    ['@markup.raw'] = tok('markup.inline.raw', a[3]),
    ['@markup.quote'] = tok('markup.quote', dim),
    ['@markup.list'] = tok('markup.list', a[6]),
    ['@diff.plus'] = tok('markup.inserted', a[3]),
    ['@diff.minus'] = tok('markup.deleted', a[2]),
    ['@diff.delta'] = tok('markup.changed', a[4]),
    -- the names before nvim-treesitter's 2024 rename
    ['@field'] = { link = '@variable.member' },
    ['@parameter'] = { link = '@variable.parameter' },
    ['@namespace'] = { link = '@module' },
    ['@method'] = { link = '@function.method' },
    ['@include'] = { link = 'Include' },
    ['@conditional'] = { link = 'Conditional' },
    ['@repeat'] = { link = 'Repeat' },
    ['@exception'] = { link = 'Exception' },
    ['@text.title'] = { link = 'Title' },
    ['@text.uri'] = { link = '@markup.link.url' },

    -- LSP
    ['@lsp.type.class'] = { link = '@type' },
    ['@lsp.type.enum'] = { link = '@type' },
    ['@lsp.type.interface'] = { link = '@type' },
    ['@lsp.type.struct'] = { link = '@type' },
    ['@lsp.type.type'] = { link = '@type' },
    ['@lsp.type.typeParameter'] = { link = '@type' },
    ['@lsp.type.namespace'] = { link = '@module' },
    ['@lsp.type.parameter'] = { link = '@variable.parameter' },
    ['@lsp.type.property'] = { link = '@property' },
    ['@lsp.type.variable'] = { link = '@variable' },
    ['@lsp.type.function'] = { link = '@function' },
    ['@lsp.type.method'] = { link = '@function.method' },
    ['@lsp.type.macro'] = { link = '@constant.macro' },
    ['@lsp.type.keyword'] = { link = '@keyword' },
    ['@lsp.type.enumMember'] = { link = '@constant' },
    ['@lsp.type.decorator'] = { link = '@attribute' },
    ['@lsp.type.comment'] = { link = '@comment' },
    ['@lsp.mod.deprecated'] = { strikethrough = true },
    LspReferenceText = { bg = ed('editor.findMatchHighlightBackground', line) },
    LspReferenceRead = { link = 'LspReferenceText' },
    LspReferenceWrite = { link = 'LspReferenceText' },
    LspInlayHint = { fg = dim },
    LspSignatureActiveParameter = { bold = true, underline = true },
    LspCodeLens = { fg = dim },

    -- diagnostics
    DiagnosticError = { fg = error },
    DiagnosticWarn = { fg = warn },
    DiagnosticInfo = { fg = info },
    DiagnosticHint = { fg = hint },
    DiagnosticOk = { fg = a[3] },
    DiagnosticUnderlineError = { undercurl = true, sp = error },
    DiagnosticUnderlineWarn = { undercurl = true, sp = warn },
    DiagnosticUnderlineInfo = { undercurl = true, sp = info },
    DiagnosticUnderlineHint = { undercurl = true, sp = hint },
    DiagnosticUnderlineOk = { undercurl = true, sp = a[3] },
    DiagnosticVirtualTextError = { fg = error },
    DiagnosticVirtualTextWarn = { fg = warn },
    DiagnosticVirtualTextInfo = { fg = info },
    DiagnosticVirtualTextHint = { fg = hint },
    DiagnosticDeprecated = { strikethrough = true },
    DiagnosticUnnecessary = { fg = dim },

    -- git signs
    GitSignsAdd = { fg = a[3] },
    GitSignsChange = { fg = a[4] },
    GitSignsDelete = { fg = a[2] },

    -- telescope
    TelescopeNormal = { link = 'NormalFloat' },
    TelescopeBorder = { link = 'FloatBorder' },
    TelescopeTitle = { link = 'FloatTitle' },
    TelescopeSelection = { link = 'PmenuSel' },
    TelescopeMatching = { fg = a[5], bold = true },
    TelescopePromptPrefix = { fg = a[5] },

    -- fzf-lua
    FzfLuaNormal = { link = 'NormalFloat' },
    FzfLuaBorder = { link = 'FloatBorder' },
    FzfLuaTitle = { link = 'FloatTitle' },
    FzfLuaCursorLine = { link = 'CursorLine' },
    FzfLuaSearch = { fg = a[5], bold = true },
  }
  return h
end

--- Make `theme` the colours: every highlight, `background`, and the sixteen
--- terminal colours. Startup and every change come here.
function M.apply(theme)
  if vim.g.colors_name then
    vim.cmd 'highlight clear'
  end
  if vim.fn.exists 'syntax_on' == 1 then
    vim.cmd 'syntax reset'
  end
  vim.o.termguicolors = true
  vim.o.background = theme.background == 'light' and 'light' or 'dark'
  vim.g.colors_name = 'devhub'
  for name, spec in pairs(M.highlights(theme)) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  for index = 0, 15 do
    vim.g['terminal_color_' .. index] = theme.colors.ansi[index + 1]
  end
  M.current = theme
  if M.config.on_apply then
    M.config.on_apply(theme)
  end
end

--- `:colorscheme devhub`: the theme DevHub publishes now. Outside DevHub
--- there is none, and that is said rather than painting something else.
function M.load()
  local theme = M.pending or M.read()
  M.pending = nil
  if not theme then
    vim.notify('devhub.nvim: no DevHub theme to wear here (DEVHUB_THEME_FILE is not set)', vim.log.levels.WARN)
    return false
  end
  M.apply(theme)
  return true
end

--- The fzf `--color=` value for the theme worn, for fzf-lua's `fzf_opts` or a
--- shell. nil outside DevHub.
function M.fzf_colors()
  local theme = M.current or M.read()
  return theme and theme.fzf or nil
end

-- ----------------------------------------------------------------- follow

local group = vim.api.nvim_create_augroup('devhub_theme', { clear = true })
local watcher
local followed = false

local function reapply(theme)
  if vim.g.colors_name ~= 'devhub' or not theme then
    return
  end
  if M.current and vim.deep_equal(M.current, theme) then
    return
  end
  -- Through `:colorscheme`, as at startup: the same code, and your
  -- ColorScheme autocommands run after it the same way.
  M.pending = theme
  vim.cmd.colorscheme 'devhub'
end

local function follow()
  if followed then
    return
  end
  followed = true
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DevhubTheme',
    callback = function(event)
      local theme = type(event.data) == 'table' and event.data or M.read()
      reapply(theme)
    end,
  })
  -- A Neovim DevHub does not manage (yours, in a pane) learns from the file.
  -- The directory is watched, because the file is replaced by a rename.
  local path = vim.env.DEVHUB_THEME_FILE
  if not path or path == '' or watcher then
    return
  end
  local directory = vim.fn.fnamemodify(path, ':h')
  local name = vim.fn.fnamemodify(path, ':t')
  watcher = uv.new_fs_event()
  if not watcher then
    return
  end
  local ok = pcall(watcher.start, watcher, directory, {}, function(_, filename)
    if filename ~= name then
      return
    end
    vim.schedule(function()
      reapply(read_file(path))
    end)
  end)
  if not ok then
    watcher = nil
  end
end

--- Configure, and inside DevHub apply the theme (`auto`) and follow it
--- (`follow`). Outside DevHub this does nothing at all.
function M.setup(options)
  M.config = vim.tbl_extend('force', M.config, options or {})
  if not M.inside() then
    return
  end
  if M.config.follow then
    follow()
  end
  if M.config.auto and vim.g.colors_name ~= 'devhub' then
    vim.cmd.colorscheme 'devhub'
  end
end

--- What plugin/devhub.lua does as Neovim starts: inside DevHub, with no
--- colorscheme chosen yet, the theme before the first redraw.
function M._startup()
  if vim.g.devhub_loaded then
    return
  end
  vim.g.devhub_loaded = true
  if not M.inside() then
    return
  end
  if M.config.follow then
    follow()
  end
  if M.config.auto and vim.g.devhub_auto ~= false and not vim.g.colors_name then
    vim.cmd.colorscheme 'devhub'
  end
end

return M
