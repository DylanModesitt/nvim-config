-- git/log.lua: history, as a view's sections: one per commit (newest first),
-- holding the files it changed against its first parent. One `git log` call
-- lists the commits and their files together.

local compare = require('git.compare')
local git = require('git')

local M = {}

---@class git.Commit
---@field sha string
---@field short string
---@field author string
---@field date string relative: '3 days ago'
---@field subject string

---`:Log` arguments: anything git log takes; paths after --, or a bare %.
---@return string[] args, string[] paths
function M.parse(args)
  local flags, paths = {}, {}
  for i, a in ipairs(args) do
    if a == '--' then
      vim.list_extend(paths, vim.tbl_map(compare.pathspec, vim.list_slice(args, i + 1)))
      break
    end
    table.insert(a == '%' and paths or flags, a == '%' and compare.pathspec(a) or a)
  end
  return flags, paths
end

---The commits `git log <args> -- <paths>` shows, as sections (the latest 300).
---@param root string
---@param args string[]
---@param paths string[]
---@param callback fun(sections: git.Section[]?, err: string?)
function M.fetch(root, args, paths, callback)
  local cmd = { 'log', '-z', '--format=%x1e%H%x1f%P%x1f%h%x1f%an%x1f%ar%x1f%s', '--raw', '--numstat', '-M',
    '--diff-merges=first-parent', '-n', '300' }
  -- One file's history follows it through renames.
  local stat = #paths == 1 and vim.uv.fs_stat(paths[1])
  if stat and stat.type == 'file' then table.insert(cmd, '--follow') end
  vim.list_extend(cmd, args)
  vim.list_extend(vim.list_extend(cmd, { '--' }), paths)

  git.run_async(root, cmd, function(out, err)
    if not out then return callback(nil, err) end
    local sections = {}
    for record in vim.gsplit(out, '\30', { plain = true }) do
      local nul = record:find('\0', 1, true)
      if nul then
        local f = vim.split(record:sub(1, nul - 1), '\31', { plain = true })
        local sha, parent = f[1], vim.split(f[2], ' ')[1]
        local commit = { sha = sha, short = f[3], author = f[4], date = f[5], subject = f[6] } ---@type git.Commit
        local left = { rev = parent ~= '' and parent or compare.EMPTY_TREE, label = commit.short .. '^' }
        local cmp = compare.new(root, left, { rev = sha, label = commit.short }, commit.subject, paths)
        local changes = compare.parse_changes(record:sub(nul + 1))
        table.insert(sections, { key = sha, cmp = cmp, changes = changes, commit = commit })
      end
    end
    callback(sections)
  end)
end

---A view source for `:Log <args>`. A file's history lists every commit open;
---a whole history, only the newest.
---@return git.Source
function M.source(root, args, paths)
  local names = vim.tbl_map(function(p) return vim.fn.fnamemodify(p, ':~:.') end, paths)
  return {
    title = table.concat(vim.list_extend(vim.list_extend({ 'Log' }, args), names), ' '),
    worktree = false,
    collapse = #paths == 0,
    fetch = function(callback) M.fetch(root, args, paths, callback) end,
  }
end

return M
