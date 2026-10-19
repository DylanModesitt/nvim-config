-- oxfmt: formatting (<leader>=) for JavaScript, TypeScript and their
-- neighbours, in projects that use it (an .oxfmtrc.json). The project's own
-- oxfmt; where it's attached, it formats instead of the TypeScript server.
return {
  cmd = require('project').tool('node_modules/.bin', 'oxfmt', { '--lsp' }),
  filetypes = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact', 'json', 'jsonc', 'css', 'markdown' },
  root_markers = { '.oxfmtrc.json', '.oxfmtrc.jsonc' },
  workspace_required = true,
}
