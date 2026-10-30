-- rewrite.lua: rewrite text by saying how. Select it, <leader>K, and write
-- what you want in the float ("a list, not a table"). Claude Code, run
-- headless with no tools (`claude -p`), writes the new text, and it takes the
-- selection's place as one change: u undoes it, gv selects it again to go on.
-- Ask a question about the text instead ("what does this do?") and the answer
-- opens in a float, the text left as it is.
--
--   <leader>K    rewrite the selection (in normal mode: this line). In the
--                float: Enter sends it, Ctrl-j starts a new line, ZQ closes
--
-- While it's being rewritten the text is dimmed. Change it meanwhile (u, say)
-- and it's left as you made it. Sonnet writes; to change that, set
-- require('rewrite').model (an alias, 'opus', or a model's full name).

local M = {}

M.model = 'sonnet'

local ns = vim.api.nvim_create_namespace('rewrite')
local context = 200 -- lines of the file sent from each side of the selection

local system = [[
You are part of a text editor. The user selected text in a file and wrote an instruction about it.
Your reply takes the selection's place in the file.

- Reply with the new text between <replacement> and </replacement>, exactly as it should appear in
  the file, and nothing outside them. Match the file: its indentation, line width, language and
  style. No code fences unless the text itself has them.
- If the instruction is a question about the text rather than a change, or you can't do it, answer
  briefly in plain text, without the tags. The user reads your answer, and the file stays as it is.

The file around the selection is given for context, with the selection marked
<selection>...</selection>. Change only the selection.]]

local function path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':~:.')
end

---' path L3-15 ', a float's title, for rows `from`..`to` (0-based) of `buf`.
local function where(buf, from, to)
  return from == to and (' %s L%d '):format(path(buf), from + 1) or (' %s L%d-%d '):format(path(buf), from + 1, to + 1)
end

---The message: the file around the text from..to, with it marked, then the
---instruction.
local function prompt(buf, from, to, instruction)
  local first = math.max(0, from[1] - context)
  local lines = vim.api.nvim_buf_get_lines(buf, first, to[1] + context + 1, false)
  local function mark(pos, tag)
    local i = pos[1] - first + 1
    lines[i] = lines[i]:sub(1, pos[2]) .. tag .. lines[i]:sub(pos[2] + 1)
  end
  mark(to, '</selection>') -- (first: on the same line, it comes after)
  mark(from, '<selection>')
  return ('<file path="%s" language="%s">\n%s\n</file>\n\n<instruction>\n%s\n</instruction>'):format(
    path(buf),
    vim.bo[buf].filetype,
    table.concat(lines, '\n'),
    instruction
  )
end

---Show a reply that isn't a rewrite (an answer, or why not), in a float.
local function answer(title, text)
  local buf = require('review.compose').float({
    name = ('rewrite://answer/%d'):format(vim.uv.hrtime()),
    title = title,
    footer = ' q close ',
    text = vim.split(vim.trim(text), '\n'),
  })
  if not buf then return end
  vim.bo[buf].modifiable = false
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buf = buf, desc = 'Close' })
end

