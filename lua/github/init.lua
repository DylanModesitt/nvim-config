-- github/init.lua: pull requests, through the gh CLI. One opens as a diff
-- view (git/view.lua) of what it changes, its review threads showing like
-- your comments (review/); your comments on it go back as a review.
--
--   :PR [PR]      open a pull request: this checkout's branch's, or NUMBER,
--                 OWNER/REPO#NUMBER or its URL (another repository's in a
--                 checkout of it near here: a submodule, the superproject).
--                 It's GitHub's diff, from where it branched to its head;
--                 when a checkout has its head checked out, that side is the
--                 checkout's files, live and editable. Again: reload it
--   :PR submit    send your comments on it, and replies, as one review
--   :PR browse    open it on GitHub
--   :PR list [FILTERS]
--                 this repository's pull requests, as GitHub searches them
--                 (FILTERS in its syntax: author:@me label:x ...; list.lua)
--   :PR inbox     yours, and those waiting for your review, everywhere
--
--   <leader>gp    :PR            <leader>gP   :PR list
--   <leader>gi    :PR inbox
--   K             in its view's list (or a list of them): read it, its
--                 description, checks, reviews and conversation
--
-- Threads are marked ◆: yellow while open, dim once resolved, blue while
-- they're yours and not sent. <leader>c on one opens it, to read and reply
-- (your reply goes with your review); ZC there resolves it, or reopens it.
--
-- Files: pr.lua (one: its commits, checkout, threads), submit.lua (reviews),
-- list.lua (lists of them), page.lua (one to read).

local checkouts = require('git.checkouts')
local git = require('git')
local task = require('task')

local M = {}

---A post's text as GitHub shows it: without its HTML comments (hidden there).
---@param body? string
---@return string
function M.clean(body) return vim.trim(((body or ''):gsub('\r', ''):gsub('<!%-%-.-%-%->', ''))) end

---'owner/name' to its owner and name.
---@param repo string
---@return string owner, string name
function M.split(repo) return repo:match('^(.-)/(.*)$') end

---Ask GitHub's GraphQL API. Returns the data, and any errors (a mutation
---of many parts can partly fail). Fails if no data came back.
---@return table data, table[]? errors
function M.graphql(query, variables)
  local body = vim.json.encode({ query = query, variables = variables or vim.empty_dict() })
  local r = task.system({ 'gh', 'api', 'graphql', '--input', '-' }, { stdin = body })
  local ok, res = pcall(vim.json.decode, r.stdout or '', { luanil = { object = true, array = true } })
  if not (ok and type(res) == 'table' and res.data) then
    local errors = ok and type(res) == 'table' and res.errors
    task.fail('GitHub: ' .. (errors and errors[1].message or vim.trim(r.stderr or 'no answer')))
  end
  return res.data, res.errors
end

---Ask GitHub's GraphQL API, failing on any error.
---@return table data
function M.query(query, variables)
  local data, errors = M.graphql(query, variables)
  if errors then task.fail('GitHub: ' .. errors[1].message) end
  return data
end

