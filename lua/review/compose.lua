-- review/compose.lua: writing comments, in a small floating markdown buffer
-- at the code they're about: a new one, one to edit, or a reply to a thread
-- (its conversation above a rule, your reply below it).
--
--   ZZ   save it and close (:w saves and keeps it open)
--   ZQ   close, throwing away this edit
--   ZD   delete the comment (or your reply)
--   ZC   in a thread: resolve it (close the conversation), or reopen it

local marks = require('review.marks')
local store = require('review.store')

local M = {}

local ns = vim.api.nvim_create_namespace('review.compose')

---Comments changed: show them again, and tell anything else that shows them
---(a diff view's counts: git/init.lua listens).
local function changed(root, path)
  marks.render_all(root, path)
  vim.api.nvim_exec_autocmds('User', { pattern = 'ReviewChanged' })
end

local function range(first, last) return first == last and ('L%d'):format(first) or ('L%d-%d'):format(first, last) end

---Delete `comment` from the repository at `root`.
---@param root string
---@param comment review.Comment
function M.delete(root, comment)
  local s = store.get(root)
  s.comments = vim.tbl_filter(function(c) return c.id ~= comment.id end, s.comments)
  store.save(s)
  changed(root, comment.path)
  vim.notify(('Deleted comment: %s'):format(vim.split(comment.body, '\n')[1]))
end

---Open a floating markdown buffer at the cursor to write in. With a `rule`,
---`above` comes first (to read: a conversation), then the rule, then `text`;
---else just `text`. Returns the buffer, its window, and a function giving the
---lines above the rule and those below it (all of them, without a rule).
---@param o { name: string, title: string, footer: string, text: string[], above?: string[], highlights?: table[], rule?: string, center?: boolean }
---If one with the same name is open already, it's focused instead (and
---nothing is returned).
---@return integer? buf, integer? win, fun(): string[], string[]
function M.float(o)
  local open = vim.iter(vim.api.nvim_list_bufs()):find(function(b) return vim.api.nvim_buf_get_name(b) == o.name end)
  local shown = open and vim.fn.win_findbuf(open)[1]
  if shown then
    vim.api.nvim_set_current_win(shown)
    return ---@diagnostic disable-line: missing-return-value
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'acwrite', 'wipe', 'markdown'
  vim.api.nvim_buf_set_name(buf, o.name)
  local width = math.min(84, math.max(40, vim.api.nvim_win_get_width(0) - 8))
  local lines, rule = vim.list_extend({}, o.above or {}), nil
  if o.rule then
    local label = ('── %s '):format(o.rule)
    table.insert(lines, label .. ('─'):rep(width - vim.fn.strdisplaywidth(label)))
    rule = #lines
  end
  vim.list_extend(lines, o.text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  for _, h in ipairs(o.highlights or {}) do
    vim.hl.range(buf, ns, h[4], { h[1] - 1, h[2] }, { h[1] - 1, h[3] })
  end
  local mark = rule and vim.api.nvim_buf_set_extmark(buf, ns, rule - 1, 0, { line_hl_group = 'FloatBorder' })

  -- Below the cursor's line (or above it, if there's more room there), or
  -- in the middle. Its height is a guess until it's open (wrapping).
  local rows = 0
  for _, l in ipairs(lines) do rows = rows + math.ceil(math.max(1, vim.fn.strdisplaywidth(l)) / (width - 2)) end
  local height = math.max(8, math.min(rows + 1, math.floor(vim.o.lines / 2)))
  local row = vim.fn.screenrow()
  local above_it = row - 1 > vim.o.lines - row - 2 and vim.o.lines - row - 2 < height + 2
  local title = o.title
  if vim.fn.strdisplaywidth(title) > width - 4 then -- too long: the file's name, not its path
    title = title:gsub('^ (%S+)', function(path) return ' ' .. vim.fs.basename(path) end)
  end
  local at = o.center
      and { relative = 'editor', row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2) }
    or { relative = 'cursor', anchor = above_it and 'SW' or 'NW', row = above_it and 0 or 1, col = 0 }
  local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend('force', at, {
    style = 'minimal',
    width = width,
    height = height,
    title = title,
    footer = o.footer,
    footer_pos = 'right',
  }))
  vim.wo[win][0].wrap, vim.wo[win][0].linebreak = true, true
  -- Now exactly as tall as its text, wrapped (within limits).
  local fit = math.max(8, math.min(vim.api.nvim_win_text_height(win, {}).all + 1, math.floor(vim.o.lines / 2)))
  if fit ~= height then
    local config = { height = fit }
    if o.center then config = vim.tbl_extend('force', at, config, { row = math.floor((vim.o.lines - fit) / 2) - 1 }) end
    vim.api.nvim_win_set_config(win, config)
  end

  return buf, win, function()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if not mark then return {}, all end
    local row = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})[1]
    return vim.list_slice(all, 1, row), vim.list_slice(all, row + 2)
  end