---Put the new text in place of the old, if the old is still there (where
---extmark `id` has followed it), as one change; and select it for gv.
local function apply(buf, id, old, new)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
  vim.api.nvim_buf_del_extmark(buf, ns, id)
  local row, col, d = pos[1], pos[2], pos[3] or {}
  -- (An error if it was deleted: the mark is gone, or its end is before its start.)
  local ok, now = pcall(vim.api.nvim_buf_get_text, buf, row, col, d.end_row, d.end_col, {})
  if not ok or not vim.deep_equal(now, old) then
    return vim.notify('Left as it is: the text changed while it was being rewritten', vim.log.levels.WARN)
  end
  new = new:gsub('\n+$', '')
  if #old > 1 and old[#old] == '' then new = new .. '\n' end -- it ended with a line break: so does this
  local lines = vim.split(new, '\n')
  vim.api.nvim_buf_set_text(buf, row, col, d.end_row, d.end_col, lines)

  local last = row + #lines - 1
  local stop = (#lines == 1 and col or 0) + #lines[#lines] -- (where it ends, exclusive)
  vim.hl.range(buf, ns, 'IncSearch', { row, col }, { last, stop }, { timeout = 300 })
  if new == '' then return end
  vim.api.nvim_buf_set_mark(buf, '<', row + 1, col, {})
  if stop == 0 then -- it ends with a line break: select through it
    vim.api.nvim_buf_set_mark(buf, '>', last, #vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1], {})
  else -- on the last character's first byte
    local line = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
    vim.api.nvim_buf_set_mark(buf, '>', last + 1, stop - 1 + vim.str_utf_start(line, stop), {})
  end
end

---Rewrite the text from..to of `buf` ((row, col), 0-based, the end
---exclusive) as `instruction` says.
local function rewrite(buf, from, to, instruction)
  local old = vim.api.nvim_buf_get_text(buf, from[1], from[2], to[1], to[2], {})
  local title = where(buf, from[1], to[1])
  local id = vim.api.nvim_buf_set_extmark(buf, ns, from[1], from[2], {
    end_row = to[1],
    end_col = to[2],
    hl_group = 'Comment',
    virt_text = { { ' rewriting…', 'Comment' } },
  })
  local cmd = {
    'claude', '-p', '--model', M.model, '--system-prompt', system, '--output-format', 'json',
    -- Just the text: no tools, settings, hooks, MCP servers or saved session.
    '--tools', '', '--setting-sources', '', '--strict-mcp-config', '--disable-slash-commands',
    '--no-session-persistence',
  }
  local opts = { stdin = prompt(buf, from, to, instruction), text = true, timeout = 300000 }
  vim.system(cmd, opts, vim.schedule_wrap(function(r)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local ok, out = pcall(vim.json.decode, r.stdout)
    local reply = ok and type(out) == 'table' and out.result
    if r.code ~= 0 or type(reply) ~= 'string' or out.is_error then
      vim.api.nvim_buf_del_extmark(buf, ns, id)
      local why = vim.trim(type(reply) == 'string' and reply or r.stderr or '')
      if why == '' then why = r.code == 124 and 'it took too long' or ('exit %d'):format(r.code) end
      return vim.notify(('Rewrite failed: %s'):format(why), vim.log.levels.ERROR)
    end
    local new = reply:match('<replacement>\n?(.*)</replacement>')
    if new then return apply(buf, id, old, new) end
    vim.api.nvim_buf_del_extmark(buf, ns, id)
    answer(title, reply)
  end))
end

---<leader>K: ask for a rewrite of the selection, or in normal mode of this
---line.
function M.here()
  if vim.fn.executable('claude') == 0 then
    return vim.notify('Rewriting needs Claude Code (claude) on the PATH', vim.log.levels.WARN)
  end
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local from, to
  if mode == 'v' then
    local a, b = vim.fn.getpos('v'), vim.fn.getpos('.')
    if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then a, b = b, a end
    local line = vim.fn.getline(b[2])
    from = { a[2] - 1, a[3] - 1 }
    if b[3] <= #line then
      to = { b[2] - 1, b[3] + vim.str_utf_end(line, b[3]) }
    elseif b[2] < vim.fn.line('$') then -- through the line break
      to = { b[2], 0 }
    else
      to = { b[2] - 1, #line }
    end
  else -- lines (a block's too)
    local a, b = vim.fn.line('v'), vim.fn.line('.')
    a, b = math.min(a, b), math.max(a, b)
    from, to = { a - 1, 0 }, { b - 1, #vim.fn.getline(b) }
  end
  if mode:match('[vV\22]') then vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false) end

  local fbuf, win, parts = require('review.compose').float({
    name = ('rewrite://%d/%d:%d'):format(buf, from[1], from[2]),
    title = where(buf, from[1], to[1]),
    footer = ' Enter rewrite · ZQ close ',
    text = {},
  })
  if not fbuf then return end
  ---@cast win integer
  local function send(lines)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    local instruction = vim.trim(table.concat(lines, '\n'))
    if instruction ~= '' then rewrite(buf, from, to, instruction) end
  end
  vim.keymap.set({ 'n', 'i' }, '<CR>', function()
    vim.cmd.stopinsert()
    send(select(2, parts()))
  end, { buf = fbuf, desc = 'Rewrite' })
  -- ZZ and :w send it too. (After :w's write; ZZ closes the window first.)
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buf = fbuf,
    callback = function()
      vim.bo[fbuf].modified = false
      local _, lines = parts()
      vim.schedule(function() send(lines) end)
    end,
  })
  vim.cmd.startinsert()
end

vim.keymap.set({ 'n', 'x' }, '<leader>K', M.here, { desc = 'Rewrite' })

return M
