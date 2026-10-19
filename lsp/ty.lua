-- ty: Astral's Python type checker. Types, hover, completion, navigation.
-- The project's own ty.toml/pyproject.toml governs strictness. The root is
-- the nearest directory with a .venv, so each worktree runs its pinned ty
-- against its own environment.
return {
  cmd = require('project').tool('.venv/bin', 'ty', { 'server' }),
  filetypes = { 'python' },
  root_markers = { '.venv', 'ty.toml', 'pyproject.toml', '.git' },
}
