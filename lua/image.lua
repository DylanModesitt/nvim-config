-- image.lua: image files open as the image, in a terminal that can draw it
-- (Ghostty, kitty), and over SSH too. A PNG is drawn as it is; a JPEG, GIF or
-- WebP is converted to PNG first (sips on macOS, ImageMagick elsewhere).
-- Where it can't be drawn, the buffer says what the file is (:Open % opens it
-- in your system's viewer).
--
-- How (as snacks.nvim draws images): the file goes to the terminal once, by
-- the kitty graphics protocol. The buffer is then a grid of placeholder
-- characters, U+10EEEE with its row and column as combining marks and the
-- image's id as its color, and the terminal draws that piece of the image in
-- each one. Neovim only draws text, so splits, scrolling, tabs and closing
-- need nothing more; a resize draws a new grid to fit.

local api = vim.api

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
-- Row and column numbers 1, 2, 3, ...: the protocol's list of combining marks.
local MARKS = vim.tbl_map(function(hex) return vim.fn.nr2char(tonumber(hex, 16)) end, vim.split(
  '0305 030D 030E 0310 0312 033D 033E 033F 0346 034A 034B 034C 0350 0351 0352 0357 035B 0363 0364 ' ..
  '0365 0366 0367 0368 0369 036A 036B 036C 036D 036E 036F 0483 0484 0485 0486 0487 0592 0593 0594 ' ..
  '0595 0597 0598 0599 059C 059D 059E 059F 05A0 05A1 05A8 05A9 05AB 05AC 05AF 05C4 0610 0611 0612 ' ..
  '0613 0614 0615 0616 0617 0657 0658 0659 065A 065B 065D 065E 06D6 06D7 06D8 06D9 06DA 06DB 06DC ' ..
  '06DF 06E0 06E1 06E2 06E4 06E7 06E8 06EB 06EC 0730 0732 0733 0735 0736 073A 073D 073F 0740 0741 ' ..
  '0743 0745 0747 0749 074A 07EB 07EC 07ED 07EE 07EF 07F0 07F1 07F3 0816 0817 0818 0819 081B 081C ' ..
  '081D 081E 081F 0820 0821 0822 0823 0825 0826 0827 0829 082A 082B 082C 082D 0951 0953 0954 0F82 ' ..
  '0F83 0F86 0F87 135D 135E 135F 17DD 193A 1A17 1A75 1A76 1A77 1A78 1A79 1A7A 1A7B 1A7C 1B6B 1B6D ' ..
  '1B6E 1B6F 1B70 1B71 1B72 1B73 1CD0 1CD1 1CD2 1CDA 1CDB 1CE0 1DC0 1DC1 1DC3 1DC4 1DC5 1DC6 1DC7 ' ..
  '1DC8 1DC9 1DCB 1DCC 1DD1 1DD2 1DD3 1DD4 1DD5 1DD6 1DD7 1DD8 1DD9 1DDA 1DDB 1DDC 1DDD 1DDE 1DDF ' ..
  '1DE0 1DE1 1DE2 1DE3 1DE4 1DE5 1DE6 1DFE 20D0 20D1 20D4 20D5 20D6 20D7 20DB 20DC 20E1 20E7 20E9 ' ..
  '20F0 2CEF 2CF0 2CF1 2DE0 2DE1 2DE2 2DE3 2DE4 2DE5 2DE6 2DE7 2DE8 2DE9 2DEA 2DEB 2DEC 2DED 2DEE ' ..
  '2DEF 2DF0 2DF1 2DF2 2DF3 2DF4 2DF5 2DF6 2DF7 2DF8 2DF9 2DFA 2DFB 2DFC 2DFD 2DFE 2DFF A66F A67C ' ..
  'A67D A6F0 A6F1 A8E0 A8E1 A8E2 A8E3 A8E4 A8E5 A8E6 A8E7 A8E8 A8E9 A8EA A8EB A8EC A8ED A8EE A8EF ' ..
  'A8F0 A8F1 AAB0 AAB2 AAB3 AAB7 AAB8 AABE AABF AAC1 FE20 FE21 FE22 FE23 FE24 FE25 FE26 10A0F 10A38 ' ..
  '1D185 1D186 1D187 1D188 1D189 1D1AA 1D1AB 1D1AC 1D1AD 1D242 1D243 1D244',
  ' ', { trimempty = true }))

local CONVERTED = { jpg = true, jpeg = true, gif = true, webp = true }

