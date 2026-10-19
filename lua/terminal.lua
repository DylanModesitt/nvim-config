-- terminal.lua: :terminal, with Vim's window keys.
--
-- Vim's :terminal conventions: <C-w> starts a window command from terminal
-- mode too (<C-w>h, <C-w>v, <C-w>c, ...), <C-w>. sends the program a literal
-- <C-w>, and <C-w>N goes to normal mode for scrollback (as does <C-\><C-n>).
-- <Esc> also goes to normal mode at a shell prompt; while a program runs in
-- the shell (claude, nvim, fzf, less) the <Esc> is the program's.
-- Terminals start in terminal mode, and resume it when you come back.

vim.keymap.set('t', '<C-w>', function()
  local key = vim.fn.getcharstr()
  if key == '.' then
    vim.api.nvim_chan_send(vim.bo.channel, vim.keycode('<C-w>'))
  else
    vim.api.nvim_feedkeys(vim.keycode('<C-\\><C-n>') .. (key == 'N' and '' or vim.keycode('<C-w>') .. key), 'n', false)
  end
end)

vim.keymap.set('t', '<Esc>', function()
  local busy = #vim.api.nvim_get_proc_children(vim.b.terminal_job_pid) > 0
  return busy and '<Esc>' or '<C-\\><C-n>'
end, { expr = true })

vim.api.nvim_create_autocmd({ 'TermOpen', 'BufEnter' }, {
  pattern = 'term://*',
  command = 'startinsert',
})
