-- git/object.lua: a file at a revision, as a read-only buffer named
--
--   git://<root>//<rev>/<path>
--
-- where rev is a commit sha, :0 (the index), 'none' (the file doesn't exist
-- on that side: an empty buffer), or 'worktree' (only for a submodule, shown
-- as the commit it's at). The path picks the syntax highlighting. These
-- aren't real files, so no LSP attaches and they're never saved.

local git = require('git')

local M = {}

---@param root string
---@param rev string
---@param path string
function M.name(root, rev, path) return ('git://%s//%s/%s'):format(root, rev, path) end

---@return { root: string, rev: string, path: string }?
function M.parse(name)
  local root, rev, path = name:match('^git://(.-)//([^/]+)/(.+)$')
  if root then return { root = root, rev = rev, path = path } end
end

---@return string[]
local function read(obj)
  if obj.rev == 'none' then return {} end
  if obj.rev == 'worktree' then -- a submodule
    local sha = git.run(vim.fs.joinpath(obj.root, obj.path), { 'rev-parse', 'HEAD' })
    return { 'Subproject commit ' .. vim.trim(sha or '?') }
  end
  local spec = (obj.rev == ':0' and ':0:' or obj.rev .. ':') .. obj.path
  local out = git.run(obj.root, { 'cat-file', '-p', spec })
  if not out then -- absent on this side, or a submodule (a commit, not a file)
    local sha = git.run(obj.root, { 'rev-parse', '--verify', '--quiet', spec })
    return sha and { 'Subproject commit ' .. vim.trim(sha) } or {}
  end
  if out:find('\0', 1, true) then return { '(binary file)' } end
  local lines = vim.split(out, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

local function fill(buf, lines)
  local bo = vim.bo[buf]
  bo.modifiable, bo.readonly = true, false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  bo.modified, bo.modifiable, bo.readonly = false, false, true
end

---Fill `buf` with the file its git:// name points to (BufReadCmd).
function M.load(buf, name)
  local obj = M.parse(name)
  if not obj then return end
  fill(buf, read(obj))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nowrite', 'wipe', false
  vim.bo[buf].filetype = vim.filetype.match({ filename = obj.path, buf = buf }) or ''
end

---Re-read a git:// buffer in place: the same buffer, so the windows showing
---it keep their diff, folds and cursors (:edit! would reload it from
---scratch). Returns whether its text changed.
---@param buf integer
---@return boolean
function M.reload(buf)
  local obj = M.parse(vim.api.nvim_buf_get_name(buf))
  if not obj then return false end
  local lines = read(obj)
  if vim.deep_equal(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then return false end
  fill(buf, lines)
  return true
end

return M
