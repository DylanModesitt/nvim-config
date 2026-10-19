-- scripts/ghostty-theme.lua: a Ghostty theme from a Neovim colorscheme: its
-- 16 terminal colors, background, foreground, cursor and selection. Run it
-- with the scheme loaded; it writes the theme to stdout:
--
--   nvim --headless --clean -c 'colorscheme torte' -c 'luafile scripts/ghostty-theme.lua' -c 'qa!' \
--     > ~/.config/ghostty/themes/torte
--
-- then `theme = torte` in ~/.config/ghostty/config. (Schemes without terminal
-- colors of their own, like vim and default, use the terminal's.)

local function hex(group, key)
  local value = vim.api.nvim_get_hl(0, { name = group, link = false })[key]
  return value and ('#%06x'):format(value)
end

local lines = {}
for i = 0, 15 do
  local color = vim.g['terminal_color_' .. i]
  if color then table.insert(lines, ('palette = %d=%s'):format(i, color)) end
end
for key, value in vim.spairs({
  ['background'] = hex('Normal', 'bg'),
  ['foreground'] = hex('Normal', 'fg'),
  ['cursor-color'] = hex('Cursor', 'bg'),
  ['cursor-text'] = hex('Cursor', 'fg'),
  ['selection-background'] = hex('Visual', 'bg'),
  ['selection-foreground'] = hex('Visual', 'fg'),
}) do
  table.insert(lines, ('%s = %s'):format(key, value))
end
io.write(table.concat(lines, '\n') .. '\n')