end

---Text written in a float, without the blank lines it ends with.
local function body_of(lines)
  lines = vim.list_extend({}, lines)
  while #lines > 0 and vim.trim(lines[#lines]) == '' do table.remove(lines) end
  return table.concat(lines, '\n')
end

---Open a comment for writing: `comment` to edit it, or a new one on lines
---`first`..`last` of `buf`.
---@param buf integer
---@param first integer
---@param last integer
---@param comment? review.Comment
function M.open(buf, first, last, comment)
  local root, rev, path = marks.locate(buf)
  if not root then return vim.notify('Comments go on files in a git repository', vim.log.levels.WARN) end
  ---@cast rev string
  ---@cast path string
  local side = require('git.view').side(vim.api.nvim_get_current_win()) or 'right'
  local code = vim.api.nvim_buf_get_lines(buf, first - 1, last, false) -- (as it is now, while you write)
  local id = comment and comment.id or store.new_id()

  local cbuf, win, parts = M.float({
    name = ('review://%s/%s'):format(id, path),
    title = (' %s %s '):format(path, range(first, last)),
    footer = comment and ' ZZ save · ZQ discard · ZD delete ' or ' ZZ save · ZQ discard ',
    text = comment and vim.split(comment.body, '\n') or {},
  })
  if not cbuf then return end
  ---@cast win integer

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buf = cbuf,
    callback = function()
      local _, lines = parts()
      local body = body_of(lines)
      vim.bo[cbuf].modified = false
      local s = store.get(root)
      local saved = store.find(s, id)
      if body == '' then -- nothing to keep
        if saved then M.delete(root, saved) end
        return
      end
      if saved then
        saved.body = body
      else
        table.insert(s.comments, {
          id = id,
          path = path,
          rev = rev,
          side = side,
          line = first,
          end_line = last,
          code = code,
          body = body,
          created = os.time(),
        })
      end
      store.save(s)
      changed(root, path)
    end,
  })
  vim.keymap.set('n', 'ZD', function()
    vim.api.nvim_win_close(win, true)
    local saved = store.find(store.get(root), id)
    if saved then M.delete(root, saved) end
  end, { buf = cbuf, desc = 'Delete the comment' })

  if not comment then vim.cmd.startinsert() end
end

