-- git/compare.lua: comparisons, and the files that changed between their sides.
--
-- A side is the working tree, the index, or a commit. A comparison is a left
-- and a right side (plus, optionally, paths to limit it to). Its changes are
-- the files that differ, as `git diff` lists them.

local git = require('git')

local M = {}

---@class git.Side
---@field rev string 'worktree', ':0' (the index) or a commit sha
---@field label string how to show it: 'worktree', 'index', 'HEAD', 'main', ...

---@class git.Comparison
---@field root string
---@field left git.Side
---@field right git.Side
---@field paths string[] pathspecs to limit it to (none: everything)
---@field title string
---@field kind? 'unstaged'|'staged' the working tree's or the index's own changes (which s stages)

---@class git.Change
---@field path string
---@field oldpath? string where a rename or copy came from
---@field status string A M D R C T U, or ? (untracked)
---@field added? integer lines
---@field removed? integer lines
---@field binary? boolean
---@field submodule? boolean
---@field blob? string the right side's content (a blob id), unless it's the working tree

local WORKTREE = { rev = 'worktree', label = 'worktree' }
local INDEX = { rev = ':0', label = 'index' }
M.EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904' -- the left side of a root commit

---@return git.Side
local function commit(root, rev)
  local sha = git.run(root, { 'rev-parse', '--verify', '--quiet', rev .. '^{commit}' })
  if not sha then error('Not a commit: ' .. rev, 0) end
  return { rev = vim.trim(sha), label = rev }
end

---@return git.Side
local function merge_base(root, a, b)
  local sha = git.run(root, { 'merge-base', a.rev, b.rev })
  if not sha then error(('No merge base for %s and %s'):format(a.label, b.label), 0) end
  return { rev = vim.trim(sha), label = ('%s...%s'):format(a.label, b.label) }
end

---@return git.Comparison
function M.new(root, left, right, title, paths)
  return { root = root, left = left, right = right, title = title, paths = paths or {} }
end

function M.unstaged(root, paths)
  local cmp = M.new(root, INDEX, WORKTREE, 'Unstaged', paths)
  cmp.kind = 'unstaged'
  return cmp
end

function M.staged(root, paths)
  local cmp = M.new(root, commit(root, 'HEAD'), INDEX, 'Staged', paths)
  cmp.kind = 'staged'
  return cmp
end

---A commit against its first parent, like `git show`.
function M.commit(root, rev)
  local right = commit(root, rev)
  local parent = git.run(root, { 'rev-parse', '--verify', '--quiet', right.rev .. '^' })
  local left = { rev = parent and vim.trim(parent) or M.EMPTY_TREE, label = rev .. '^' }
  local title = vim.trim(git.run(root, { 'log', '-1', '--format=%h %s', right.rev }) or rev)
  return M.new(root, left, right, title)
end

---Pathspecs are relative to the cwd (as in a shell); % is the current file.
function M.pathspec(p)
  if p == '%' then return vim.fn.expand('%:p') end
  return vim.startswith(p, '/') and p or vim.fs.joinpath(vim.fn.getcwd(), p)
end

---The comparisons `git diff <args>` would show.
---@param root string
---@param args string[]
---@return git.Comparison[]
function M.parse(root, args)
  local revs, paths, staged, base, flags = {}, {}, false, false, args
  for i, a in ipairs(args) do
    if a == '--' then
      paths, flags = vim.tbl_map(M.pathspec, vim.list_slice(args, i + 1)), vim.list_slice(args, 1, i - 1)
      break
    elseif a == '--staged' or a == '--cached' then
      staged = true
    elseif a == '--merge-base' then
      base = true
    else
      table.insert(revs, a)
    end
  end
  local title = table.concat(flags, ' ')

  local a, dots, b = (revs[1] or ''):match('^(.-)(%.%.%.?)(.*)$')
  if #revs == 1 and dots then
    revs = { a ~= '' and a or 'HEAD', b ~= '' and b or 'HEAD' }
    base = dots == '...'
  end

  if #revs == 0 then
    if staged then return { M.staged(root, paths) } end
    return { M.unstaged(root, paths), M.staged(root, paths) }
  end
  local left = commit(root, revs[1])
  if #revs == 1 then
    if base then left = merge_base(root, left, commit(root, 'HEAD')) end
    return { M.new(root, left, staged and INDEX or WORKTREE, title, paths) }
  end
  local right = commit(root, revs[2])
  if base then left = merge_base(root, left, right) end
  return { M.new(root, left, right, title, paths) }
