-- Python: comments and docstrings wrap at 79 (gq, and comments as you type).
-- Code width is the formatter's business (ruff's line-length).
vim.bo.textwidth = 79
vim.bo.formatoptions = 'cqjnl' -- wrap comments, never code, while typing

-- List items aren't merged into their neighbours, and wrap with a hanging
-- indent: under the text for `1.`, `-`, `*`; four spaces in for docstring
-- entries like `name (type): text` (Google style). The pattern matches what
-- becomes the continuation indent.
vim.bo.formatlistpat = [[^\s*\%(\d\+[.)]\|[-*+]\)\s\+\|^\s*\%(\S\+\%( ([^)]*)\)\?:\s\)\@=.\{4}]]