---@class image.Image
---@field id integer its id in the terminal, which is also its placeholders' color
---@field file string the PNG the terminal draws
---@field width integer in pixels
---@field height integer
---@field drawn? string the grid last drawn, as 'cols rows left top'

local images = {} ---@type table<integer, image.Image> buf -> its image
local ns = api.nvim_create_namespace('image')
-- Ids from a range of this Neovim's own, so two in one terminal don't collide.
local last_id = bit.lshift(bit.band(vim.fn.getpid(), 0x3ff), 14)

---Whether the terminal can draw images. Ghostty's and kitty's can, and their
---TERM comes along over SSH; ids need 24-bit color.
local function drawable()
  return vim.o.termguicolors and (vim.env.TERM == 'xterm-ghostty' or vim.env.TERM == 'xterm-kitty')
end

---Send the terminal a graphics command, with its replies turned off.
---@param keys table<string, string|integer>
---@param data? string
local function send(keys, data)
  local parts = { 'q=2' }
  for k, v in pairs(keys) do table.insert(parts, k .. '=' .. v) end
  api.nvim_ui_send(('\027_G%s%s\027\\'):format(table.concat(parts, ','), data and (';' .. data) or ''))
end

---Send the image itself: its path, for the terminal to read, or over SSH its
---bytes, in pieces.
---@param img image.Image
local function transmit(img)
  if not (vim.env.SSH_TTY or vim.env.SSH_CONNECTION) then
    return send({ i = img.id, f = 100, t = 'f' }, vim.base64.encode(img.file))
  end
  local f = assert(io.open(img.file, 'rb'))
  local data = vim.base64.encode(f:read('*a'))
  f:close()
  for at = 1, #data, 4096 do
    local more = at + 4096 <= #data and 1 or 0
    send(at == 1 and { i = img.id, f = 100, m = more } or { m = more }, data:sub(at, at + 4095))
  end
end

