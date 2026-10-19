-- git/signs.lua: changes in the gutter, hunk actions, blame (gitsigns.nvim).
--
--   ]c [c        next/previous hunk (in diff mode: the native change motions)
--   <leader>hs   stage hunk, or the selected lines (again to unstage)
--   <leader>hr   reset hunk, or the selected lines
--   <leader>hp   preview the hunk inline
--   <leader>hb   blame this line (full commit message)
--   <leader>hB   blame the whole file, side by side
--   <leader>hq   every hunk in the repo, in the quickfix list
--   <leader>tb   toggle blame at the end of the current line
--   ih           hunk text object (dih, yih, vih)

vim.pack.add({ { src = 'https://github.com/lewis6991/gitsigns.nvim', version = vim.version.range('2') } })

local gitsigns = require('gitsigns')

gitsigns.setup({
  current_line_blame_formatter = '<author>, <author_time:%R> · <summary>',
  on_attach = function(buf)
    local function map(mode, lhs, rhs, desc) vim.keymap.set(mode, lhs, rhs, { buf = buf, desc = desc }) end
    local function lines() return { vim.fn.line('.'), vim.fn.line('v') } end

    map('n', ']c', function()
      if vim.wo.diff then return vim.cmd.normal({ vim.v.count1 .. ']c', bang = true }) end
      gitsigns.nav_hunk('next') -- (counts: v:count1)
    end, 'Next hunk')
    map('n', '[c', function()
      if vim.wo.diff then return vim.cmd.normal({ vim.v.count1 .. '[c', bang = true }) end
      gitsigns.nav_hunk('prev')
    end, 'Previous hunk')

    map('n', '<leader>hs', gitsigns.stage_hunk, 'Stage hunk')
    map('x', '<leader>hs', function() gitsigns.stage_hunk(lines()) end, 'Stage lines')
    map('n', '<leader>hr', gitsigns.reset_hunk, 'Reset hunk')
    map('x', '<leader>hr', function() gitsigns.reset_hunk(lines()) end, 'Reset lines')
    map('n', '<leader>hp', gitsigns.preview_hunk_inline, 'Preview hunk')
    map('n', '<leader>hb', function() gitsigns.blame_line({ full = true }) end, 'Blame line')
    map('n', '<leader>hB', gitsigns.blame, 'Blame file')
    map('n', '<leader>hq', function() gitsigns.setqflist('all') end, 'All hunks to quickfix')
    map('n', '<leader>tb', gitsigns.toggle_current_line_blame, 'Toggle line blame')
    map({ 'o', 'x' }, 'ih', gitsigns.select_hunk, 'Hunk')
  end,
})
