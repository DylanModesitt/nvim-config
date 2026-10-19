-- git/watch.lua: notice a repository changing while you look at it: files in
-- its working tree (an agent writing, creating, deleting), and its index,
-- HEAD and refs (staging, commits, checkouts). OS-level recursive watchers
-- (FSEvents on macOS): no polling, no cost while idle. Bursts of changes
-- become one callback, at most every 200ms.
--
-- Linux's inotify watches one directory, not the ones below it. There,
-- inotifywait (from inotify-tools, as Neovim's own LSP file watching uses)
-- watches the tree; without it, only the top directory is watched, and views
-- catch up when you come back to them.

local git = require('git')

local M = {}

-- Churn that never changes what git shows.
local noise = { '/__pycache__/', '/%.venv/', '/node_modules/', '/%.mypy_cache/', '/%.ruff_cache/',
  '/%.pytest_cache/', '/%.DS_Store$', '%.sw[po]$', '~$' }

---Whether a change to git's own directory matters: the index, HEAD, refs.
local function git_relevant(name)
  return name == 'index' or name == 'HEAD' or name == 'packed-refs' or vim.startswith(name, 'refs/')
end

-- What inotifywait never watches: git's objects and logs, and the noise above.
local skip = [[/(\.git/(objects|logs|lfs)|__pycache__|\.venv|node_modules|\.mypy_cache|\.ruff_cache|\.pytest_cache)(/|$)]]
local inotifywait = vim.fn.has('linux') == 1 and vim.fn.executable('inotifywait') == 1

local function worktree_relevant(name)
  local dotgit = name:match('^%.git/(.*)$') -- a plain repo's git directory is inside it
  if dotgit then return git_relevant(dotgit) end
  local path = '/' .. name
  for _, pattern in ipairs(noise) do
    if path:find(pattern) then return false end
  end
  return true
end

---Watch the repository at `root` (its working tree too, if `worktree`) and
---call `on_change` on the main loop after changes. Returns a function that
---stops watching.
---@param root string
---@param worktree boolean
---@param on_change fun()
---@return fun()
function M.start(root, worktree, on_change)
  local stops, timer = {}, assert(vim.uv.new_timer()) ---@type fun()[]
  local function changed()
    if not timer:is_active() then timer:start(200, 0, vim.schedule_wrap(on_change)) end
  end
  local function watch(dir, relevant)
    local function seen(name)
      if vim.startswith(name, dir .. '/') then name = name:sub(#dir + 2) end
      if relevant(name) then changed() end
    end
    if inotifywait then
      local partial = '' -- (output arrives in chunks, not always whole lines)
      local job = vim.fn.jobstart({ 'inotifywait', '--monitor', '--recursive', '--quiet', '--format', '%w%f',
        '--event', 'close_write,create,delete,move', '--exclude', skip, dir }, {
        on_stdout = function(_, lines)
          lines[1] = partial .. lines[1]
          partial = table.remove(lines)
          vim.iter(lines):each(seen)
        end,
      })
      if job > 0 then table.insert(stops, function() vim.fn.jobstop(job) end) end
      return
    end
    local w = assert(vim.uv.new_fs_event())
    local ok = w:start(dir, { recursive = true }, function(err, name)
      if not err and name then seen(name) end
    end)
    if ok then
      table.insert(stops, function()
        w:stop()
        w:close()
      end)
    else
      w:close()
    end
  end

  if worktree then watch(root, worktree_relevant) end
  -- A worktree's or submodule's git directory lives elsewhere; branches
  -- (refs) live in the repository's common directory.
  local out = git.run(root, { 'rev-parse', '--path-format=absolute', '--git-dir', '--git-common-dir' })
  local dirs = vim.split(vim.trim(out or ''), '\n', { trimempty = true })
  for _, dir in ipairs(vim.list.unique(dirs)) do
    if not (worktree and vim.startswith(dir, root .. '/')) then watch(dir, git_relevant) end
  end

  return function()
    for _, stop in ipairs(stops) do stop() end
    timer:stop()
    timer:close()
  end
end

return M
