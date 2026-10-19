-- task.lua: tasks, for code that waits on commands (git, gh) without
-- freezing the editor. A task runs in a coroutine: task.system() inside one
-- yields until its command exits, letting the editor run meanwhile; outside
-- one, it simply waits. So the same code serves both.
--
-- A task's failure is reported as a message: task.fail('...') for one meant
-- for you, any other error with its traceback.

local M = {}

---Fail with a message for you (not a traceback).
---@param msg string
---@return any
function M.fail(msg) error({ msg = msg }, 0) end

---Run `fn` as a task. Failures are reported.
---@param fn fun()
function M.run(fn)
  coroutine.wrap(function()
    xpcall(fn, function(e)
      vim.notify(type(e) == 'table' and e.msg or debug.traceback(tostring(e)), vim.log.levels.ERROR)
    end)
  end)()
end

---Run a command (as vim.system) and wait for it.
---@param cmd string[]
---@param opts? vim.SystemOpts
---@return vim.SystemCompleted
function M.system(cmd, opts)
  local co = coroutine.running()
  if not co then return vim.system(cmd, opts):wait() end
  vim.system(cmd, opts, function(r) vim.schedule(function() coroutine.resume(co, r) end) end)
  return coroutine.yield()
end

return M
