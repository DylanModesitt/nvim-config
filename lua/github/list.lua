-- github/list.lua: lists of pull requests. Each is a GitHub search, in
-- GitHub's own syntax (the first line says which), and opens in the window
-- like a file.
--
--   :PR list [FILTERS]  this repository's: the open ones, or those FILTERS
--                       pick (author:@me review:required label:x is:merged
--                       sort:created-desc ...; Tab completes them). Naming
--                       repo:, org: or user: searches beyond this repository
--   :PR inbox           yours, and those waiting for your review, in every
--                       repository
--
-- In a list:
--   <CR>   open it (in a checkout of its repository near here); on "⋯ more",
--          load the next 100
--   K      read it: its description, checks, reviews and conversation
--   o      open it on GitHub
--   f      change the filters (on the command line, as :PR list ...)
--   R      reload
--   q      back to the buffer before
--
-- One checked out in a checkout near here says where (⎇): you can edit it
-- as you review it.

local checkouts = require('git.checkouts')
local gh = require('github')
local task = require('task')

local M = {}

local FIELDS = [[
fragment pr on PullRequest {
  number title url state isDraft updatedAt reviewDecision headRefName headRefOid isCrossRepository
  author { login }
  repository { nameWithOwner }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}]]

local checks = { SUCCESS = { '✓', 'Added' }, FAILURE = { '✗', 'Removed' }, ERROR = { '✗', 'Removed' } }
local decisions = { APPROVED = 'approved', CHANGES_REQUESTED = 'changes requested' }
local ns = vim.api.nvim_create_namespace('github.list')

---@class github.List
---@field kind 'list'|'inbox'
---@field root? string where it was opened (where <CR> looks for checkouts)
---@field scoped? boolean whether it searches only that repository
---@field filters string
---@field searches { title?: string, query: string }[]
---@field results? table[] each search's, as far as loaded
---@field me? string your login
---@field places? table<string, { dir: string, name: string }[]> checkouts near here
---@field rows table<integer, table> what each line shows: a pull request, or { more = search }
---@field back? integer the buffer it was opened over (q goes back to it)

local lists = {} ---@type table<integer, github.List> buf -> its list

---Run the searches, at once (each from its cursor in `after`, if given):
---their results, and who you are.
local function search(searches, after)
  local params, fields, vars = {}, {}, {}
  for i, s in ipairs(searches) do
    params[i] = ('$q%d: String!, $a%d: String'):format(i, i)
    fields[i] = ('s%d: search(query: $q%d, type: ISSUE, first: 100, after: $a%d) {'
      .. ' issueCount pageInfo { hasNextPage endCursor } nodes { ...pr } }'):format(i, i, i)
    vars['q' .. i], vars['a' .. i] = s.query, after and after[i]
  end
  local query = ('query(%s) {\nviewer { login }\n%s\n}\n%s'):format(table.concat(params, ', '),
    table.concat(fields, '\n'), FIELDS)
  local data = gh.query(query, vars)
  local results = {}
  for i in ipairs(searches) do results[i] = data['s' .. i] end
  return results, data.viewer.login
end

---Where they're checked out near the list's checkout: for each pull
---request's repository, its checkouts (and their names here).
local function places(list, repos)
  if not list.root then return {} end
  local nearby = gh.nearby(list.root)
  local top = checkouts.superproject(list.root) or list.root
  local base = vim.fs.dirname(top) -- checkouts are named from here: worktrees are often side by side
  local found = {}
  for repo in pairs(repos) do
    local dir = nearby[repo]
    if dir then
      found[repo] = vim.tbl_map(function(d)
        local name = d == list.root and 'here' or vim.fs.relpath(base, d) or vim.fn.fnamemodify(d, ':~')
        local sub = vim.fs.relpath(top, dir) -- a submodule's path: in each checkout, the same
        if sub and sub ~= '.' and name:sub(-#sub - 1) == '/' .. sub then name = name:sub(1, -#sub - 2) end
        return { dir = d, name = name }
      end, checkouts.all(dir))
    end
  end
  return found
end

local function shorten(text, width)
  if vim.fn.strdisplaywidth(text) <= width then return text end
  return vim.fn.strcharpart(text, 0, width - 1) .. '…'
end

-- Columns a checkout's name keeps when a row is short of room: a long one (a
-- path) gives way, rather than every title.
local NAMEW = 24

