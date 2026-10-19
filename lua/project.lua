-- project.lua: a project's own tools. A project pins the versions of its
-- tools (Python's in .venv/bin, JavaScript's in node_modules/.bin), and each
-- worktree can pin different ones: a language server for a file is the one
-- its project pins, else the one installed globally (on $PATH).

local M = {}

---The project's own `name`: in `dir` (say, '.venv/bin') of `root` or of a
---directory above it (a workspace can keep its tools at its top).
---@param root string
---@param dir string
---@param name string
---@return string?
function M.bin(root, dir, name)
  for _, d in ipairs(vim.list_extend({ root }, vim.iter(vim.fs.parents(root)):totable())) do
    local bin = vim.fs.joinpath(d, dir, name)
    if vim.fn.executable(bin) == 1 then return bin end
  end
end

---An LSP `cmd` running `bin(root)` with `args`, in the project's root.
---Resolved per client, so each worktree runs the version it pins.
---@param bin fun(root: string?): string
---@param args string[]
function M.lsp_cmd(bin, args)
  return function(dispatchers, config)
    return vim.lsp.rpc.start(vim.list_extend({ bin(config.root_dir) }, args), dispatchers, { cwd = config.root_dir })
  end
end

---An LSP `cmd` running the project's `name` (from `dir`), else $PATH's.
---@param dir string
---@param name string
---@param args string[]
function M.tool(dir, name, args)
  return M.lsp_cmd(function(root) return root and M.bin(root, dir, name) or name end, args)
end

return M
