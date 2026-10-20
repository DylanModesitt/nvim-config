-- Plain text: prose. Long lines wrap on screen, between words. j/k move by
-- screen line (init.lua).
local wo = vim.wo[0][0]
wo.wrap, wo.linebreak = true, true
