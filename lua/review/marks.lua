-- review/marks.lua: comments and threads shown where their content is, in
-- diff views and plain buffers alike: a mark in the sign column (● for a
-- comment, ◆ for a thread, ┌│└ for either on a range) and its first line at
-- the end of its first line. No virtual lines: in a diff they would push one
-- side out of line with the other.
--
-- A comment remembers the code it's about. When that code moves (an agent
-- rewrote the file, you added lines above it) the comment moves with it; when
-- it's gone, the comment is marked outdated rather than pointing at whatever
-- is there now. Threads are found the same way, each time they're shown.

local store = require('review.store')

local M = {}

local ns = vim.api.nvim_create_namespace('review')
local tracked = {} ---@type table<integer, table<string, integer>> buf -> comment id -> extmark
local shown = {} ---@type table<integer, { thread: review.Thread, first: integer, last: integer }[]>

---Define the marks' colours (again after a colorscheme change clears them).
function M.highlights()
  vim.api.nvim_set_hl(0, 'ReviewSign', { link = 'DiagnosticInfo', default = true })
  vim.api.nvim_set_hl(0, 'ReviewThread', { link = 'DiagnosticWarn', default = true })
  vim.api.nvim_set_hl(0, 'ReviewOutdated', { link = 'Comment', default = true })
end
M.highlights()

---What `buf` shows: its repository, revision and path, if it's a file in one.
---@return string? root, string? rev, string? path
function M.locate(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local obj = require('git.object').parse(name)
  if obj then return obj.root, obj.rev, obj.path end
  if vim.bo[buf].buftype ~= '' or name == '' then return end
  local root = vim.fs.root(buf, '.git')
  if root and vim.startswith(name, root .. '/') then return root, 'worktree', name:sub(#root + 2) end
end

local function matches(lines, at, code)
  for i, line in ipairs(code) do
    if lines[at + i - 1] ~= line then return false end
  end
  return true
end

---Where `code` is in `lines`: at line `near` if it's still there, else the
---nearest place it is now. Nil if it's gone.
---@param lines string[]
---@param code string[]
---@param near integer
---@return integer?
function M.find(lines, code, near)
  if matches(lines, near, code) then return near end
  local best
  for at = 1, #lines - #code + 1 do
    if lines[at] == code[1] and matches(lines, at, code) then
      if not best or math.abs(at - near) < math.abs(best - near) then best = at end
    end
  end
  return best
end

---Find the comment's code in `lines`, moving the comment there (or marking it
---outdated). Returns whether the comment changed.
local function anchor(c, lines)
  local at = M.find(lines, c.code, c.line)
  if at == c.line then
    local changed = c.outdated ~= nil
    c.outdated = nil
    return changed
  end
  if at then
    c.line, c.end_line, c.outdated = at, at + #c.code - 1, nil
  else
    c.outdated = true
  end
  return true
end

---Put a mark on lines `first`..`last`: `glyph` for one line, a bracket for
---more, with `text` after the first. Returns the extmark spanning them.
local function place(buf, first, last, glyph, hl, text, priority)
  local count = vim.api.nvim_buf_line_count(buf)
  first, last = math.min(first, count), math.min(last, count)
  for l = first, last do
    local sign = first == last and glyph or l == first and '┌' or l == last and '└' or '│'
    vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { sign_text = sign, sign_hl_group = hl, priority = priority })
  end
  return vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, {
    end_row = last - 1,
    invalidate = true, -- deleting the lines deletes the comment's place
    virt_text = { { '  ' .. text, hl } },
    virt_text_pos = 'eol',
    hl_mode = 'combine',
  })
end

local function first_line(text) return vim.split(text, '\n')[1] end

---Show `buf`'s comments and threads, re-finding any whose code moved.
---@param buf integer
function M.render(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  tracked[buf], shown[buf] = nil, nil
  local root, rev, path = M.locate(buf)
  if not root then return end
  local s = store.get(root)
  -- Replies show with their thread, not on their own.
  local comments, replied = {}, {}
  for _, c in ipairs(store.on(s, path, rev)) do
    if c.thread then replied[c.thread] = true else table.insert(comments, c) end
  end
  local threads = vim.tbl_filter(function(t) return t.path == path and t.rev == rev end, require('review').threads(root))
  if #comments == 0 and #threads == 0 then return end
  local lines, moved = vim.api.nvim_buf_get_lines(buf, 0, -1, false), false

  tracked[buf] = {}
  for _, c in ipairs(comments) do
    moved = anchor(c, lines) or moved
    local text = (c.outdated and '(outdated) ' or '') .. first_line(c.body)
    tracked[buf][c.id] = place(buf, c.line, c.end_line, '●', c.outdated and 'ReviewOutdated' or 'ReviewSign', text, 20)
  end
  if moved then store.save(s) end

  shown[buf] = {}
  for _, t in ipairs(threads) do -- where its code is, else where it was (outdated)
    local at = M.find(lines, t.code, t.line)
    local first, last = at or t.line, (at or t.line) + t.end_line - t.line
    local outdated, post = t.outdated or not at, t.posts[1]
    local hl = t.pending and 'ReviewSign' or (t.resolved or outdated) and 'ReviewOutdated' or 'ReviewThread'
    local text = ('%s%s%s: %s'):format(t.resolved and 'resolved · ' or '', outdated and '(outdated) ' or '',
      post.author, first_line(post.body))
    if #t.posts > 1 then text = ('%s  (+%d)'):format(text, #t.posts - 1) end
    if replied[t.id] then text = text .. '  · your reply, not sent yet' end
    place(buf, first, last, '◆', hl, text, 19)
    table.insert(shown[buf], { thread = t, first = first, last = last })
  end
end

---Show the comments again in every buffer showing `path` of `root` (or any
---file of it).
function M.render_all(root, path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local r, _, p = M.locate(buf)
    if r == root and (not path or p == path) then M.render(buf) end
  end
end

---After you save edits to a file: take each comment's place from where its
---mark moved to, and its code from what's there now (your edits to the lines
---it's about carry it along). An outdated comment stays outdated.
---@param buf integer
function M.sync(buf)
  local root = M.locate(buf)
  if not (root and tracked[buf]) then return end
  local s, changed = store.get(root), false
  for _, c in ipairs(s.comments) do
    local id = not c.outdated and tracked[buf][c.id]
    local mark = id and vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
    if mark and mark[1] then
      if mark[3].invalid then
        c.outdated, changed = true, true
      else
        local first, last = mark[1] + 1, mark[3].end_row + 1
        local code = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
        if first ~= c.line or last ~= c.end_line or not vim.deep_equal(code, c.code) then
          c.line, c.end_line, c.code, changed = first, last, code, true
        end
      end
    end
  end
  if changed then store.save(s) end
  M.render(buf)
end

---Comments (not replies) on line `lnum` of `buf`.
---@return review.Comment[]
function M.at(buf, lnum)
  local root, rev, path = M.locate(buf)
  if not root then return {} end
  return vim.tbl_filter(function(c) return not c.thread and c.line <= lnum and lnum <= c.end_line end,
    store.on(store.get(root), path, rev))
end

---The thread shown on line `lnum` of `buf`, if any.
---@return review.Thread?
function M.thread_at(buf, lnum)
  for _, s in ipairs(shown[buf] or {}) do
    if s.first <= lnum and lnum <= s.last then return s.thread end
  end
end

return M
