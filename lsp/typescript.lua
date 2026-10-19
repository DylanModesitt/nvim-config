-- typescript: TypeScript's own language server (TypeScript 7, native and
-- fast), for TypeScript and JavaScript: types, completion with auto-imports,
-- navigation, renames, fixes. The project's, if it pins one (typescript 7 or
-- later, or the @typescript/native-preview its checks run), else the global
-- one (brew install typescript).
local project = require('project')

---The project's native TypeScript, if it has one.
local function pinned(root)
  local preview = project.bin(root, 'node_modules/.bin', 'tsgo')
  if preview then return preview end
  local tsc = project.bin(root, 'node_modules/.bin', 'tsc')
  if not tsc then return end
  local package = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(tsc)), 'typescript', 'package.json')
  local ok, info = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(package), '\n')) end)
  local major = ok and tonumber(tostring(info.version):match('^(%d+)'))
  if major and major >= 7 then return tsc end -- (6 and earlier have no language server of their own)
end

return {
  cmd = project.lsp_cmd(function(root) return root and pinned(root) or 'tsc' end, { '--lsp', '--stdio' }),
  filetypes = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact' },
  root_markers = { 'tsconfig.json', 'jsconfig.json', 'package.json', '.git' },
}
