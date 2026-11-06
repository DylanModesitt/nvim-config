-- rex.lua: what Rex says about the terminal Neovim is in.
--
-- Rex runs terminals on a server, on your Mac or on a host you reach from it,
-- and shows them in its app, which runs only on macOS. A terminal follows its
-- owner, the app you're using it from. So on a host that isn't a Mac, you're
-- always elsewhere. On a Mac, Rex is asked who owns the terminal and how that
-- app is connected: over the server's own socket, it's on this Mac. That's
-- asked when Neovim starts and whenever it gets focus back, in the background,
-- so it follows you between computers.

local task = require('task')

local M = {}

local mac = vim.fn.has('mac') == 1

---Neovim is in a Rex terminal.
M.terminal = vim.env.REX_BLOCK ~= nil

---The app you're using this terminal from is on another computer: always on
---a host that isn't a Mac; on a Mac, once Rex says so. False outside Rex.
M.remote = M.terminal and not mac

---Run a rex command, in a task, and decode its JSON; nil if it failed.
---@param ... string
---@return table?
local function rex(...)
  local cmd = { 'rex', '--autostart=false', ... }
  table.insert(cmd, '--json')
  local r = task.system(cmd, { text = true })
  local ok, out = pcall(vim.json.decode, r.stdout or '', { luanil = { object = true } })
  return r.code == 0 and ok and type(out) == 'table' and out or nil
end

---Ask Rex where the app that owns this terminal is.
local function locate()
  task.run(function()
    local owner = vim.tbl_get(rex('block', 'inspect', vim.env.REX_BLOCK) or {}, 'block', 'owner')
    local client = owner and rex('client', 'inspect', owner) or {}
    local transport = vim.tbl_get(client, 'client', 'principal', 'transport')
    if transport then M.remote = transport ~= 'unix' end
  end)
end

if M.terminal and mac and vim.fn.executable('rex') == 1 then
  locate()
  vim.api.nvim_create_autocmd('FocusGained', {
    group = vim.api.nvim_create_augroup('rex', {}),
    callback = locate,
  })
end

return M
