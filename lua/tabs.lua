-- tabs.lua: Vim's tabs, labelled and numbered, with keys under <leader><Tab>.
--
-- <leader><Tab> then n new, d close, o close the others, r name it,
-- ] [ next/previous, > < move it right/left, <Tab> back to the last one.
-- <leader>1 to <leader>9 go to that tab (the tabline numbers them). Vim's
-- own: gt gT, {n}gt, g<Tab>, <C-w>T (this window to a new tab).

-- Tab labels: a tab's t:title if it has one (diff views set it), else its
-- file, or a terminal's title.
function _G.tabline()
  local parts, current = {}, vim.api.nvim_get_current_tabpage()
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local name = vim.t[tab].title
    if not name then
      local buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))
      if vim.bo[buf].buftype == 'terminal' then -- what's running in it, as the shell titles it
        name = vim.b[buf].term_title or 'terminal'
      else
        local file = vim.api.nvim_buf_get_name(buf)
        name = file ~= '' and vim.fn.pathshorten(vim.fn.fnamemodify(file, ':~:.')) or ''
      end
    end
    name = (name ~= '' and name or '[No Name]'):gsub('%%', '%%%%')
    table.insert(parts, ('%%#%s#%%%dT %d %s '):format(tab == current and 'TabLineSel' or 'TabLine', i, i, name))
  end
  return table.concat(parts) .. '%#TabLineFill#%T'
end
vim.o.tabline = '%!v:lua.tabline()'

local map = vim.keymap.set

local function tabkey(lhs, rhs, desc) map('n', '<leader><Tab>' .. lhs, rhs, { desc = desc }) end
tabkey('n', '<Cmd>tabnew<CR>', 'New tab')
tabkey('d', '<Cmd>tabclose<CR>', 'Close tab')
tabkey('o', '<Cmd>tabonly<CR>', 'Close other tabs')
tabkey(']', '<Cmd>tabnext<CR>', 'Next tab')
tabkey('[', '<Cmd>tabprevious<CR>', 'Previous tab')
tabkey('>', '<Cmd>+tabmove<CR>', 'Move tab right')
tabkey('<', '<Cmd>-tabmove<CR>', 'Move tab left')
tabkey('<Tab>', 'g<Tab>', 'Last tab')
tabkey('r', function()
  vim.ui.input({ prompt = 'Tab name: ', default = vim.t.title }, function(name)
    if not name then return end
    vim.t.title = name ~= '' and name or nil
    vim.cmd.redrawtabline()
  end)
end, 'Name tab')
for i = 1, 9 do
  map('n', '<leader>' .. i, function() pcall(vim.cmd.tabnext, i) end, { desc = 'Tab ' .. i })
end
