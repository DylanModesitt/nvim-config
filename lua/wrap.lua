-- wrap.lua: gq rewraps prose and leaves code alone.
--
-- With a language server attached, Neovim would point gq at the server's
-- range formatter (unless 'formatexpr' is set, as here), which reformats code
-- but never rewraps a long comment. Vim's own gw rewraps, but `gwip` on a
-- comment with code right below it pulls the code in. Here gq rewraps just
-- the comment blocks and docstrings inside its
-- range, at 'textwidth', using Vim's own formatter (which understands comment
-- leaders, and list items via 'formatlistpat'). So `gqip` or `gqG` only touch
-- the prose in their range, and `gqq` on a comment or docstring line refills
-- that paragraph (Emacs's M-q). A range with no prose in it goes to the
-- language server as before.

local M = {}

---'comment' or 'docstring' if the line is prose, judged by the treesitter
---captures at its first character. Blank and quote-only lines are not: they
---separate paragraphs.
local function prose(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local col = line:find('%S')
  if not col or line:match('^%s*"""%s*$') or line:match("^%s*'''%s*$") then return end
  for _, cap in ipairs(vim.treesitter.get_captures_at_pos(buf, row, col - 1)) do
    if cap.capture == 'string.documentation' then return 'docstring' end
    if cap.capture == 'comment' or vim.startswith(cap.capture, 'comment.') then return 'comment' end
  end
end

---Runs of consecutive prose lines of one kind (and, for comments, one indent)
---within [first, last], 1-based.
local function prose_runs(buf, first, last)
  local runs, run = {}, nil
  for lnum = first, last do
    local kind = prose(buf, lnum - 1)
    local indent = vim.fn.indent(lnum)
    if kind and run and run.kind == kind and (kind == 'docstring' or run.indent == indent) then
      run.last = lnum
    else
      run = kind and { kind = kind, indent = indent, first = lnum, last = lnum } or nil
      if run then table.insert(runs, run) end
    end
  end
  return runs
end

---'formatexpr'.
function M.formatexpr()
  -- Auto-wrap while typing past 'textwidth': Vim's formatter handles that.
  if vim.fn.mode():match('^[iR]') then return 1 end

  local buf = vim.api.nvim_get_current_buf()
  local first, last = vim.v.lnum, vim.v.lnum + vim.v.count - 1
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then return 1 end -- no syntax tree: plain text, format it all
  parser:parse()

  -- gqq (one line) on prose refills its whole paragraph, like Emacs's M-q.
  local kind = vim.v.count == 1 and prose(buf, first - 1)
  if kind then
    local indent = vim.fn.indent(first)
    local function same(lnum)
      return prose(buf, lnum - 1) == kind and (kind == 'docstring' or vim.fn.indent(lnum) == indent)
    end
    while first > 1 and same(first - 1) do first = first - 1 end
    while last < vim.api.nvim_buf_line_count(buf) and same(last + 1) do last = last + 1 end
  end

  local runs = prose_runs(buf, first, last)
  if #runs == 0 then
    local lsp = #vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/rangeFormatting' }) > 0
    return lsp and vim.lsp.formatexpr() or 1
  end

  -- Bottom-up, so formatting a run doesn't shift the ones still to do. An
  -- extmark keeps the cursor on its text as line numbers change.
  local ns = vim.api.nvim_create_namespace('wrap')
  local cursor = vim.api.nvim_win_get_cursor(0)
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, cursor[1] - 1, cursor[2], {})
  for i = #runs, 1, -1 do
    vim.cmd(('keepjumps normal! %dGgw%dG'):format(runs[i].first, runs[i].last))
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
  vim.api.nvim_buf_del_extmark(buf, ns, mark)
  pcall(vim.api.nvim_win_set_cursor, 0, { pos[1] + 1, pos[2] })
  return 0
end

-- (A language server attaching leaves it be: Neovim only replaces an unset
-- or default 'formatexpr'.)
vim.o.formatexpr = "v:lua.require'wrap'.formatexpr()"

return M
