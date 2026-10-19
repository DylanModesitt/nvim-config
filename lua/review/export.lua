-- review/export.lua: a repository's review comments, and its open threads, as
-- markdown, ready to hand to an agent (or anyone): per file, each with the
-- code it's about.

local store = require('review.store')

local M = {}

local rev_names = { worktree = 'working tree', [':0'] = 'index' }

local function quote(author, body)
  local lines = vim.split((body:gsub('\r', '')), '\n')
  lines[1] = ('**%s**: %s'):format(author, lines[1])
  return vim.tbl_map(function(l) return l == '' and '>' or '> ' .. l end, lines)
end

---@param root string
---@return string markdown, integer count
function M.markdown(root)
  local threads = vim.tbl_filter(function(t) return not t.resolved end, require('review').threads(root))
  local replies, entries = {}, {}
  for _, t in ipairs(threads) do table.insert(entries, { at = t, thread = t }) end
  for _, c in ipairs(store.get(root).comments) do
    if c.thread then replies[c.thread] = c end
  end
  for _, c in ipairs(store.get(root).comments) do
    local t = c.thread and vim.iter(threads):find(function(t) return t.id == c.thread end)
    if not t then table.insert(entries, { at = c, comment = c }) end -- (a reply shows with its thread)
  end
  table.sort(entries, function(a, b)
    if a.at.path ~= b.at.path then return a.at.path < b.at.path end
    return a.at.line < b.at.line
  end)

  local out = { ('# Review comments: %s'):format(vim.fn.fnamemodify(root, ':~')), '' }
  local path
  for _, e in ipairs(entries) do
    local x = e.at
    if x.path ~= path then
      path = x.path
      vim.list_extend(out, { ('## `%s`'):format(path), '' })
    end
    local range = x.line == x.end_line and ('line %d'):format(x.line) or ('lines %d-%d'):format(x.line, x.end_line)
    if #x.code == 0 then range = 'the whole file' end
    local notes = { rev_names[x.rev] or ('commit %s'):format(x.rev:sub(1, 10)) }
    if e.thread then table.insert(notes, 1, ('a review thread on %s'):format(e.thread.where)) end
    if x.side == 'left' then table.insert(notes, 'the old side of the diff') end
    if x.outdated then table.insert(notes, 'outdated: this code has since changed') end
    vim.list_extend(out, { ('%s (%s):'):format(range, table.concat(notes, '; ')), '' })
    if #x.code > 0 then
      local lang = vim.filetype.match({ filename = x.path }) or ''
      vim.list_extend(out, { '```' .. lang })
      vim.list_extend(out, x.code)
      vim.list_extend(out, { '```', '' })
    end
    if e.comment then
      vim.list_extend(out, { (e.comment.thread and 'A reply to a review thread: ' or '') .. e.comment.body, '' })
    else
      for i, p in ipairs(e.thread.posts) do
        if i > 1 then table.insert(out, '>') end
        vim.list_extend(out, quote(p.author, p.body))
      end
      local reply = replies[e.thread.id]
      if reply then vim.list_extend(vim.list_extend(out, { '>' }), quote('Your reply (not sent yet)', reply.body)) end
      table.insert(out, '')
    end
  end
  return table.concat(out, '\n'), #entries
end

return M
