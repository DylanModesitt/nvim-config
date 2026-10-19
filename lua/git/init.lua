-- git/init.lua: running git, and the commands that open git views.
--
--   :Diff [args]   the arguments of `git diff`, and the same comparison:
--                    (none)          unstaged and staged changes
--                    --staged        index against HEAD
--                    REV             REV against the working tree
--                    A B, A..B       A against B
--                    A...B           where B branched from A, against B
--                    --merge-base A  where HEAD branched from A, against the
--                                    working tree (a branch's whole change)
--                    -- PATHS        only these paths (% is the current file)
--   :Show [REV]    like `git show`: a commit against its parent (HEAD)
--   :Log [args]    the arguments of `git log`: its commits, each opening to
--                  the files it changed (% or -- PATHS: those files' history,
--                  following renames)
--
--   <leader>gd     :Diff          <leader>gf   :Diff -- %
--   <leader>gl     :Log           <leader>gh   :Log %
--
-- Files: compare.lua (comparisons and their changed files), log.lua
-- (history), object.lua (a file at a revision, as a buffer), view.lua (the
-- diff tab), watch.lua (live updates), signs.lua (the gutter), checkouts.lua
-- (worktrees, and what each has checked out).

local M = {}

local function cmd(root, args)
  return vim.list_extend({ 'git', '-C', root, '--no-pager', '-c', 'core.quotepath=off' }, args)
end

---Run git in `root` and wait (in a task, without blocking: task.lua).
---Returns stdout, or nil and the error.
---@param root string
---@param args string[]
---@return string?, string?
function M.run(root, args)
  local r = require('task').system(cmd(root, args))
  if r.code ~= 0 then return nil, vim.trim(r.stderr or '') end
  return r.stdout
end

---Run git in `root` without waiting; `callback(stdout?, err?)` runs on the
---main loop.
---@param root string
---@param args string[]
---@param callback fun(stdout: string?, err: string?)
function M.run_async(root, args, callback)
  vim.system(cmd(root, args), {}, vim.schedule_wrap(function(r)
    if r.code ~= 0 then return callback(nil, vim.trim(r.stderr or '')) end
    callback(r.stdout)
  end))
end

---The repository (or submodule, or worktree) of the current buffer: its
---file's, a git:// buffer's, the open diff view's, or the cwd's.
---@return string?
function M.root()
  local view = require('git.view').get()
  if view then return view.root end
  local obj = require('git.object').parse(vim.api.nvim_buf_get_name(0))
  if obj then return obj.root end
  return vim.fs.root(0, '.git') -- (from the cwd for unnamed and special buffers)
end

local function complete_refs(arglead)
  local root = M.root()
  local out = root and M.run(root, { 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes', 'refs/tags' })
  local words = vim.list_extend({ 'HEAD', '--staged', '--merge-base', '--' }, vim.split(out or '', '\n', { trimempty = true }))
  return arglead == '' and words or vim.fn.matchfuzzy(words, arglead)
end

---Open a view of `source(root)`, reporting bad arguments.
local function open(source)
  local root = M.root()
  if not root then return vim.notify('Not in a git repository', vim.log.levels.WARN) end
  local ok, src = pcall(source, root)
  if not ok then return vim.notify(tostring(src), vim.log.levels.ERROR) end
  require('git.view').open(root, src)
end

vim.api.nvim_create_user_command('Diff', function(c)
  open(function(root)
    local compare = require('git.compare')
    local make = function() return compare.parse(root, c.fargs) end
    local titles = vim.tbl_map(function(cmp) return cmp.title end, make())
    return compare.source('Diff ' .. table.concat(titles, ' + '), make)
  end)
end, { nargs = '*', complete = complete_refs, desc = 'Diff, with git diff arguments' })

vim.api.nvim_create_user_command('Show', function(c)
  open(function(root)
    local compare = require('git.compare')
    local cmp = compare.commit(root, c.args ~= '' and c.args or 'HEAD') -- pinned: a commit doesn't move
    return compare.source('Show ' .. cmp.title, function() return { cmp } end)
  end)
end, { nargs = '?', complete = complete_refs, desc = 'A commit against its parent' })

vim.api.nvim_create_user_command('Log', function(c)
  open(function(root)
    local log = require('git.log')
    return log.source(root, log.parse(c.fargs))
  end)
end, { nargs = '*', complete = complete_refs, desc = 'History, with git log arguments' })

vim.keymap.set('n', '<leader>gd', '<Cmd>Diff<CR>', { desc = 'Unstaged and staged changes' })
vim.keymap.set('n', '<leader>gf', '<Cmd>Diff -- %<CR>', { desc = "This file's changes" })
vim.keymap.set('n', '<leader>gl', '<Cmd>Log<CR>', { desc = 'History' })
vim.keymap.set('n', '<leader>gh', '<Cmd>Log %<CR>', { desc = "This file's history" })

-- ]f [f: next/previous file in a diff view (elsewhere, Vim's own: like gf).
for lhs, step in pairs({ [']f'] = 1, ['[f'] = -1 }) do
  vim.keymap.set('n', lhs, function()
    if not require('git.view').step(step * vim.v.count1) then vim.cmd.normal({ vim.v.count1 .. lhs, bang = true }) end
  end, { desc = step > 0 and 'Next file' or 'Previous file' })
end

local group = vim.api.nvim_create_augroup('git', {})

vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = 'git://*',
  callback = function(ev) require('git.object').load(ev.buf, ev.match) end,
})

-- Keep the current tab's diff view up to date as files, the index or HEAD change.
vim.api.nvim_create_autocmd({ 'BufWritePost', 'FileChangedShellPost', 'FocusGained', 'TabEnter' }, {
  group = group,
  callback = function() require('git.view').changed() end,
})
vim.api.nvim_create_autocmd('User', {
  group = group,
  -- Staged or unstaged a hunk, committed, ...; or review comments changed
  -- (the counts in the list).
  pattern = { 'GitSignsChanged', 'ReviewChanged' },
  callback = function() require('git.view').changed() end,
})
vim.api.nvim_create_autocmd('ColorScheme', {
  group = group,
  callback = function() require('git.view').highlights() end,
})
vim.api.nvim_create_autocmd('TabClosed', {
  group = group,
  callback = function() require('git.view').close_stale() end,
})

return M
