-- find.lua: fuzzy finding on the native command line, no picker plugin.
-- Completion pops up as you type (see init.lua); <Tab> moves through it and
-- <CR> opens the highlighted item, or the best match if none is highlighted.
-- Queries can contain spaces, like fzf: `:find user model`.
--
--   :find {fuzzy}    files under the cwd (rg --files: honors .gitignore)
--   :Recent {fuzzy}  recently used files, this session's first
--   :Grep {regex}    ripgrep into the quickfix list
--   :buffer, :help   built in, made fuzzy by 'wildoptions'

local M = {}

local function fuzzy(list, query) return query == '' and list or vim.fn.matchfuzzy(list, query) end

-- Files entered this session, newest first. v:oldfiles only covers earlier
-- sessions: Neovim writes it on exit.
local session = {} ---@type string[]

vim.api.nvim_create_autocmd('BufEnter', {
  callback = function(ev)
    local name = vim.api.nvim_buf_get_name(ev.buf)
    if vim.bo[ev.buf].buftype ~= '' or name == '' then return end
    for i, f in ipairs(session) do
      if f == name then
        table.remove(session, i)
        break
      end
    end
    table.insert(session, 1, name)
  end,
})

-- Commands whose argument is picked from a fuzzy list.
local sources = {
  find = function() return vim.fn.systemlist({ 'rg', '--files', '--hidden', '--glob=!.git' }) end,
  Recent = function()
    local seen = { [vim.api.nvim_buf_get_name(0)] = true } -- not the file you're in
    return vim.iter({ session, vim.v.oldfiles })
      :flatten()
      :filter(function(f)
        if seen[f] then return false end
        seen[f] = true
        return vim.uv.fs_stat(f) ~= nil
      end)
      :map(function(f) return vim.fn.fnamemodify(f, ':~:.') end)
      :totable()
  end,
}

local cache = {} ---@type table<string, string[]> each source listed once per command line

vim.api.nvim_create_autocmd('CmdlineEnter', {
  pattern = ':',
  callback = function() cache = {} end,
})

local function list(cmd)
  cache[cmd] = cache[cmd] or sources[cmd]()
  return cache[cmd]
end

---The picker command being typed and its whole query. (Completion functions
---only receive the last space-separated word.)
local function typed()
  local word, query = vim.fn.getcmdline():match('^%s*(%a+)%s+(.-)%s*$')
  local cmd = word and vim.fn.fullcommand(word)
  if sources[cmd] or cmd == 'sfind' or cmd == 'tabfind' then return cmd, query end
end

local function source(cmd) return sources[cmd] and cmd or 'find' end -- (:sfind, :tabfind: :find's)

local function complete()
  local cmd, query = typed()
  return cmd and fuzzy(list(source(cmd)), query) or {}
end

-- <CR> runs the command on the chosen item rather than the raw query.
vim.api.nvim_create_autocmd('CmdlineLeavePre', {
  pattern = ':',
  callback = function()
    local cmd, query = typed()
    if not cmd or query == '' then return end
    local info = vim.fn.cmdcomplete_info()
    if info.selected == -1 and vim.uv.fs_stat(vim.fn.expand(query)) then return end -- a path: that file
    local pick = info.selected ~= -1 and info.matches[info.selected + 1] or fuzzy(list(source(cmd)), query)[1]
    if pick then vim.fn.setcmdline(cmd .. ' ' .. vim.fn.fnameescape(pick)) end
  end,
})

---'findfunc'. :find opens the first item returned.
function M.find(arg, cmdcomplete)
  if cmdcomplete then return complete() end
  return vim.uv.fs_stat(arg) and { arg } or fuzzy(list('find'), arg)
end

vim.o.findfunc = "v:lua.require'find'.find"

vim.api.nvim_create_user_command('Recent', function(cmd) vim.cmd('edit ' .. cmd.args) end,
  { nargs = 1, complete = complete })

-- :grep (synchronous, takes rg flags) and :Grep share this.
vim.o.grepprg = 'rg --vimgrep --smart-case --hidden --glob=!.git'

---Run rg with `args` asynchronously and load the matches into quickfix.
---@param args string[]
function M.grep(args)
  local cmd = vim.list_extend(vim.split(vim.o.grepprg, ' '), args)
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(r)
    if r.code > 1 then return vim.notify(r.stderr, vim.log.levels.ERROR) end
    local lines = vim.split(r.stdout, '\n', { trimempty = true })
    vim.fn.setqflist({}, ' ', { title = 'rg ' .. args[#args], lines = lines, efm = vim.o.grepformat })
    vim.cmd('botright cwindow')
    if #lines == 0 then vim.notify('No matches: ' .. args[#args]) end
  end))
end

---Grep the word under the cursor, or the visual selection, literally.
function M.grep_here()
  local mode = vim.fn.mode()
  if mode == 'n' then
    return M.grep({ '-F', '-w', '--', vim.fn.expand('<cword>') })
  end
  local text = vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode })
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
  M.grep({ '-F', '--', table.concat(text, '\n') })
end

vim.api.nvim_create_user_command('Grep', function(cmd) M.grep({ '--', cmd.args }) end, { nargs = '+' })

return M