---A PNG's size in pixels, from its header.
---@return integer? width, integer? height
local function png_size(file)
  local f = io.open(file, 'rb')
  local head = f and f:read(24) or ''
  if f then f:close() end
  if #head < 24 or head:sub(1, 8) ~= '\137PNG\r\n\026\n' then return end
  local function u32(at)
    local a, b, c, d = head:byte(at, at + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

---The PNG to draw for `path`: itself, or a converted copy (kept in the cache
---until the file changes).
---@return string?
local function png(path)
  local ext = vim.fn.fnamemodify(path, ':e'):lower()
  if not CONVERTED[ext] then return path end
  local stat = assert(vim.uv.fs_stat(path))
  local out = vim.fs.joinpath(vim.fn.stdpath('cache'), 'image', vim.fn.sha256(path .. stat.mtime.sec) .. '.png')
  if vim.uv.fs_stat(out) then return out end
  vim.fn.mkdir(vim.fs.dirname(out), 'p')
  local cmd = vim.fn.executable('sips') == 1 and { 'sips', '-s', 'format', 'png', path, '--out', out }
    or vim.fn.executable('magick') == 1 and { 'magick', path .. '[0]', out } -- ([0]: a GIF's first frame)
    or vim.fn.executable('convert') == 1 and { 'convert', path .. '[0]', out } -- (ImageMagick 6)
  if cmd and vim.system(cmd):wait().code == 0 then return out end
end

-- The terminal's cell size in pixels, which it tells the tty (over SSH too).
local has_ffi, ffi = pcall(require, 'ffi')
if has_ffi then
  pcall(ffi.cdef, 'typedef struct { unsigned short row, col, xpixel, ypixel; } image_winsize;'
    .. 'int ioctl(int, unsigned long, ...);')
end
local function cell()
  if has_ffi then
    local size = ffi.new('image_winsize') ---@type { row: integer, col: integer, xpixel: integer, ypixel: integer }
    local TIOCGWINSZ = vim.fn.has('mac') == 1 and 0x40087468 or 0x5413
    if ffi.C.ioctl(1, TIOCGWINSZ, size) == 0 and size.xpixel > 0 and size.col > 0 then
      return size.xpixel / size.col, size.ypixel / size.row
    end
  end
  return 8, 16 -- (a common one)
end

---Draw `buf`'s image to fit the windows showing it: at its own size, or
---smaller in proportion, centered.
local function render(buf)
  local img, wins = images[buf], vim.fn.win_findbuf(buf)
  if not img or #wins == 0 then return end
  local width, height = math.huge, math.huge
  for _, win in ipairs(wins) do
    width = math.min(width, api.nvim_win_get_width(win))
    height = math.min(height, api.nvim_win_get_height(win))
  end
  local cw, ch = cell()
  local cols, rows = img.width / cw, img.height / ch
  local scale = math.min(1, width / cols, height / rows, #MARKS / cols, #MARKS / rows)
  cols, rows = math.max(1, math.floor(cols * scale)), math.max(1, math.floor(rows * scale))
  local left, top = math.floor((width - cols) / 2), math.floor((height - rows) / 2)
  local drawn = ('%d %d %d %d'):format(cols, rows, left, top)
  if img.drawn == drawn then return end
  img.drawn = drawn

  send({ a = 'p', U = 1, i = img.id, p = 1, c = cols, r = rows, C = 1 }) -- (p=1: replaces the last one)
  local lines = {} ---@type string[]
  for _ = 1, top do table.insert(lines, '') end
  for r = 1, rows do
    local line = { (' '):rep(left) }
    for c = 1, cols do line[#line + 1] = PLACEHOLDER .. MARKS[r] .. MARKS[c] end
    table.insert(lines, table.concat(line))
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row = top, top + rows - 1 do
    api.nvim_buf_set_extmark(buf, ns, row, left, { end_col = #lines[row + 1], hl_group = 'Image' .. img.id })
  end
  for _, win in ipairs(wins) do
    api.nvim_win_call(win, function() vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, leftcol = 0 }) end)
  end
end

local function forget(buf)
  local img = images[buf]
  if not img then return end
  images[buf] = nil
  if drawable() then send({ a = 'd', d = 'I', i = img.id }) end -- (I: frees its data too)
end

---Read `buf`'s file as an image: send it to the terminal, or say why not.
local function read(buf)
  forget(buf)
  local path = api.nvim_buf_get_name(buf)
  local bo = vim.bo[buf]
  bo.buftype, bo.swapfile, bo.undolevels, bo.filetype = 'nofile', false, -1, 'image'
  local file = vim.uv.fs_stat(path) and png(path)
  local width, height ---@type integer?, integer?
  if file then width, height = png_size(file) end
  if file and width and height and drawable() then
    last_id = last_id + 1
    images[buf] = { id = last_id, file = file, width = width, height = height }
    api.nvim_set_hl(0, 'Image' .. last_id, { fg = last_id, nocombine = true })
    return transmit(images[buf]) -- (drawn once it's in a window: BufWinEnter)
  end
  local lines = { vim.fn.fnamemodify(path, ':~:.') }
  if width then table.insert(lines, ('%d × %d'):format(width, height)) end
  table.insert(lines, '')
  if not vim.uv.fs_stat(path) then
    table.insert(lines, 'No such file.')
  else
    table.insert(lines, width and "This terminal can't draw images (Ghostty and kitty can)."
      or "Couldn't read it as an image (formats other than PNG need sips or ImageMagick).")
    table.insert(lines, ":Open % opens it in your system's viewer.")
  end
  bo.modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  bo.modifiable, bo.modified = false, false
end

local group = api.nvim_create_augroup('image', {})

api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = { '*.png', '*.jpg', '*.jpeg', '*.gif', '*.webp' },
  callback = function(ev)
    if ev.match:find('^%a[%w+.-]*://') then return end -- (a git:// revision, a URL: not a file)
    read(ev.buf)
  end,
})

api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  callback = function(ev)
    if not images[ev.buf] then return end
    local wo = vim.wo[0][0]
    wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, 'no', '0', ''
    wo.list, wo.wrap, wo.cursorline, wo.cursorcolumn, wo.spell, wo.colorcolumn = false, false, false, false, false, ''
    images[ev.buf].drawn = nil
    render(ev.buf)
  end,
})

api.nvim_create_autocmd('WinResized', {
  group = group,
  callback = function()
    for _, win in ipairs(vim.v.event.windows) do
      if api.nvim_win_is_valid(win) then render(api.nvim_win_get_buf(win)) end
    end
  end,
})

api.nvim_create_autocmd('ColorScheme', { -- (a colorscheme clears every highlight group)
  group = group,
  callback = function()
    for _, img in pairs(images) do api.nvim_set_hl(0, 'Image' .. img.id, { fg = img.id, nocombine = true }) end
  end,
})

api.nvim_create_autocmd('BufUnload', { group = group, callback = function(ev) forget(ev.buf) end })

api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function() vim.iter(vim.tbl_keys(images)):each(forget) end,
})
