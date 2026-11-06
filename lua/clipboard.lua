-- clipboard.lua: yanks go to the clipboard of the computer you're at, wherever
-- Neovim runs ('clipboard' is unnamedplus).
--
-- At that computer, it's the clipboard itself (pbcopy, pbpaste). From another
-- one, over SSH or in Rex (see rex.lua), yanks reach it through the terminal
-- (OSC 52). Reading it back that way would have the terminal ask each time
-- (Rex doesn't answer at all), so p puts the last yank, and Cmd-V pastes from
-- your computer. Links you open (gx, a pull request's o) are copied, to open
-- there.

local rex = require('rex')

local ssh = vim.env.SSH_TTY ~= nil
if not (ssh or rex.terminal) then return end

---You're at another computer than the one Neovim runs on.
local function remote() return ssh or rex.remote end

local osc52 = require('vim.ui.clipboard.osc52')

---@param reg '+'|'*'
local function copy(reg)
  local through = osc52.copy(reg)
  return function(lines)
    if remote() then return through(lines) end
    vim.fn.systemlist({ 'pbcopy' }, lines, 1)
  end
end

local function paste()
  if remote() then return { vim.fn.getreg('', 1, true), vim.fn.getregtype('') } end
  return vim.fn.systemlist({ 'pbpaste' }, { '' }, 1)
end

vim.g.clipboard = {
  name = 'clipboard.lua',
  copy = { ['+'] = copy('+'), ['*'] = copy('*') },
  paste = { ['+'] = paste, ['*'] = paste },
}

local open = vim.ui.open
---@diagnostic disable-next-line: duplicate-set-field
vim.ui.open = function(url, opt)
  if not remote() then return open(url, opt) end
  vim.fn.setreg('+', url)
  vim.notify('Copied ' .. url)
end
