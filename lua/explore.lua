-- explore.lua: directories, with Vim's own netrw.
--
--   <leader>e    the directory of this file, on it
--   <leader>E    the project's root (the repository's, else the cwd)
--   :e {dir}     any directory
-- In a directory (netrw; F1 lists every key):
--   <CR> open      -  up a directory       <C-^> back to your file
--   %  new file    d  new directory        R rename    D delete
--   o v t  open in a split / vertical split / tab      p preview
--   gh  show or hide dotfiles    <C-r> refresh (it re-reads a directory you go into)

vim.g.netrw_banner = 0
vim.g.netrw_list_hide = [[^\.git/$]]
vim.g.netrw_fastbrowse = 0 -- re-read a directory each time you go into it (files come and go)
vim.g.netrw_altfile = 1 -- <C-^> goes back to your file, not to the listing

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('explore', {}),
  pattern = 'netrw',
  callback = function(ev)
    local function map(lhs, rhs, opts) vim.keymap.set('n', lhs, rhs, vim.tbl_extend('force', { buf = ev.buf }, opts or {})) end
    map('<C-h>', '<C-w>h') -- (window moves, as everywhere; netrw had these)
    map('<C-l>', '<C-w>l')
    map('<C-r>', '<Plug>NetrwRefresh', { remap = true, desc = 'Refresh' })
  end,
})

---Open directory `dir`, with the cursor on `name` in it (if given).
local function open(dir, name)
  if require('git.view').get() then vim.cmd.tabnew() end -- (not into a diff view's windows)
  vim.cmd.edit(vim.fn.fnameescape(dir))
  -- netrw lists a name with a mark of its kind: / directory, * executable, @ link.
  if name then vim.fn.search('^\\V' .. vim.fn.escape(name, '\\') .. '\\[/*@]\\=\\$', 'cw') end
end

---The file this buffer shows, if it shows one: its own, or (a revision) the
---working tree's.
local function file()
  local name = vim.api.nvim_buf_get_name(0)
  local obj = require('git.object').parse(name)
  if obj then return vim.fs.joinpath(obj.root, obj.path) end
  -- (an image's buffer is 'nofile': it holds the picture, not the file's bytes)
  if (vim.bo.buftype == '' or vim.bo.filetype == 'image') and name ~= '' then return name end
end

vim.keymap.set('n', '<leader>e', function()
  if vim.bo.filetype == 'netrw' then return vim.cmd.normal('-') end -- (in one already: its parent)
  local f = file()
  if not f then return open(vim.fn.getcwd()) end
  open(vim.fs.dirname(f), vim.fs.basename(f))
end, { desc = "This file's directory" })

vim.keymap.set('n', '<leader>E', function()
  local root = require('git').root() or vim.fn.getcwd()
  local f = file()
  -- On the entry the file is under, if it's in the project.
  local rel = f and vim.fs.relpath(root, f)
  open(root, rel and rel:match('^[^/]+'))
end, { desc = 'Project root' })
