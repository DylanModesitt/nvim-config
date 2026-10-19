-- oxlint: lint diagnostics and fixes (gra) for JavaScript and TypeScript, in
-- projects that use it (an .oxlintrc.json). The project's own oxlint.
return {
  cmd = require('project').tool('node_modules/.bin', 'oxlint', { '--lsp' }),
  filetypes = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact' },
  root_markers = { '.oxlintrc.json' },
  workspace_required = true,
}