---A thread's posts, as lines to read (and where to colour them).
local function conversation(thread)
  local lines, hls = {}, {}
  for i, p in ipairs(thread.posts) do
    if i > 1 then table.insert(lines, '') end
    local head = ('%s · %s%s'):format(p.author, require('review').ago(p.time), p.pending and ' · pending' or '')
    table.insert(lines, head)
    table.insert(hls, { #lines, 0, #p.author, 'Title' })
    table.insert(hls, { #lines, #p.author, #head, 'Comment' })
    vim.list_extend(lines, vim.split((p.body:gsub('\r', '')), '\n'))
  end
  return lines, hls
end

---Open a thread on `buf`: to read, and to write your reply (a comment kept
---with the others until it's sent).
---@param buf integer
---@param thread review.Thread
function M.open_thread(buf, thread)
  local root = assert(marks.locate(buf))
  local function reply() -- your reply to it, as stored now
    return vim.iter(store.get(root).comments):find(function(c) return c.thread == thread.id end) ---@type review.Comment?
  end
  local drafted = reply()
  local above, hls = conversation(thread)
  local keys = { 'ZZ save reply', 'ZQ close' }
  if drafted then table.insert(keys, 'ZD delete reply') end
  if thread.resolve then table.insert(keys, thread.resolved and 'ZC reopen' or 'ZC resolve') end

  local cbuf, win, parts = M.float({
    name = ('review://%s/%s'):format(thread.id, thread.path),
    title = (' %s %s · %s%s%s '):format(thread.path, range(thread.line, thread.end_line), thread.where,
      thread.outdated and ' · outdated' or '', thread.resolved and ' · resolved' or ''),
    footer = (' %s '):format(table.concat(keys, ' · ')),
    above = above,
    highlights = hls,
    rule = drafted and 'your reply (not sent yet)' or 'reply',
    text = drafted and vim.split(drafted.body, '\n') or { '' },
  })
  if not cbuf then return end
  ---@cast win integer
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(cbuf), 0 })

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buf = cbuf,
    callback = function()
      local _, lines = parts()
      local body = body_of(lines)
      vim.bo[cbuf].modified = false
      local saved = reply()
      if body == '' then
        if saved then M.delete(root, saved) end
        return
      end
      local s = store.get(root)
      if saved then
        saved.body = body
      else
        table.insert(s.comments, {
          id = store.new_id(),
          path = thread.path,
          rev = thread.rev,
          side = 'right',
          line = thread.line,
          end_line = thread.end_line,
          code = thread.code,
          body = body,
          created = os.time(),
          thread = thread.id,
        })
      end
      store.save(s)
      changed(root, thread.path)
    end,
  })
  vim.keymap.set('n', 'ZD', function()
    vim.api.nvim_win_close(win, true)
    local saved = reply()
    if saved then M.delete(root, saved) end
  end, { buf = cbuf, desc = 'Delete your reply' })
  vim.keymap.set('n', 'ZC', function()
    if not thread.resolve then return vim.notify('Only sent threads can be resolved', vim.log.levels.WARN) end
    if vim.bo[cbuf].modified then vim.cmd.write() end -- keep a reply you wrote
    vim.api.nvim_win_close(win, true)
    thread.resolve(not thread.resolved)
  end, { buf = cbuf, desc = 'Resolve the thread, or reopen it' })
end

---<leader>c: in normal mode, open the thread or edit the comment on this
---line, or start one on it; in visual mode, start one on the selected lines.
function M.here()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  if mode:match('[vV\22]') then
    local a, b = vim.fn.line('v'), vim.fn.line('.')
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
    return M.open(buf, math.min(a, b), math.max(a, b))
  end
  local lnum = vim.fn.line('.')
  local thread = marks.thread_at(buf, lnum)
  if thread then return M.open_thread(buf, thread) end
  local existing = marks.at(buf, lnum)[1]
  if existing then return M.open(buf, existing.line, existing.end_line, existing) end
  M.open(buf, lnum, lnum)
end

---<leader>C: delete the comment on this line (or your reply to its thread).
function M.delete_here()
  local buf, lnum = vim.api.nvim_get_current_buf(), vim.fn.line('.')
  local root = marks.locate(buf)
  local existing = marks.at(buf, lnum)[1]
  local thread = not existing and marks.thread_at(buf, lnum)
  if thread then
    existing = vim.iter(store.get(root).comments):find(function(c) return c.thread == thread.id end)
  end
  if not existing then return vim.notify('No comment on this line') end
  M.delete(assert(root), existing)
end

return M