end

---`git diff` arguments selecting the comparison's two sides.
local function diff_args(cmp)
  local l, r = cmp.left.rev, cmp.right.rev
  if r == 'worktree' then return l == ':0' and {} or { l } end
  if r == ':0' then return { '--cached', l } end
  return { l, r }
end

---Changes from `--raw --numstat -z` output: raw entries (status, modes,
---paths), then numstat entries (line counts; '-' for binary files).
---@param out string
---@return git.Change[]
function M.parse_changes(out)
  local changes, by_path, t, i = {}, {}, vim.split(out, '\0', { plain = true }), 1
  while t[i] and t[i]:match('^\n?:') do
    local mode_a, mode_b, blob, status = t[i]:match('^\n?:(%d+) (%d+) %x+ (%x+) (%a)')
    local path, oldpath
    if status == 'R' or status == 'C' then
      oldpath, path, i = t[i + 1], t[i + 2], i + 3
    else
      path, i = t[i + 1], i + 2
    end
    local c = { path = path, oldpath = oldpath, status = status, submodule = mode_a == '160000' or mode_b == '160000' }
    if not blob:match('^0+$') then c.blob = blob end
    by_path[path] = c
    table.insert(changes, c)
  end
  while t[i] and t[i] ~= '' do
    local added, removed, path = t[i]:match('^\n?([%d-]+)\t([%d-]+)\t(.*)$')
    if not added then break end
    if path == '' then path, i = t[i + 2], i + 3 else i = i + 1 end -- a rename: old\0new follow
    local c = by_path[path]
    if c then c.added, c.removed, c.binary = tonumber(added), tonumber(removed), added == '-' end
  end
  return changes
end

---The comparison's changed files, sorted by path. Runs git in the
---background (its few calls in parallel) and calls back on the main loop.
---@param cmp git.Comparison
---@param callback fun(changes: git.Change[]?, err: string?)
function M.changes(cmp, callback)
  local jobs = {
    diff = vim.list_extend(vim.list_extend({ 'diff', '-z', '-M', '--raw', '--numstat', '--no-ext-diff',
      '--ignore-submodules=dirty' }, diff_args(cmp)), vim.list_extend({ '--' }, cmp.paths)),
  }
  if cmp.right.rev == 'worktree' then
    jobs.untracked = vim.list_extend({ 'ls-files', '-z', '--others', '--exclude-standard', '--' }, cmp.paths)
  end

  local results, pending, failed = {}, vim.tbl_count(jobs), nil
  for name, args in pairs(jobs) do
    git.run_async(cmp.root, args, function(out, err)
      results[name], failed, pending = out, failed or err, pending - 1
      if pending > 0 then return end
      if failed then return callback(nil, failed) end
      local changes = M.parse_changes(results.diff)
      for _, path in ipairs(vim.split(results.untracked or '', '\0', { trimempty = true })) do
        table.insert(changes, { path = path, status = '?' })
      end
      table.sort(changes, function(x, y) return x.path < y.path end)
      callback(changes)
    end)
  end
end

---A view source for comparisons, one section each. `make` builds them, and
---runs again on every refresh, so names like HEAD follow commits made while
---the view is open (as `git diff` would).
---@param title string
---@param make fun(): git.Comparison[]
---@return git.Source
function M.source(title, make)
  local worktree = vim.iter(make()):any(function(cmp) return cmp.right.rev == 'worktree' end)
  return {
    title = title,
    worktree = worktree,
    fetch = function(callback)
      local ok, cmps = pcall(make)
      if not ok then return callback(nil, tostring(cmps)) end
      local sections, pending, failed = {}, #cmps, nil
      for i, cmp in ipairs(cmps) do
        M.changes(cmp, function(changes, err)
          sections[i] = { key = cmp.title, cmp = cmp, changes = changes or {} }
          failed, pending = failed or err, pending - 1
          if pending == 0 then callback(sections, failed) end
        end)
      end
    end,
  }
end

return M