---A row's details, within `width` if its checkout's name can give way: it
---loses its start (a path's end says the most), down to NAMEW columns.
---@return string details, string? where the checkout's part of them
local function details(row, width)
  local function with(name)
    local parts = vim.list_slice(row.meta)
    if name then table.insert(parts, '⎇ ' .. name) end
    table.insert(parts, row.ago)
    return table.concat(parts, ' · ')
  end
  if not row.name then return with(nil) end
  local room = math.max(NAMEW, width - vim.fn.strdisplaywidth(with('')))
  local name = row.name
  if vim.fn.strdisplaywidth(name) > room then
    name = '…' .. vim.fn.strcharpart(name, vim.fn.strchars(name) - room + 1)
  end
  return with(name), '⎇ ' .. name
end

---Fill the list's buffer with its results.
local function render(buf, list)
  local results, me, found = list.results, list.me, list.places
  local win = vim.fn.bufwinid(buf)
  local width = win > 0 and vim.api.nvim_win_get_width(win) or vim.o.columns
  local rows, refw, metaw = {}, 0, 0
  for i, result in ipairs(results) do
    for _, p in ipairs(result.nodes) do
      local repo = p.repository.nameWithOwner
      local ref = list.scoped and ('#%d'):format(p.number) or ('%s#%d'):format(repo:match('[^/]+$'), p.number)
      local meta, name = {}, nil
      local author = p.author and p.author.login or 'ghost'
      if not (list.kind == 'inbox' and i == 1) then table.insert(meta, author == me and 'you' or author) end
      if p.state ~= 'OPEN' then table.insert(meta, p.state:lower()) end
      if p.isDraft then table.insert(meta, 'draft') end
      if decisions[p.reviewDecision] then table.insert(meta, decisions[p.reviewDecision]) end
      for _, c in ipairs(found[repo:lower()] or {}) do
        if gh.holds(c.dir, { head = p.headRefName, head_oid = p.headRefOid, fork = p.isCrossRepository }) then
          name = c.name
          break
        end
      end
      local commit = p.commits.nodes[1]
      local rollup = commit and commit.commit.statusCheckRollup
      local row = { pr = p, section = i, ref = ref, meta = meta, name = name,
        ago = require('review').ago(gh.epoch(p.updatedAt)),
        check = rollup and (checks[rollup.state] or { '●', 'DiagnosticWarn' }) or { ' ' } }
      table.insert(rows, row)
      refw = math.max(refw, #ref)
      metaw = math.max(metaw, vim.fn.strdisplaywidth((details(row, 0))))
    end
  end
  -- Titles in a column, as wide as the window leaves them (but readable).
  local titlew = 0
  for _, row in ipairs(rows) do titlew = math.max(titlew, vim.fn.strdisplaywidth(row.pr.title)) end
  titlew = math.min(titlew, math.max(30, width - (2 + refw + 4) - metaw - 3))

  local lines, hls, at = {}, {}, {}
  local function head(i, result)
    local s = list.searches[i]
    local count = result.issueCount > #result.nodes and ('%d of %d'):format(#result.nodes, result.issueCount)
      or tostring(result.issueCount)
    local title = s.title and ('%s (%s)'):format(s.title, count) or s.query
    local line = s.title and ('%s  %s'):format(title, s.query) or ('%s  (%s)'):format(title, count)
    if #lines > 0 then table.insert(lines, '') end
    table.insert(lines, line)
    table.insert(hls, { #lines, 0, #title, 'Title' })
    table.insert(hls, { #lines, #title, #line, 'Comment' })
  end
  local section = 0
  for i, result in ipairs(results) do
    if #result.nodes == 0 then
      head(i, result)
      table.insert(lines, '  (none)')
      table.insert(hls, { #lines, 0, #lines[#lines], 'Comment' })
    end
    for _, row in ipairs(rows) do
      if row.section == i then
        if section ~= i then
          head(i, result)
          section = i
        end
        local title = shorten(row.pr.title, titlew)
        local pad = (' '):rep(titlew - vim.fn.strdisplaywidth(title))
        local prefix = ('  %-' .. refw .. 's  '):format(row.ref)
        local meta, where = details(row, width - (2 + refw + 4) - titlew - 3)
        local line = ('%s%s %s%s  %s'):format(prefix, row.check[1], title, pad, meta)
        table.insert(lines, line)
        table.insert(hls, { #lines, 2, 2 + #row.ref, 'Identifier' })
        if row.check[2] then table.insert(hls, { #lines, #prefix, #prefix + #row.check[1], row.check[2] }) end
        local meta_at = #line - #meta
        table.insert(hls, { #lines, meta_at, #line, 'Comment' })
        if where then
          local s = line:find(where, meta_at + 1, true)
          if s then table.insert(hls, { #lines, s - 1, s - 1 + #where, 'Special' }) end
        end
        at[#lines] = row.pr
      end
    end
    if result.pageInfo.hasNextPage then
      table.insert(lines, ('  ⋯ %d more (Enter loads them)'):format(result.issueCount - #result.nodes))
      table.insert(hls, { #lines, 0, #lines[#lines], 'Comment' })
      at[#lines] = { more = i }
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.hl.range(buf, ns, h[4], { h[1] - 1, h[2] }, { h[1] - 1, h[3] })
  end
  list.rows = at
end

local function repos(results)
  local found = {}
  for _, r in ipairs(results) do
    for _, p in ipairs(r.nodes) do found[p.repository.nameWithOwner:lower()] = true end
  end
  return found
end

---Run the list's searches and show what they find.
local function load(buf)
  local list = lists[buf]
  task.run(function()
    local results, me = search(list.searches)
    local found = places(list, repos(results))
    if not (vim.api.nvim_buf_is_valid(buf) and lists[buf] == list) then return end
    list.results, list.me, list.places = results, me, found
    render(buf, list)
  end)
end

---Load the next page of search `i`, below what's shown.
local function more(buf, i)
  local list = lists[buf]
  local result = list.results[i]
  vim.notify(('Loading %d more…'):format(result.issueCount - #result.nodes))
  task.run(function()
    local after = {}
    after[1] = result.pageInfo.endCursor
    local page = search({ list.searches[i] }, after)[1]
    local found = places(list, repos({ page }))
    if not (vim.api.nvim_buf_is_valid(buf) and lists[buf] == list) then return end
    vim.list_extend(result.nodes, page.nodes)
    result.pageInfo = page.pageInfo
    list.places = vim.tbl_extend('keep', list.places, found)
    render(buf, list)
    vim.cmd.echo('""')
  end)
end

---Show `list` in the current window (in the buffer for its kind), and load it.
---@param list github.List
local function show(list)
  local name = list.kind == 'inbox' and 'Pull requests: inbox' or 'Pull requests'
  local buf = vim.fn.bufnr('^' .. name .. '$')
  if buf < 0 then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].bufhidden, vim.bo[buf].filetype, vim.bo[buf].modifiable = 'hide', 'prlist', false
    local function map(lhs, fn, desc) vim.keymap.set('n', lhs, fn, { buf = buf, desc = desc }) end
    local function here() return lists[buf].rows[vim.api.nvim_win_get_cursor(0)[1]] end
    map('<CR>', function()
      local p = here()
      if not p then return end
      if p.more then return more(buf, p.more) end
      if not lists[buf].root then
        return vim.notify('Not in a git repository: o opens it on GitHub', vim.log.levels.WARN)
      end
      require('github.pr').open(('%s#%d'):format(p.repository.nameWithOwner, p.number), lists[buf].root)
    end, 'Open the pull request')
    map('K', function()
      local p = here()
      if p and p.number then require('github.page').open(p.repository.nameWithOwner, p.number) end
    end, 'Read the pull request')
    map('o', function()
      local p = here()
      if p and p.url then vim.ui.open(p.url) end
    end, 'Open it on GitHub')
    map('f', function() vim.api.nvim_feedkeys(':PR list ' .. lists[buf].filters, 'n', false) end, 'Change the filters')
    map('R', function() load(buf) end, 'Reload')
    map('q', function()
      local back = lists[buf].back
      if back and vim.api.nvim_buf_is_valid(back) then return vim.api.nvim_win_set_buf(0, back) end
      vim.cmd.enew()
    end, 'Back')
  end
  if require('git.view').get() then vim.cmd.tabnew() end -- (not into a diff view's windows)
  -- q goes back to the buffer it opens over (over a list, to where that went back to).
  local over = vim.api.nvim_get_current_buf()
  if lists[over] then list.back = lists[over].back else list.back = over end
  vim.api.nvim_win_set_buf(0, buf)
  local wo = vim.wo[0][0]
  wo.number, wo.relativenumber, wo.signcolumn, wo.wrap, wo.list, wo.cursorline = false, false, 'no', false, false, true

  lists[buf] = list
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(function(s) return s.query end, list.searches))
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '  Loading…' })
  vim.bo[buf].modifiable = false
  load(buf)
end

---This repository's pull requests: those `filters` pick (default: the open
---ones). Filters naming repo:, org: or user: reach beyond it.
---@param filters string
function M.open(filters)
  local root = require('git').root()
  task.run(function()
    if not root then task.fail('Not in a git repository (:PR inbox lists yours, everywhere)') end
    ---@cast root string
    local repo = gh.repo(root) or task.fail('No GitHub remote in ' .. vim.fn.fnamemodify(root, ':~'))
    filters = vim.trim(filters)
    if filters == '' then filters = 'is:open' end
    local scoped = not (' ' .. filters):match('%s%-?repo:') and not (' ' .. filters):match('%s%-?org:')
      and not (' ' .. filters):match('%s%-?user:')
    local query = ('is:pr %s%s'):format(scoped and ('repo:%s '):format(repo) or '', filters)
    if not filters:match('sort:') then query = query .. ' sort:updated-desc' end
    show({ kind = 'list', root = root, scoped = scoped, filters = filters, searches = { { query = query } },
      rows = {} })
  end)
end

---Yours, and those waiting for your review, in every repository.
function M.inbox()
  show({
    kind = 'inbox',
    root = require('git').root(),
    filters = '',
    searches = {
      { title = 'Yours', query = 'is:pr is:open author:@me archived:false sort:updated-desc' },
      { title = 'Waiting for your review', query = 'is:pr is:open review-requested:@me archived:false sort:updated-desc' },
    },
    rows = {},
  })
end

return M
