-- code.lua: understanding code. Treesitter for syntax, LSP for semantics.
--
-- Language servers are defined one per file in lsp/<name>.lua (:h lsp-config)
-- and switched on below: Python (ty, ruff), TypeScript and JavaScript
-- (typescript; oxlint and oxfmt where a project uses them), Rust
-- (rust_analyzer), Lua (lua_ls). The Python and JavaScript ones run the
-- versions their project pins, if it pins them (project.lua).
--
-- Neovim's default LSP keymaps apply: K hover, grn rename, gra code action,
-- grr references, gri implementation, grt type definition, gO document
-- symbols, <C-]> definition, <C-s> signature help, ]d [d diagnostics.

local M = {}

-- Treesitter ------------------------------------------------------------------
-- Neovim bundles parsers for C, Lua, Vimscript, help and Markdown;
-- nvim-treesitter installs the rest (compiled locally with tree-sitter-cli).

vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    if ev.data.spec.name == 'nvim-treesitter' and ev.data.kind == 'update' then
      if not ev.data.active then vim.cmd.packadd('nvim-treesitter') end
      vim.cmd('TSUpdate') -- parsers must match the plugin's queries
    end
  end,
})

vim.pack.add({ 'https://github.com/nvim-treesitter/nvim-treesitter' })

M.parsers = {
  'python', 'bash', 'json', 'yaml', 'toml', 'sql', 'rust', 'html', 'css',
  'javascript', 'typescript', 'tsx', 'dockerfile', 'make', 'regex',
  'diff', 'gitcommit', 'git_rebase', 'git_config', 'gitignore',
}
-- Missing ones install in the background, once there's a screen: a headless
-- run (scripts/install, make check) would quit midway through and leave a
-- half-built parser and a stale lock behind.
vim.api.nvim_create_autocmd('UIEnter', {
  once = true,
  callback = function() require('nvim-treesitter').install(M.parsers) end,
})

vim.o.foldlevelstart = 99 -- folds exist but start open
vim.o.foldtext = '' -- show a folded line as itself, highlighted

-- Web languages indent by 2, as their projects do (an .editorconfig wins).
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact', 'json', 'jsonc', 'yaml', 'html', 'css' },
  callback = function(ev) vim.bo[ev.buf].shiftwidth, vim.bo[ev.buf].tabstop = 2, 2 end,
})
---Syntax folds in window `win`, if its buffer has a syntax tree.
---@param win integer
function M.folds(win)
  if not vim.treesitter.get_parser(vim.api.nvim_win_get_buf(win), nil, { error = false }) then return end
  vim.wo[win][0].foldmethod = 'expr' -- [0]: :setlocal, not :set
  vim.wo[win][0].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
end

vim.api.nvim_create_autocmd('FileType', {
  callback = function(ev)
    if not pcall(vim.treesitter.start, ev.buf) then return end
    -- In the windows showing this buffer (FileType also fires when a file is
    -- reloaded in the background, so not "the current window"), except diff
    -- windows: their folds hide what didn't change.
    for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
      if not vim.wo[win].diff then M.folds(win) end
    end
  end,
})

-- Diagnostics -----------------------------------------------------------------

-- Severity shows as a coloured line number, leaving the sign column to git;
-- the message shows on the cursor line, counts in the statusline.
local severity = vim.diagnostic.severity
vim.diagnostic.config({
  severity_sort = true,
  signs = {
    text = { [severity.ERROR] = '', [severity.WARN] = '', [severity.INFO] = '', [severity.HINT] = '' },
    numhl = {
      [severity.ERROR] = 'DiagnosticSignError',
      [severity.WARN] = 'DiagnosticSignWarn',
      [severity.INFO] = 'DiagnosticSignInfo',
      [severity.HINT] = 'DiagnosticSignHint',
    },
  },
  virtual_text = { current_line = true }, -- message for the cursor line only
  float = { source = 'if_many' },
})

-- LSP -------------------------------------------------------------------------

vim.lsp.enable({ 'ty', 'ruff', 'typescript', 'oxlint', 'oxfmt', 'rust_analyzer', 'lua_ls' })

-- Completion pops up as you type; <C-n>/<C-p> move, <C-y> accepts (which
-- also applies auto-imports and expands snippets), <C-e> dismisses.
vim.o.completeopt = 'menuone,noselect,popup,fuzzy'
vim.o.pumborder = 'rounded'

local identifier_chars = vim.split('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_', '')

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))
    local provider = client.server_capabilities.completionProvider
    if provider then
      -- Trigger on every identifier keystroke, not just '.' (:h lsp-autocompletion).
      provider.triggerCharacters = vim.list.unique(vim.list_extend(provider.triggerCharacters or {}, identifier_chars))
      vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
    end
    -- Renaming an opening tag (JSX, HTML) renames its closing tag too.
    if client:supports_method('textDocument/linkedEditingRange') then
      vim.lsp.linked_editing_range.enable(true, { client_id = client.id })
    end
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buf = ev.buf, desc = 'Go to definition' })
  end,
})

-- <leader>= formats with the buffer's formatter: a dedicated one (ruff,
-- oxfmt) where one is attached, else any server that formats.
local formatters = { ruff = true, oxfmt = true }
vim.keymap.set('n', '<leader>=', function()
  local clients = vim.lsp.get_clients({ bufnr = 0, method = 'textDocument/formatting' })
  local dedicated = vim.iter(clients):any(function(c) return formatters[c.name] end)
  vim.lsp.buf.format({ filter = function(c) return not dedicated or formatters[c.name] end })
end, { desc = 'Format buffer' })
vim.keymap.set('n', '<leader>ti', function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, { desc = 'Toggle inlay hints' })

return M
