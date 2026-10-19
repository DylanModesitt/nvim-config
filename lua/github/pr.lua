-- github/pr.lua: a pull request, loaded: its data from GitHub, its commits in
-- a local checkout (fetched if they're missing), the two sides of its diff
-- there, and its review threads. A loaded one stays loaded, so its threads
-- show in the checkout's files too, not only in its view.

local git = require('git')
local checkouts = require('git.checkouts')
local gh = require('github')
local store = require('review.store')
local task = require('task')

local M = {}

---@class github.PR
---@field key string 'owner/name#number'
---@field repo string 'owner/name'
---@field number integer
---@field id string its GraphQL id
---@field title string
---@field url string
---@field state string OPEN, CLOSED or MERGED
---@field draft boolean
---@field author string
---@field mine boolean you opened it
---@field base string its base branch
---@field head string its head branch
---@field base_oid string
---@field head_oid string
---@field fork boolean its head is another repository's
---@field review? string your pending review on GitHub (its id), if you have one
---@field root string the checkout it's shown in
---@field left git.Side where it branched from its base
---@field right git.Side its head: the checkout's files if it has it checked out, else the commit
---@field threads review.Thread[]
---@field fetched integer when it was loaded

local loaded = {} ---@type table<string, github.PR>

local QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id title url state isDraft viewerDidAuthor
      author { login }
      baseRefName headRefName baseRefOid headRefOid
      headRepository { nameWithOwner }
      reviews(states: PENDING, first: 1) { nodes { id } }
      reviewThreads(first: 100) {
        nodes {
          id isResolved isOutdated path diffSide subjectType
          line startLine originalLine originalStartLine
          comments(first: 100) { nodes { author { login } body createdAt state diffHunk } }
        }
      }
    }
  }
}]]

---'owner/name#number' or a URL to its parts; just a number is this
---repository's.
---@return string? repo, integer? number
local function parse(arg)
  local repo, n = arg:match('github%.com/([^/]+/[^/]+)/pull/(%d+)')
  if not repo then repo, n = arg:match('^([%w._-]+/[%w._-]+)#(%d+)$') end
  if not repo then n = arg:match('^#?(%d+)$') end
  return repo, tonumber(n)
end

