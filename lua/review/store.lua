-- review/store.lua: review comments and "viewed" marks, kept per repository
-- in one JSON file each (under stdpath('state')/review), so they survive
-- restarts and stay out of the repository itself. Code that changes a store
-- gets it (M.get) at the time, rather than keeping one: another Neovim may
-- have changed it meanwhile.

local M = {}

---@class review.Comment
---@field id string
---@field path string relative to the repository root
---@field rev string the commented content: 'worktree', ':0' (index) or a commit sha
---@field side 'left'|'right' the side of a diff it was written on (right outside one)
---@field line integer first line commented on
---@field end_line integer last line
---@field code string[] those lines as they were, to find them again if they move
---@field body string markdown
---@field created integer
---@field outdated? boolean its code is gone from the file
---@field thread? string a reply: to this thread (review.Thread's id)

---@class review.Store
---@field root string
---@field comments review.Comment[]
---@field viewed table<string, string> '<rev>:<path>' -> a token for the content viewed

local stores = {} ---@type table<string, review.Store>
local read_at = {} ---@type table<string, string> root -> its file's mtime when last read or written

local function file(root)
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'review', vim.fn.sha256(root):sub(1, 16) .. '.json')
end

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and ('%d.%d'):format(stat.mtime.sec, stat.mtime.nsec) or ''
end

---The store for the repository at `root`: kept, and read again if another
---Neovim changed its file since.
---@return review.Store
function M.get(root)
  local path = file(root)
  if not stores[root] or read_at[root] ~= mtime(path) then
    local f = io.open(path)
    local ok, data = pcall(vim.json.decode, f and f:read('*a') or '{}')
    if f then f:close() end
    data = ok and type(data) == 'table' and data or {}
    stores[root] = { root = root, comments = data.comments or {}, viewed = data.viewed or {} }
    read_at[root] = mtime(path)
  end
  return stores[root]
end

---@param store review.Store
function M.save(store)
  local path = file(store.root)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  -- vim.empty_dict(): an empty map must stay an object in JSON, not become [].
  local viewed = next(store.viewed) and store.viewed or vim.empty_dict()
  -- Written whole to a temporary file, then renamed over the old one: never
  -- half-written.
  local tmp = path .. '.tmp'
  local f = assert(io.open(tmp, 'w'))
  f:write(vim.json.encode({ root = store.root, comments = store.comments, viewed = viewed }))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
  read_at[store.root] = mtime(path)
end

---Find comment `id` in the store (as it is now: see M.get).
---@return review.Comment?
function M.find(store, id)
  return vim.iter(store.comments):find(function(c) return c.id == id end)
end

---Comments on `path` at `rev`.
---@return review.Comment[]
function M.on(store, path, rev)
  return vim.tbl_filter(function(c) return c.path == path and c.rev == rev end, store.comments)
end

function M.new_id() return ('%x%04x'):format(os.time(), math.random(0, 0xffff)) end

return M
