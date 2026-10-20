-- Markdown: prose. Long lines wrap on screen, between words, and a wrapped
-- list item continues under its text (by Neovim's own markdown list pattern).
-- j/k move by screen line (init.lua).
--
-- Markup hides (**, backticks, a link's URL, code fences) except on the
-- cursor's line. Lines still wrap as if it were there, so a long link can
-- leave a short line after it.
local wo = vim.wo[0][0]
wo.wrap, wo.linebreak, wo.breakindentopt = true, true, 'list:-1'
wo.conceallevel = 2
