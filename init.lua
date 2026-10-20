-- init.lua: the whole editor, top to bottom.
--
--   init.lua            options, keymaps, autocmds
--   lua/find.lua        fuzzy :find, :Recent, :Grep on the native command line
--   lua/explore.lua     directories (netrw): <leader>e, <leader>E
--   lua/tabs.lua        tab labels and numbers, <leader><Tab> keys
--   lua/terminal.lua    :terminal with Vim's window keys
--   lua/sync.lua        files <-> buffers: reload on change, autosave at rest
--   lua/code.lua        treesitter, LSP, completion, diagnostics
--   lua/wrap.lua        gq rewraps comments/docstrings, leaves code to the LSP
--   lua/image.lua       image files show as the image (Ghostty, kitty)
--   lua/project.lua     each project's own tools (.venv, node_modules)
--   lua/task.lua        waiting on git/gh without freezing the editor
--   lua/git/            git: :Diff/:Show/:Log views, gutter signs (see git/init.lua)
--   lua/review/         review comments, viewed marks, export (see review/init.lua)
--   lua/github/         pull requests: :PR views, threads, reviews (see github/init.lua)
--   lsp/*.lua           one file per language server (Python, TypeScript, Rust, Lua)
--   after/ftplugin/     per-language settings (python: wrap width; markdown, text: wrap)
--
-- Plugins are managed by the built-in vim.pack and pinned in
-- nvim-pack-lock.json. :lua vim.pack.update() to update them.

vim.loader.enable()

vim.g.mapleader = ' '
vim.g.maplocalleader = ','

-- Experimental 0.12 message/cmdline UI: no "Press ENTER" stops, highlighted
-- cmdline, :messages in a real buffer. Remove this line to go back.
require('vim._core.ui2').enable({})

-- Options ---------------------------------------------------------------------

local o = vim.o

o.number = true
o.relativenumber = true
o.signcolumn = 'yes'
o.cursorline = true
o.scrolloff = 8
o.smoothscroll = true
o.wrap = false
o.breakindent = true
o.list = true
o.listchars = 'tab:» ,trail:·,nbsp:␣'

o.expandtab = true
o.shiftwidth = 4
o.tabstop = 4
o.virtualedit = 'block'

o.ignorecase = true
o.smartcase = true
o.inccommand = 'split'

o.splitright = true
o.splitbelow = true
o.winborder = 'rounded'
o.diffopt = o.diffopt:gsub('inline:%a+', 'inline:word') .. ',algorithm:histogram,foldcolumn:0'
o.confirm = true
o.undofile = true
o.updatetime = 250
o.clipboard = 'unnamedplus'

-- Over SSH, the clipboard is your own computer's: yanks reach it through the
-- terminal (OSC 52). Reading it back would have the terminal ask each time,
-- so p puts the last yank (Cmd-V pastes from your computer). Links you open
-- (gx, a pull request's o) are copied, to open there.
if vim.env.SSH_TTY then
  local osc52 = require('vim.ui.clipboard.osc52')
  local function last() return { vim.fn.getreg('', 1, true), vim.fn.getregtype('') } end
  vim.g.clipboard = {
    name = 'OSC 52',
    copy = { ['+'] = osc52.copy('+'), ['*'] = osc52.copy('*') },
    paste = { ['+'] = last, ['*'] = last },
  }
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.open = function(url)
    vim.fn.setreg('+', url)
    vim.notify('Copied ' .. url)
  end
end

-- Ghostty tab title: the project/worktree directory name.
o.title = true
o.titlestring = '%{fnamemodify(getcwd(), ":t")}'

-- Command line: completion pops up as you type (:h cmdline-autocompletion).
-- <Tab>/<S-Tab> move through it, <CR> runs the command, <Up>/<Down> history.
o.wildmode = 'noselect:lastused,full'
o.wildoptions = 'pum,fuzzy'
o.pumheight = 15
vim.api.nvim_create_autocmd('CmdlineChanged', {
  pattern = ':',
  callback = function() vim.fn.wildtrigger() end,
})
vim.keymap.set('c', '<Up>', function() return vim.fn.wildmenumode() == 1 and '<C-e><Up>' or '<Up>' end, { expr = true })
vim.keymap.set('c', '<Down>', function() return vim.fn.wildmenumode() == 1 and '<C-e><Down>' or '<Down>' end, { expr = true })

-- Theme -----------------------------------------------------------------------
-- retrobox: Vim's own retro scheme (gruvbox's colors), dark or light as the
-- terminal is. Ghostty's theme is made from it (scripts/ghostty-theme.lua).
-- To change themes: the name here, and the theme line in
-- ~/.config/ghostty/config.

vim.cmd.colorscheme('retrobox')

-- Keymaps ---------------------------------------------------------------------
-- Neovim's own defaults cover a lot already: ]q [q ]b [b ]d [d (unimpaired-
-- style), gcc (comment), K grn gra grr gri grt gO <C-]> (LSP), an/in
-- (treesitter select). The full list of ours: CHEATSHEET.md.

local map = vim.keymap.set

map('n', '<Esc>', '<Cmd>nohlsearch<CR>')

-- Where lines wrap (Markdown, text), j/k move a line on screen. With a count
-- they move real lines, as the relative numbers count.
map({ 'n', 'x' }, 'j', function() return vim.v.count == 0 and 'gj' or 'j' end, { expr = true })
map({ 'n', 'x' }, 'k', function() return vim.v.count == 0 and 'gk' or 'k' end, { expr = true })

map('n', '<C-h>', '<C-w>h')
map('n', '<C-j>', '<C-w>j')
map('n', '<C-k>', '<C-w>k')
map('n', '<C-l>', '<C-w>l')

map('n', '<leader>f', ':find ', { desc = 'Find file' })
map('n', '<leader>r', ':Recent ', { desc = 'Recent file' })
map('n', '<leader>b', ':buffer ', { desc = 'Buffer' })
map('n', '<leader>/', ':Grep ', { desc = 'Grep' })
map({ 'n', 'x' }, '<leader>*', function() require('find').grep_here() end, { desc = 'Grep word/selection' })

-- Close this window's location list (gO's symbols) or else the quickfix
-- list; with neither open, open the quickfix list.
map('n', '<leader>q', function()
  if vim.fn.getloclist(0, { winid = 0 }).winid ~= 0 then
    vim.cmd.lclose()
  elseif vim.fn.getqflist({ winid = 0 }).winid ~= 0 then
    vim.cmd.cclose()
  else
    vim.cmd('botright copen')
  end
end, { desc = 'Close list / open quickfix' })

-- The undo tree (Neovim's own): moving in it moves the file through its
-- history. <leader>u again (or q in it) closes it.
vim.cmd.packadd('nvim.undotree')
map('n', '<leader>u', '<Cmd>Undotree<CR>', { desc = 'Undo tree' })

-- Change every occurrence of the word under the cursor (or the selection)
-- in the file: :%s, ready for the replacement, previewed live as you type.
-- (Neovim's own multiple cursors are due in 0.13. Meanwhile: * then cgn and
-- . to change them one by one; grn renames a symbol, across files.)
map({ 'n', 'x' }, '<leader>L', function()
  local pattern
  if vim.fn.mode():match('[vV\22]') then
    local text = vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = vim.fn.mode() })
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
    pattern = table.concat(vim.tbl_map(function(l) return vim.fn.escape(l, '/\\') end, text), '\\n')
  else
    pattern = '\\<' .. vim.fn.escape(vim.fn.expand('<cword>'), '/\\') .. '\\>'
  end
  vim.api.nvim_feedkeys(':%s/\\V\\C' .. pattern .. '//g' .. vim.keycode('<Left><Left>'), 'n', false)
end, { desc = 'Change all occurrences' })

-- Autocmds --------------------------------------------------------------------

local group = vim.api.nvim_create_augroup('init', {})

vim.api.nvim_create_autocmd('TextYankPost', {
  group = group,
  callback = function() vim.hl.on_yank() end,
})

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'nvim-undotree',
  callback = function(ev) map('n', 'q', '<Cmd>close<CR>', { buf = ev.buf, desc = 'Close the undo tree' }) end,
})

-- Reopen files where you left them.
vim.api.nvim_create_autocmd('BufReadPost', {
  group = group,
  callback = function(ev)
    local mark = vim.api.nvim_buf_get_mark(ev.buf, '"')
    if mark[1] > 1 and mark[1] <= vim.api.nvim_buf_line_count(ev.buf) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Features --------------------------------------------------------------------

require('find')
require('explore')
require('tabs')
require('terminal')
require('sync')
require('code')
require('wrap')
require('image')
require('git')
require('git.signs')
require('review')
require('github')
