-- ruff: Python lint diagnostics, fixes (gra), formatting (<leader>=).
return {
  cmd = require('project').tool('.venv/bin', 'ruff', { 'server' }),
  filetypes = { 'python' },
  root_markers = { '.venv', 'ruff.toml', 'pyproject.toml', '.git' },
  on_attach = function(client)
    client.server_capabilities.hoverProvider = false -- ty's hover is the useful one
  end,
}
