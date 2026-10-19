-- review/init.lua: review comments on code: on any file of a repository, at
-- any revision, in diff views and plain buffers. Kept per repository, until
-- you clear them (or send them to a pull request: github/). Threads, from
-- pull requests, show alongside them.
--
--   <leader>c        comment on this line (or edit its comment, or open its
--                    thread); in visual mode, on the selected lines. In the
--                    comment: ZZ saves, ZQ discards the edit, ZD deletes the
--                    comment. In a thread: write your reply below the rule;
--                    ZC resolves it (or reopens it)
--   <leader>C        delete the comment on this line
--   :Review          every comment and open thread, in the quickfix list
--                    (<leader>gc)
--   :Review export   as markdown, for an agent: copied to the clipboard (and
--                    written to a file, if you name one)
--   :Review clear    delete them all
--
-- Files: store.lua (saving them), marks.lua (showing them, following their
-- code as it moves), compose.lua (writing them), export.lua (markdown).

local M = {}

---@class review.Thread a discussion about code, from elsewhere (a pull request)
---@field id string
---@field path string
---@field rev string the content its lines are in (as a review.Comment's)
---@field line integer first line it's about (1 for the whole file)
---@field end_line integer
---@field code string[] those lines, to find them where they moved (none: the whole file)
---@field outdated? boolean its code has changed since
---@field resolved boolean
---@field pending boolean yours, not yet sent: only you can see it
---@field posts review.Post[]
---@field where string where it's from: '#123'
---@field resolve? fun(resolved: boolean) resolve it (or reopen it)

---@class review.Post
---@field author string
---@field body string
---@field time integer
---@field pending? boolean

local sources = {} ---@type (fun(root: string): review.Thread[])[]

---Add a source of threads: a function giving a repository's.
---@param fn fun(root: string): review.Thread[]
function M.add_source(fn) table.insert(sources, fn) end

---The threads on the repository at `root`.
---@return review.Thread[]
function M.threads(root)
  local threads = {}
  for _, fn in ipairs(sources) do vim.list_extend(threads, fn(root)) end
  return threads
end

---'3 days ago', for a time.
---@param t integer
function M.ago(t)
  local s = os.time() - t
  for _, u in ipairs({ { 'year', 31536000 }, { 'month', 2592000 }, { 'week', 604800 }, { 'day', 86400 },
    { 'hour', 3600 }, { 'minute', 60 } }) do
    local n = math.floor(s / u[2])
    if n >= 1 then return ('%d %s%s ago'):format(n, u[1], n == 1 and '' or 's') end
  end
  return 'just now'
end

-- "Viewed" is about a file's content: marking it records what it was, and a
-- change since (an agent's edit, a new commit) makes it unviewed again.
local function viewed_key(cmp, change) return cmp.right.rev .. ':' .. change.path end

local function token(root, change)
  if change.blob then return change.blob end -- a revision's content id
  local stat = vim.uv.fs_stat(vim.fs.joinpath(root, change.path)) -- the working tree's
  return stat and ('%d.%d.%d'):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or 'gone'
end

---How a diff view marks a changed file: viewed (and unchanged since), and how
---many comments and open threads it has, on either side.
---@param root string
---@param cmp git.Comparison
---@param change git.Change
---@return boolean viewed, integer comments, integer threads
function M.status(root, cmp, change)
  local function on(x) return x.path == change.path and (x.rev == cmp.left.rev or x.rev == cmp.right.rev) end
  local s = require('review.store').get(root)
  local threads = vim.tbl_filter(function(t) return on(t) and not t.resolved end, M.threads(root))
  return s.viewed[viewed_key(cmp, change)] == token(root, change), #vim.tbl_filter(on, s.comments), #threads
end

---Mark a changed file viewed (as it is now), or not. Returns whether it's viewed.
---@return boolean
function M.toggle_viewed(root, cmp, change)
  local store = require('review.store')
  local s = store.get(root)
  local key, now = viewed_key(cmp, change), token(root, change)
  local viewed = s.viewed[key] ~= now
  s.viewed[key] = viewed and now or nil
  store.save(s)
  return viewed
end

local function root()
  local r = require('git').root()
  if not r then vim.notify('Not in a git repository', vim.log.levels.WARN) end
  return r
end

local function list(r)
  local object, items = require('git.object'), {}
  local function add(x, text)
    local worktree = x.rev == 'worktree'
    table.insert(items, {
      filename = worktree and vim.fs.joinpath(r, x.path) or object.name(r, x.rev, x.path),
      module = worktree and x.path or ('%s @ %s'):format(x.path, x.rev == ':0' and 'index' or x.rev:sub(1, 7)),
      lnum = x.line,
      end_lnum = x.end_line,
      text = (x.outdated and '(outdated) ' or '') .. text,
    })
  end
  for _, c in ipairs(require('review.store').get(r).comments) do
    add(c, (c.thread and '↳ ' or '') .. vim.split(c.body, '\n')[1])
  end
  for _, t in ipairs(M.threads(r)) do
    if not t.resolved then add(t, ('◆ %s: %s'):format(t.posts[1].author, vim.split(t.posts[1].body, '\n')[1])) end
  end
  table.sort(items, function(a, b) return a.module < b.module or a.module == b.module and a.lnum < b.lnum end)
  vim.fn.setqflist({}, ' ', { title = 'Review comments', items = items })
  if #items == 0 then return vim.notify('No review comments') end
  vim.cmd('botright copen')
end

local function export(r, file)
  local md, count = require('review.export').markdown(r)
  vim.fn.setreg('+', md)
  if file then vim.fn.writefile(vim.split(md, '\n'), vim.fn.expand(file)) end
  vim.cmd('botright new')
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'nofile', 'wipe', 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(md, '\n'))
  vim.notify(('%d comments copied to the clipboard%s'):format(count, file and (', and written to ' .. file) or ''))
end

local function clear(r)
  local store = require('review.store')
  local s = store.get(r)
  if #s.comments == 0 then return vim.notify('No review comments') end
  local question = ('Delete all %d review comments in %s?'):format(#s.comments, vim.fn.fnamemodify(r, ':~'))
  if vim.fn.confirm(question, '&Delete\n&Cancel', 2, 'Warning') ~= 1 then return end
  s.comments = {}
  store.save(s)
  require('review.marks').render_all(r)
  vim.api.nvim_exec_autocmds('User', { pattern = 'ReviewChanged' })
end

vim.api.nvim_create_user_command('Review', function(c)
  local r = root()
  if not r then return end
  local action = c.fargs[1]
  if not action then return list(r) end
  if action == 'export' then return export(r, c.fargs[2]) end
  if action == 'clear' then return clear(r) end
  vim.notify('Usage: :Review [export [FILE] | clear]', vim.log.levels.ERROR)
end, {
  nargs = '*',
  complete = function(arglead, line)
    if line:match('^%s*%S+%s+%S+%s') then return {} end
    return vim.tbl_filter(function(w) return vim.startswith(w, arglead) end, { 'export', 'clear' })
  end,
  desc = 'Review comments: list, export, clear',
})

vim.keymap.set({ 'n', 'x' }, '<leader>c', function() require('review.compose').here() end, { desc = 'Comment' })
vim.keymap.set('n', '<leader>C', function() require('review.compose').delete_here() end, { desc = 'Delete comment' })
vim.keymap.set('n', '<leader>gc', '<Cmd>Review<CR>', { desc = 'Review comments' })

require('review.marks') -- its colours, which diff views use too

local group = vim.api.nvim_create_augroup('review', {})

vim.api.nvim_create_autocmd({ 'BufWinEnter', 'FileChangedShellPost' }, {
  group = group,
  callback = function(ev) require('review.marks').render(ev.buf) end,
})
vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  callback = function(ev) require('review.marks').sync(ev.buf) end,
})
vim.api.nvim_create_autocmd('ColorScheme', {
  group = group,
  callback = function() require('review.marks').highlights() end,
})

return M
