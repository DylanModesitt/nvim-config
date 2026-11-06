-- clipboard.lua: yanks go to the clipboard of the computer you're at, wherever
-- Neovim runs ('clipboard' is unnamedplus).
--
-- On that computer, it's the clipboard itself (pbcopy, pbpaste). On another
-- machine, yanks reach it through the terminal (OSC 52). Reading it back that
-- way would have the terminal ask each time (Rex doesn't answer at all), so p
-- puts the last yank, and Cmd-V pastes from your computer. Links you open (gx,
-- a pull request's o) are copied, to open there.
--
-- Another machine is: over SSH, or in a Rex terminal that the Rex app you're
-- using reaches over the network. Rex's app runs only on macOS, so a Rex
-- terminal anywhere else always is. On a Mac, Rex is asked: a terminal follows
-- its owner, the app you're using, which is on this Mac if it's connected over
-- the server's own socket. It's asked when Neovim starts and when you come back
-- to it (FocusGained), in the background, so it follows you between computers.

local mac = vim.fn.has('mac') == 1
local block = vim.env.REX_BLOCK
local remote = vim.env.SSH_TTY ~= nil or (block ~= nil and not mac)
local ask = block ~= nil and mac and not remote

if not (remote or ask) then return end

---Run a rex command; `k` gets its JSON output, or nil if it failed.
---@param args string[]
---@param k fun(out: table?)
local function rex(args, k)
  local cmd = vim.list_extend({ 'rex', '--autostart=false' }, args)
  local ok = pcall(vim.system, cmd, { text = true }, function(r)
    local decoded, out = pcall(vim.json.decode, r.stdout or '', { luanil = { object = true } })
    vim.schedule(function() k(r.code == 0 and decoded and type(out) == 'table' and out or nil) end)
  end)
  if not ok then k(nil) end
end

---Ask Rex where the app you're using is. Until it answers, and if it can't,
---the clipboard is this Mac's.
local function locate()
  rex({ 'block', 'inspect', block, '--json' }, function(b)
    local owner = b and b.block and b.block.owner
    if not owner then return end
    rex({ 'client', 'inspect', owner, '--json' }, function(c)
      local transport = c and c.client and c.client.principal and c.client.principal.transport
      if transport then remote = transport ~= 'unix' end
    end)
  end)
end

if ask then
  locate()
  vim.api.nvim_create_autocmd('FocusGained', {
    group = vim.api.nvim_create_augroup('clipboard', {}),
    callback = locate,
  })
end

local osc52 = require('vim.ui.clipboard.osc52')

---@param reg '+'|'*'
local function copy(reg)
  local through = osc52.copy(reg)
  return function(lines)
    if remote then return through(lines) end
    vim.fn.systemlist({ 'pbcopy' }, lines, 1)
  end
end

local function paste()
  if remote then return { vim.fn.getreg('', 1, true), vim.fn.getregtype('') } end
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
  if not remote then return open(url, opt) end
  vim.fn.setreg('+', url)
  vim.notify('Copied ' .. url)
end