---The lines a thread is about: the last `count` lines of its side in the
---diff hunk GitHub keeps with it (which ends at them).
local function hunk_code(hunk, side, count)
  local lines, mine = {}, side == 'LEFT' and '-' or '+'
  for i, l in ipairs(vim.split(hunk or '', '\n', { plain = true })) do
    local mark = l:sub(1, 1)
    if i > 1 and (mark == ' ' or mark == mine) then table.insert(lines, l:sub(2)) end
  end
  return vim.list_slice(lines, math.max(1, #lines - count + 1))
end

---Mark a thread resolved, or not.
local function resolve(pr, thread, resolved)
  task.run(function()
    local field = resolved and 'resolveReviewThread' or 'unresolveReviewThread'
    gh.query(('mutation($id: ID!) { %s(input: { threadId: $id }) { thread { isResolved } } }'):format(field),
      { id = thread.id })
    thread.resolved = resolved
    M.changed(pr)
    vim.notify(resolved and 'Resolved' or 'Reopened')
  end)
end

---@return review.Thread
local function thread(pr, t)
  local posts = {}
  for _, c in ipairs(t.comments.nodes) do
    table.insert(posts, {
      author = c.author and c.author.login or 'ghost',
      body = gh.clean(c.body),
      time = gh.epoch(c.createdAt),
      pending = c.state == 'PENDING' or nil,
    })
  end
  local last = t.line or t.originalLine
  local first = (t.line and t.startLine or not t.line and t.originalStartLine) or last
  local whole = t.subjectType == 'FILE' or not last -- about the whole file
  local th = { ---@type review.Thread
    id = t.id,
    path = t.path,
    rev = t.diffSide == 'LEFT' and pr.left.rev or pr.right.rev,
    line = whole and 1 or first,
    end_line = whole and 1 or last,
    code = whole and {} or hunk_code(t.comments.nodes[1].diffHunk, t.diffSide, last - first + 1),
    outdated = t.isOutdated or nil,
    resolved = t.isResolved,
    pending = vim.iter(posts):all(function(p) return p.pending end),
    posts = posts,
    where = '#' .. pr.number,
  }
  if not th.pending then th.resolve = function(resolved) resolve(pr, th, resolved) end end
  return th
end

local function has(root, oid) return git.run(root, { 'cat-file', '-e', oid .. '^{commit}' }) ~= nil end

---Its two sides, in its checkout: fetching its commits first, if need be.
local function sides(pr)
  local root, remote = pr.root, gh.remote(pr.root, pr.repo)
  if not has(root, pr.head_oid) then
    vim.notify(('Fetching %s…'):format(pr.key))
    local _, err = git.run(root, { 'fetch', '--quiet', '--no-write-fetch-head', remote, ('refs/pull/%d/head'):format(pr.number) })
    if err then task.fail(err) end
  end
  if not has(root, pr.base_oid) then
    local _, err = git.run(root, { 'fetch', '--quiet', '--no-write-fetch-head', remote, 'refs/heads/' .. pr.base })
    if err then task.fail(err) end
  end
  local base, err = git.run(root, { 'merge-base', pr.base_oid, pr.head_oid })
  if not base then return task.fail(err) end
  pr.left = { rev = vim.trim(base), label = pr.base }
  pr.right = { rev = gh.holds(root, pr) and 'worktree' or pr.head_oid, label = pr.head }
end

---Your comments on a side that moved (new commits pushed, a new base) move
---with it, to be found again in its new content.
local function follow(pr, before)
  local moves = {}
  if before.right and before.right.rev ~= 'worktree' and before.right.rev ~= pr.right.rev then
    moves[before.right.rev] = pr.right.rev
  end
  if before.left and before.left.rev ~= pr.left.rev then moves[before.left.rev] = pr.left.rev end
  if not next(moves) then return end
  local s = store.get(pr.root)
  for _, c in ipairs(s.comments) do c.rev = moves[c.rev] or c.rev end
  store.save(s)
end

---Load a pull request (again): from GitHub, into a checkout of `root`'s
---repository: one that has it checked out, if any does, else `root`.
---@return github.PR
function M.load(root, repo, number)
  local owner, name = gh.split(repo)
  local p = gh.query(QUERY, { owner = owner, name = name, number = number }).repository.pullRequest
  local key = ('%s#%d'):format(repo, number)
  local pr = loaded[key] or { key = key, repo = repo, number = number } ---@type github.PR
  local before = { left = pr.left, right = pr.right }
  pr.id, pr.title, pr.url, pr.state, pr.draft = p.id, p.title, p.url, p.state, p.isDraft
  pr.author, pr.mine = p.author and p.author.login or 'ghost', p.viewerDidAuthor
  pr.base, pr.head, pr.base_oid, pr.head_oid = p.baseRefName, p.headRefName, p.baseRefOid, p.headRefOid
  pr.fork = (p.headRepository and p.headRepository.nameWithOwner or ''):lower() ~= repo:lower()
  pr.review = p.reviews.nodes[1] and p.reviews.nodes[1].id
  if not pr.root then
    pr.root = vim.iter(checkouts.all(root)):find(function(dir) return gh.holds(dir, pr) end) or root
  end
  sides(pr)
  follow(pr, before)
  pr.threads = vim.iter(p.reviewThreads.nodes)
    :filter(function(t) return #t.comments.nodes > 0 end)
    :map(function(t) return thread(pr, t) end)
    :totable()
  pr.fetched = os.time()
  loaded[key] = pr
  return pr
end

---Show a pull request's changes: its threads, wherever its files are shown.
function M.changed(pr)
  require('review.marks').render_all(pr.root)
  require('git.view').changed()
end

---Load a pull request again, in the background.
function M.reload(pr)
  pr.fetched = os.time() -- (once at a time)
  task.run(function()
    M.load(pr.root, pr.repo, pr.number)
    M.changed(pr)
  end)
end

local function summary(pr)
  local open = #vim.tbl_filter(function(t) return not t.resolved end, pr.threads)
  local parts = { ('%s → %s'):format(pr.head, pr.base), pr.author }
  if pr.draft then table.insert(parts, 'draft') end
  if pr.state ~= 'OPEN' then table.insert(parts, pr.state:lower()) end
  if open > 0 then table.insert(parts, ('◆ %d open'):format(open)) end
  return table.concat(parts, ' · ')
end

---A view source for a pull request: one section, its changes.
---@return git.Source
function M.source(pr)
  return {
    title = ('#%d %s'):format(pr.number, pr.title),
    worktree = pr.right.rev == 'worktree',
    pr = pr,
    keys = { K = { function() require('github.page').open(pr.repo, pr.number) end, 'Read the pull request' } },
    fetch = function(callback)
      local cmp = require('git.compare').new(pr.root, pr.left, pr.right, ('#%d %s'):format(pr.number, pr.title))
      require('git.compare').changes(cmp, function(changes, err)
        callback({ { key = pr.key, cmp = cmp, changes = changes or {}, detail = summary(pr) } }, err)
      end)
    end,
  }
end

---The pull request for what `root` has checked out: its branch's (an open
---one, else the latest), or its detached commit's.
local function number_here(root, repo)
  local owner, name = gh.split(repo)
  local h = checkouts.head(root) or {}
  local prs
  if h.branch then
    prs = gh.query([[query($owner: String!, $name: String!, $branch: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(headRefName: $branch, first: 5, orderBy: { field: UPDATED_AT, direction: DESC }) {
          nodes { number state headRepository { nameWithOwner } }
        }
      }
    }]], { owner = owner, name = name, branch = h.branch }).repository.pullRequests.nodes
    prs = vim.tbl_filter(function(p) -- not a fork's same-named branch
      return p.headRepository and p.headRepository.nameWithOwner:lower() == repo:lower()
    end, prs)
  elseif h.sha then
    local commit = gh.query([[query($owner: String!, $name: String!, $sha: GitObjectID!) {
      repository(owner: $owner, name: $name) {
        object(oid: $sha) { ... on Commit { associatedPullRequests(first: 5) { nodes { number state } } } }
      }
    }]], { owner = owner, name = name, sha = h.sha }).repository.object
    prs = commit and commit.associatedPullRequests.nodes or {}
  end
  local pr = vim.iter(prs or {}):find(function(p) return p.state == 'OPEN' end) or (prs or {})[1]
  if not pr then task.fail(('No pull request for %s'):format(h.branch or 'this checkout')) end
  return pr.number
end

---Which pull request `arg` (as :PR takes it) means, from `root`: its
---repository, its number, and a checkout of the repository.
local function which(arg, root)
  local repo, number = nil, nil
  if arg then
    repo, number = parse(arg)
    if not number then task.fail('Not a pull request: ' .. arg) end
  end
  local here = gh.repo(root)
  if repo and repo:lower() ~= (here or ''):lower() then
    root = gh.checkout(root, repo) or task.fail(('No checkout of %s here'):format(repo))
  end
  repo = repo or here or task.fail('No GitHub remote in ' .. vim.fn.fnamemodify(root, ':~'))
  return repo, number or number_here(root, repo), root
end

---The pull request you're looking at: the current view's, else one loaded
---in this checkout.
---@return github.PR?
function M.current()
  local view = require('git.view').get()
  if view and view.source.pr then return view.source.pr end
  local root = require('git').root()
  return vim.iter(vim.tbl_values(loaded)):find(function(pr) return pr.root == root end)
end

---Open a pull request (`arg`, as :PR takes it) in a view; if it's open
---already, go to it and reload it.
---@param arg? string
---@param root? string where to look from (default: here)
function M.open(arg, root)
  task.run(function()
    root = root or require('git').root() or task.fail('Not in a git repository')
    local repo, number
    repo, number, root = which(arg, root)
    local key = ('%s#%d'):format(repo, number)
    local view = require('git.view').find(function(v) return v.source.pr ~= nil and v.source.pr.key == key end)
    if view then vim.api.nvim_set_current_tabpage(view.tab) end
    vim.notify(('Loading %s…'):format(key))
    local pr = M.load(root, repo, number)
    if view then
      M.changed(pr)
    else -- (built on the main loop, not in this task, so it's whole before anything else runs)
      vim.schedule(function() require('git.view').open(pr.root, M.source(pr)) end)
    end
    vim.cmd.echo('""')
  end)
end

---Open the pull request on GitHub: the one you're looking at, else this
---checkout's.
function M.browse()
  local pr = M.current()
  if pr then return vim.ui.open(pr.url) end
  task.run(function()
    local root = require('git').root() or task.fail('Not in a git repository')
    local repo, number = which(nil, root)
    vim.ui.open(('https://github.com/%s/pull/%d'):format(repo, number))
  end)
end

-- Threads of the pull requests loaded in a checkout show on its files.
require('review').add_source(function(root)
  local threads = {}
  for _, pr in pairs(loaded) do
    if pr.root == root then vim.list_extend(threads, pr.threads) end
  end
  return threads
end)

return M
