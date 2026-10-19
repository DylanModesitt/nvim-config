-- git/checkouts.lua: where a repository is checked out, and what each
-- checkout has checked out. Its worktrees and, for a submodule, the same
-- submodule in each worktree of its superproject; what's checked out is read
-- from their files, which is quick even for dozens of them.

local git = require('git')

local M = {}

local function first_line(file)
  local f = io.open(file)
  if not f then return end
  local line = f:read('*l')
  f:close()
  return line
end

---What checkout `dir` has checked out: a branch, or (detached) a commit.
---@param dir string
---@return { branch: string?, sha: string? }?
function M.head(dir)
  local dotgit = vim.fs.joinpath(dir, '.git')
  local stat = vim.uv.fs_stat(dotgit)
  if not stat then return end
  local gitdir = dotgit
  if stat.type == 'file' then -- a worktree's, or a submodule's: points to its git dir
    local to = (first_line(dotgit) or ''):match('^gitdir: (.+)$')
    if not to then return end
    gitdir = vim.fs.normalize(to:sub(1, 1) == '/' and to or vim.fs.joinpath(dir, to))
  end
  local head = first_line(vim.fs.joinpath(gitdir, 'HEAD')) or ''
  local branch = head:match('^ref: refs/heads/(.+)$')
  return { branch = branch, sha = not branch and head:match('^%x+$') or nil }
end

---The superproject's checkout, if `root` is a submodule's.
---@param root string
---@return string?
function M.superproject(root)
  local out = vim.trim(git.run(root, { 'rev-parse', '--show-superproject-working-tree' }) or '')
  return out ~= '' and out or nil
end

local function worktrees(root)
  local paths = {}
  for p in (git.run(root, { 'worktree', 'list', '--porcelain' }) or ''):gmatch('worktree ([^\n]+)') do
    table.insert(paths, p)
  end
  return paths
end

---Every checkout of the repository at `root` (it first): its worktrees and,
---for a submodule, the same submodule in each worktree of its superproject.
---@param root string
---@return string[]
function M.all(root)
  local paths = vim.list_extend({ root }, worktrees(root))
  local super = M.superproject(root)
  if super then
    for _, wt in ipairs(worktrees(super)) do table.insert(paths, vim.fs.joinpath(wt, root:sub(#super + 2))) end
  end
  return vim.list.unique(paths)
end

---The checkouts near `root`: it, its superproject, and the submodules of
---either (each a repository of its own).
---@param root string
---@return string[]
function M.near(root)
  local top = M.superproject(root) or root
  local dirs = { root, top }
  local out = git.run(top, { 'config', '-f', '.gitmodules', '--get-regexp', [[^submodule\..*\.path$]] }) or ''
  for path in out:gmatch('%S+ ([^\n]+)') do table.insert(dirs, vim.fs.joinpath(top, path)) end
  return vim.tbl_filter(function(d) return vim.uv.fs_stat(vim.fs.joinpath(d, '.git')) ~= nil end, vim.list.unique(dirs))
end

return M