---Seconds since the epoch, for GitHub's '2026-10-03T14:05:09Z' (UTC, so
---computed directly: no time zones involved).
---@param iso string
---@return integer
function M.epoch(iso)
  local y, mo, d, h, mi, s = iso:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not y then return os.time() end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- Days from 1970-01-01 to the date (H. Hinnant's days_from_civil).
  y = mo <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

---The GitHub repositories a checkout's remotes are for: { remote, repo }.
local function remotes(root)
  local found = {}
  for name, url in (git.run(root, { 'remote', '-v' }) or ''):gmatch('(%S+)%s+(%S+) %(fetch%)') do
    local repo = url:match('github%.com[:/]([^/]+/[^/]+)$')
    if repo then table.insert(found, { remote = name, repo = (repo:gsub('%.git$', '')) }) end
  end
  return found
end

---The GitHub repository ('owner/name') a checkout is of: its origin's, else
---its first remote's on GitHub.
---@return string?
function M.repo(root)
  local found = remotes(root)
  local origin = vim.iter(found):find(function(r) return r.remote == 'origin' end)
  return (origin or found[1] or {}).repo
end

---The checkout's remote for `repo`.
function M.remote(root, repo)
  local found = vim.iter(remotes(root)):find(function(r) return r.repo:lower() == repo:lower() end)
  return found and found.remote or 'origin'
end

---The GitHub repositories near `root`, and a checkout of each (see
---git/checkouts.lua). Keyed by 'owner/name', lowercase (GitHub's names
---aren't case-sensitive).
---@return table<string, string>
function M.nearby(root)
  local found = {}
  for _, dir in ipairs(checkouts.near(root)) do
    local repo = M.repo(dir)
    if repo and not found[repo:lower()] then found[repo:lower()] = dir end
  end
  return found
end

---A checkout of `repo` near `root` (see M.nearby).
---@return string?
function M.checkout(root, repo) return M.nearby(root)[repo:lower()] end

---Whether checkout `dir` has a pull request checked out: its head commit,
---or its branch (unless it's a fork's: that name could be anyone's).
---@param dir string
---@param pr { head: string, head_oid: string, fork: boolean }
function M.holds(dir, pr)
  local h = checkouts.head(dir)
  return h ~= nil and (h.sha == pr.head_oid or not pr.fork and h.branch == pr.head)
end

-- GitHub's search syntax, to complete :PR list's filters with.
local filters = { 'is:open', 'is:closed', 'is:merged', 'is:draft', 'draft:false', 'author:@me', 'author:',
  'assignee:@me', 'review-requested:@me', 'reviewed-by:@me', 'involves:@me', 'commenter:@me', 'mentions:@me',
  'review:required', 'review:approved', 'review:changes_requested', 'status:success', 'status:failure',
  'status:pending', 'label:', '-label:', 'base:', 'head:', 'repo:', 'org:', 'user:', 'archived:false',
  'sort:updated-desc', 'sort:created-desc', 'sort:created-asc', 'sort:comments-desc', 'updated:>', 'created:>' }

vim.api.nvim_create_user_command('PR', function(c)
  local arg = c.fargs[1]
  if arg == 'submit' then return require('github.submit').open() end
  if arg == 'browse' then return require('github.pr').browse() end
  if arg == 'list' then return require('github.list').open(table.concat(vim.list_slice(c.fargs, 2), ' ')) end
  if arg == 'inbox' then return require('github.list').inbox() end
  require('github.pr').open(arg)
end, {
  nargs = '*',
  complete = function(arglead, line)
    local words = line:match('^%s*%S+%s+(%S+)%s') == 'list' and filters or { 'submit', 'browse', 'list', 'inbox' }
    if line:match('^%s*%S+%s+%S+%s') and words ~= filters then return {} end
    return vim.tbl_filter(function(w) return vim.startswith(w, arglead) end, words)
  end,
  desc = 'Pull requests: open, submit a review, browse, list, inbox',
})

vim.keymap.set('n', '<leader>gp', '<Cmd>PR<CR>', { desc = 'Pull request' })
vim.keymap.set('n', '<leader>gP', '<Cmd>PR list<CR>', { desc = "This repository's pull requests" })
vim.keymap.set('n', '<leader>gi', '<Cmd>PR inbox<CR>', { desc = 'Pull requests: yours, and for you to review' })

-- Keep a pull request's threads current: reload it on coming back to its
-- view, if it's been a minute.
vim.api.nvim_create_autocmd({ 'FocusGained', 'TabEnter' }, {
  group = vim.api.nvim_create_augroup('github', {}),
  callback = function()
    local view = require('git.view').get()
    local pr = view and view.source.pr
    if pr and os.time() - pr.fetched >= 60 then require('github.pr').reload(pr) end
  end,
})

return M
