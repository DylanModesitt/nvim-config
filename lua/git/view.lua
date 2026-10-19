-- git/view.lua: a tab showing sections of changed files, listed at the bottom,
-- with the selected file's two sides above it in Nvim's diff mode. Sections
-- come from a source: comparisons (:Diff, :Show), commits (:Log) or a pull
-- request (:PR, github/). When the right side is the working tree it's the
-- real file: edit it (and stage hunks with <leader>hs) as you read. The view
-- updates live as files, the index and HEAD change.
--
--   ]f [f    next/previous file (anywhere in the tab; walks through history)
--   ]c [c    next/previous hunk
--   q        close the view (in the list or a read-only side)
--   :q       closes a window as usual, which ends the view: :q on the left side
--            or the list (or :only on the right) leaves you the file, if the
--            right side is one
-- In the list:
--   <CR>     show the file under the cursor; on a commit, open or close it
--   s        stage the file (Unstaged) or unstage it (Staged)
--   S U      stage all / unstage all
--   X        discard the file's unstaged changes (asks first)
--   v        mark the file viewed (and go on to the next), or not; a change
--            to it since makes it unviewed again

local git = require('git')
local object = require('git.object')
local review = require('review') -- viewed marks and comment counts in the list

local M = {}

---@class git.Section a group of changes: a comparison's, or a commit's
---@field key string identifies it across refreshes
---@field cmp git.Comparison
---@field changes git.Change[]
---@field commit? git.Commit
---@field detail? string more about it, after its title

---@class git.Source where a view's sections come from
---@field title string
---@field fetch fun(callback: fun(sections: git.Section[]?, err: string?))
---@field worktree boolean whether it shows the working tree or index (watch it)
---@field collapse? boolean commits start closed, but the first
---@field keys? table<string, { [1]: fun(view: git.View), [2]: string }> its own keys in the list
---@field pr? table its maker's own data: a pull request's view keeps its PR (github/pr.lua)

---@class git.Item a changed file, as listed
---@field section git.Section
---@field cmp git.Comparison
---@field change git.Change
---@field line? integer its line in the list, if its section is open

---@class git.View
---@field tab integer
---@field root string
---@field source git.Source
---@field sections git.Section[]
---@field items git.Item[] every section's, in order
---@field lines table<integer, git.Item|git.Section> what each list line shows
---@field open table<string, boolean> sections opened or closed by hand
---@field current? git.Item the file shown
---@field list integer the list buffer
---@field wins { left: integer, right: integer, list: integer }
---@field generation integer the latest refresh; older ones are dropped
---@field unwatch? fun()

local views = {} ---@type table<integer, git.View>
local ns = vim.api.nvim_create_namespace('git.view')
local status_hl = { A = 'Added', ['?'] = 'Added', D = 'Removed', U = 'DiagnosticWarn' } -- else Changed

-- Each pane colours its side: the left in reds (what was removed), the right
-- in greens (what was added). Nvim highlights both windows of a diff alike,
-- so each pane remaps the diff groups ('winhighlight').
local pane_hl = {}
for side, group in pairs({ left = 'GitDiffRemoved', right = 'GitDiffAdded' }) do
  pane_hl[side] = table.concat({
    'DiffAdd:' .. group, 'DiffChange:' .. group, 'DiffText:' .. group .. 'Text',
    'DiffTextAdd:' .. group .. 'Text', 'DiffDelete:GitDiffFiller', 'Folded:GitDiffFolded',
  }, ',')
end

---A colour `t` of the way from `a` to `b` (colours as 0xRRGGBB).
local function blend(a, b, t)
  local c = 0
  for shift = 16, 0, -8 do
    local x, y = math.floor(a / 2 ^ shift) % 256, math.floor(b / 2 ^ shift) % 256
    c = c * 256 + math.floor(x + (y - x) * t + 0.5)
  end
  return c
end

---Define the panes' colours (again when the colorscheme changes): tints of
---the colorscheme's own red and green (its Removed and Added) over its
---background, so a diff looks like it belongs to whatever theme is on.
function M.highlights()
  local function get(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
  local normal = get('Normal')
  local dark = vim.o.background == 'dark'
  local bg = normal.bg or (dark and 0x000000 or 0xffffff) -- (no background: the terminal's)
  local fg = normal.fg or (dark and 0xffffff or 0x000000)
  local function tint(group, t) return blend(bg, get(group).fg or fg, t) end
  local function hl(name, val) vim.api.nvim_set_hl(0, name, val) end
  hl('GitDiffRemoved', { bg = tint('Removed', dark and 0.15 or 0.12) })
  hl('GitDiffRemovedText', { bg = tint('Removed', dark and 0.32 or 0.28) })
  hl('GitDiffAdded', { bg = tint('Added', dark and 0.15 or 0.12) })
  hl('GitDiffAddedText', { bg = tint('Added', dark and 0.32 or 0.28) })
  hl('GitDiffFiller', { fg = blend(bg, fg, 0.18) }) -- the ╱╱╱ opposite a change
  hl('GitDiffFolded', { link = 'Comment' })
end
M.highlights()

---'foldtext' for a run of unchanged lines.
function M.foldtext() return ('  ⋯ %d unchanged lines'):format(vim.v.foldend - vim.v.foldstart + 1) end

---The view in `tab` (default: the current tab), if it has one.
---@return git.View?
function M.get(tab) return views[tab or vim.api.nvim_get_current_tabpage()] end

---Which side of a view window `win` is: 'left', 'right', or nil (not a side).
---@param win integer
---@return 'left'|'right'|nil
function M.side(win)
  local view = M.get(vim.api.nvim_win_get_tabpage(win))
  if not view then return end
  return win == view.wins.left and 'left' or win == view.wins.right and 'right' or nil
end

---A view `pick` picks, if one does.
---@param pick fun(view: git.View): boolean
---@return git.View?
function M.find(pick)
  for _, view in pairs(views) do
    if pick(view) then return view end
  end
end

---The listed item for `path` in section `key`.
local function find_item(view, key, path)
  for _, item in ipairs(view.items) do
    if item.section.key == key and item.change.path == path then return item end
  end
end

local function is_open(view, sec)
  local open = view.open[sec.key]
  if open ~= nil then return open end
  return not view.source.collapse or sec == view.sections[1]
end

---Buffer names for an item's two sides.
local function sides(view, item)
  local c, cmp = item.change, item.cmp
  local function name(rev, path)
    if rev == 'worktree' and not c.submodule then return vim.fs.joinpath(view.root, path) end
    return object.name(view.root, rev, path)
  end
  local added = c.status == 'A' or c.status == '?'
  return name(added and 'none' or cmp.left.rev, c.oldpath or c.path),
    name(c.status == 'D' and 'none' or cmp.right.rev, c.path)
end

local function render(view)
  local lines, hls, items, at = {}, {}, {}, {}
  local function add(line, ...)
    table.insert(lines, line)
    for _, h in ipairs({ ... }) do table.insert(hls, { #lines, h[1], h[2] or #line, h[3] }) end
  end
  for _, sec in ipairs(view.sections) do
    local open = is_open(view, sec)
    local marks, viewed = {}, 0
    if open or not sec.commit then -- (a closed commit shows neither)
      for i, c in ipairs(sec.changes) do
        marks[i] = { review.status(view.root, sec.cmp, c) }
        if marks[i][1] then viewed = viewed + 1 end
      end
    end
    if sec.commit then
      local c = sec.commit
      local head = ('%s %s %s'):format(open and '▾' or '▸', c.short, c.subject)
      local meta = ('  %s · %s'):format(c.author, c.date)
      add(head .. meta, { 0, 3, 'Comment' }, { 4, 4 + #c.short, 'Identifier' }, { #head, nil, 'Comment' })
    else
      local count = viewed > 0 and ('%d, %d viewed'):format(#sec.changes, viewed) or tostring(#sec.changes)
      local head = ('%s (%s)'):format(sec.cmp.title, count)
      add(head .. (sec.detail and '  ' .. sec.detail or ''), { 0, #head, 'Title' }, { #head, nil, 'Comment' })
    end
    at[#lines] = sec
    if open and #sec.changes == 0 then add('  (no changes)', { 0, nil, 'Comment' }) end
    for i, c in ipairs(sec.changes) do
      local item = { section = sec, cmp = sec.cmp, change = c } ---@type git.Item
      table.insert(items, item)
      if open then
        local is_viewed, comments, threads = unpack(marks[i])
        local head = ('%s %s '):format(is_viewed and '✓' or ' ', c.status)
        local path = c.oldpath and (c.oldpath .. ' → ' .. c.path) or c.path
        local stat = c.binary and 'binary' or c.added and ('+%d -%d'):format(c.added, c.removed) or ''
        local line = head .. path .. (stat ~= '' and '  ' .. stat or '')
        local stat_at = #line - #stat
        local note = comments > 0 and ('  ● %d'):format(comments) or ''
        local talk = threads > 0 and ('  ◆ %d'):format(threads) or ''
        line = line .. note .. talk
        local note_hl = { #line - #talk - #note, #line - #talk, 'ReviewSign' }
        local talk_hl = { #line - #talk, nil, 'ReviewThread' }
        if is_viewed then -- done with: dimmed
          add(line, { 0, nil, 'Comment' }, note_hl, talk_hl)
        else
          add(line, { #head - 2, #head - 1, status_hl[c.status] or 'Changed' }, { stat_at, stat_at + #stat, 'Comment' },
            note_hl, talk_hl)
        end
        item.line, at[#lines] = #lines, item
      end
    end
  end
  view.items, view.lines = items, at

  -- Repaint only what changed: a refresh that finds nothing new is invisible.
  local old = vim.api.nvim_buf_get_lines(view.list, 0, -1, false)
  if not vim.deep_equal(old, lines) then
    vim.bo[view.list].modifiable = true
    vim.api.nvim_buf_set_lines(view.list, 0, -1, false, lines)
    vim.bo[view.list].modifiable = false
    if #old ~= #lines and vim.api.nvim_win_is_valid(view.wins.list) then
      vim.api.nvim_win_set_height(view.wins.list, math.max(3, math.min(#lines, 12)))
    end
  end
  vim.api.nvim_buf_clear_namespace(view.list, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.hl.range(view.list, ns, h[4], { h[1] - 1, h[2] }, { h[1] - 1, h[3] })
  end
end

---Show `item`'s two sides, at its first hunk, and its line in the list
---(opening its section if it's closed). `refresh` instead keeps every cursor
---and fold where it is, re-reading the index side in case that changed
---(other sides can't, or are real files).
local function show(view, item, refresh)
  local w = view.wins
  if not (vim.api.nvim_win_is_valid(w.left) and vim.api.nvim_win_is_valid(w.right)) then return end
  if not item.line and not refresh then -- in a closed section: open it (rendering lists items anew)
    view.open[item.section.key] = true
    render(view)
    item = find_item(view, item.section.key, item.change.path) or item
  end
  view.current = item
  if refresh then
    local changed = false
    for _, win in ipairs({ w.left, w.right }) do
      local buf = vim.api.nvim_win_get_buf(win)
      local obj = object.parse(vim.api.nvim_buf_get_name(buf))
      if obj and obj.rev == ':0' and object.reload(buf) then changed = true end
    end
    if changed then vim.api.nvim_win_call(w.right, vim.cmd.diffupdate) end
    return
  end

  local left, right = sides(view, item)
  vim.api.nvim_win_call(w.left, function() vim.cmd('diffoff!') end)
  for _, pane in ipairs({ { w.left, left }, { w.right, right } }) do
    vim.api.nvim_win_call(pane[1], function()
      if vim.api.nvim_buf_get_name(0) ~= pane[2] then
        vim.cmd.edit(vim.fn.fnameescape(vim.fn.fnamemodify(pane[2], ':~:.')))
      end
      vim.cmd.diffthis()
      vim.wo[0][0].foldlevel = 0 -- fold away what didn't change
    end)
  end
  local path = item.change.path:gsub('%%', '%%%%')
  for which, side in pairs({ left = item.cmp.left, right = item.cmp.right }) do
    local win = w[which]
    local wo, buf = vim.wo[win][0], vim.api.nvim_win_get_buf(win) -- [0]: :setlocal, not :set
    local revision = object.parse(vim.api.nvim_buf_get_name(buf))
    wo.winhighlight, wo.fillchars = pane_hl[which], 'diff:╱,fold: ,eob: '
    wo.foldtext = "v:lua.require'git.view'.foldtext()"
    wo.number, wo.relativenumber = true, false
    -- The winbar says which side and file; a revision's statusline would only
    -- repeat that as a long git:// name, so it keeps just the position.
    wo.winbar = (' %s  %%#Comment#%s'):format(side.label:gsub('%%', '%%%%'), path)
    wo.statusline = revision and '%= %-14.(%l,%c%V%) %P' or ''
    if revision then
      vim.keymap.set('n', 'q', function()
        local current = M.get() -- (the buffer can be in more than one view)
        if current then M.close(current) end
      end, { buf = buf, desc = 'Close the view' })
    end
  end
  vim.api.nvim_win_set_cursor(w.list, { item.line, 0 })
  vim.api.nvim_win_call(w.right, function()
    vim.cmd('normal! gg')
    if vim.fn.diff_hlID(1, 1) == 0 then vim.cmd('silent! normal! ]c') end
  end)
end

---Fetch the sections again, then keep showing the same file (re-reading its
---index side), or the nearest one if it's gone.
local function refresh(view)
  view.generation = view.generation + 1
  local gen = view.generation
  -- In a task, so what fetching runs (git rev-parse ...) doesn't block; the
  -- result is handled outside it, on the main loop, as it opens buffers.
  require('task').run(function() view.source.fetch(vim.schedule_wrap(function(sections, err)
    if view.generation ~= gen or views[view.tab] ~= view then return end
    if err then vim.notify('git: ' .. err, vim.log.levels.ERROR) end
    view.sections = sections or {}
    local cur = view.current
    render(view)
    if #view.items == 0 then return end
    local same = cur and find_item(view, cur.section.key, cur.change.path)
    if same then return show(view, same, true) end
    local line = cur and cur.line or 0
    for _, item in ipairs(view.items) do
      if item.line and item.line >= line then return show(view, item) end
    end
    show(view, view.items[1])
  end)) end)
end

---What the list's cursor line shows: an item or a section header.
local function at_cursor(view) return view.lines[vim.api.nvim_win_get_cursor(view.wins.list)[1]] end

local function unstaged(cmp) return cmp.kind == 'unstaged' end
local function staged(cmp) return cmp.kind == 'staged' end

---Run git, then refresh. False (and a message) if git failed.
local function run(view, args)
  local _, err = git.run(view.root, args)
  if err then vim.notify(err, vim.log.levels.ERROR) end
  refresh(view)
  return not err
end

---Stage an unstaged file, or unstage a staged one.
local function stage(view, item)
  local paths = { item.change.path, item.change.oldpath }
  if unstaged(item.cmp) then return run(view, vim.list_extend({ 'add', '-A', '--' }, paths)) end
  if staged(item.cmp) then return run(view, vim.list_extend({ 'reset', '-q', 'HEAD', '--' }, paths)) end
  vim.notify('Only unstaged and staged changes can be (un)staged', vim.log.levels.WARN)
end

---Stage everything unstaged (or unstage everything staged) in the view.
local function stage_all(view, unstage)
  for _, sec in ipairs(view.sections) do
    local paths = #sec.cmp.paths > 0 and sec.cmp.paths or { '.' }
    if unstage and staged(sec.cmp) then
      return run(view, vim.list_extend({ 'reset', '-q', 'HEAD', '--' }, paths))
    elseif not unstage and unstaged(sec.cmp) then
      return run(view, vim.list_extend({ 'add', '-A', '--' }, paths))
    end
  end
end

---Throw away a file's unstaged changes (an untracked file: delete it).
local function discard(view, item)
  local c = item.change
  if not unstaged(item.cmp) then
    return vim.notify('Only unstaged changes can be discarded', vim.log.levels.WARN)
  end
  local question = c.status == '?' and 'Delete untracked file %s?' or 'Discard your changes to %s?'
  if vim.fn.confirm(question:format(c.path), '&Discard\n&Cancel', 2, 'Warning') ~= 1 then return end
  if c.status == '?' then
    local path = vim.fs.joinpath(view.root, c.path)
    local buf = vim.iter(vim.api.nvim_list_bufs()):find(function(b) return vim.api.nvim_buf_get_name(b) == path end)
    if buf then -- let go of its buffer first, so nothing reports the file vanishing
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_call(win, function() vim.cmd.enew() end)
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    local ok, err = os.remove(path)
    if not ok then vim.notify(err or ('Could not delete ' .. c.path), vim.log.levels.ERROR) end
    return refresh(view)
  end
  run(view, { 'restore', '--', c.path })
end

---Open a view of `source`'s sections in a new tab.
---@param root string
---@param source git.Source
function M.open(root, source)
  vim.cmd.tabnew()
  local tab, left = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  vim.cmd('rightbelow vsplit')
  local right = vim.api.nvim_get_current_win()
  vim.cmd('botright split')
  local list = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, list)
  vim.bo[list].filetype, vim.bo[list].bufhidden = 'gitview', 'wipe'
  local wo = vim.wo[0][0]
  wo.number, wo.relativenumber, wo.signcolumn, wo.wrap, wo.list = false, false, 'no', false, false
  wo.cursorline, wo.winfixheight = true, true
  pcall(vim.api.nvim_buf_set_name, list, ('%s [%d]'):format(source.title, tab))
  vim.api.nvim_win_set_height(0, 3)

  local view = { ---@type git.View
    tab = tab,
    root = root,
    source = source,
    sections = {},
    items = {},
    lines = {},
    open = {},
    list = list,
    wins = { left = left, right = right, list = vim.api.nvim_get_current_win() },
    generation = 0,
  }
  views[tab] = view
  vim.t[tab].title = source.title

  -- Closing any of its windows (:q, :only, ...) ends the view.
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = vim.tbl_map(tostring, vim.tbl_values(view.wins)),
    once = true,
    callback = function() vim.schedule(function() M.dissolve(view) end) end,
  })

  -- Live: refresh as the repository changes (while this tab is the current one;
  -- entering it refreshes too).
  view.unwatch = require('git.watch').start(root, source.worktree, function()
    if views[tab] == view and M.get() == view then refresh(view) end
  end)

  local function map(lhs, fn, desc) vim.keymap.set('n', lhs, fn, { buf = list, desc = desc }) end
  map('<CR>', function()
    local at = at_cursor(view)
    if not at then return end
    if at.change then
      show(view, at)
      return vim.api.nvim_set_current_win(view.wins.right)
    end
    view.open[at.key] = not is_open(view, at) -- a header: open or close it
    render(view)
    local first = view.open[at.key] and at.changes[1]
    if first then show(view, find_item(view, at.key, first.path)) end
  end, 'Show this file / open or close this commit')
  map('s', function()
    local at = at_cursor(view)
    if at and at.change then stage(view, at) end
  end, 'Stage/unstage this file')
  map('S', function() stage_all(view, false) end, 'Stage all')
  map('U', function() stage_all(view, true) end, 'Unstage all')
  map('X', function()
    local at = at_cursor(view)
    if at and at.change then discard(view, at) end
  end, "Discard this file's changes")
  map('v', function()
    local at = at_cursor(view)
    if not (at and at.change) then return end
    local viewed = review.toggle_viewed(view.root, at.cmp, at.change)
    render(view)
    if not viewed then return end
    -- On to the next file not yet viewed, as on GitHub.
    local after = false
    for _, item in ipairs(view.items) do
      if after and not review.status(view.root, item.cmp, item.change) then return show(view, item) end
      after = after or (item.section.key == at.section.key and item.change.path == at.change.path)
    end
  end, 'Mark viewed / not viewed')
  map('q', function() M.close(view) end, 'Close the view')
  for lhs, key in pairs(source.keys or {}) do map(lhs, function() key[1](view) end, key[2]) end

  refresh(view)
end

---Move to the next (1) or previous (-1) file. False if this isn't a view.
function M.step(delta)
  local view = M.get()
  if not view then return false end
  if #view.items == 0 then return true end
  local i = 0
  for k, item in ipairs(view.items) do
    if item == view.current then i = k end
  end
  i = i == 0 and (delta > 0 and 1 or #view.items) or (i - 1 + delta) % #view.items + 1
  show(view, view.items[i])
  return true
end

local function forget(view)
  views[view.tab] = nil
  if view.unwatch then view.unwatch() end
end

---End a view that lost a window. If its right side is a real file and still
---open, that stays, as a plain window (`:q` the left side or the list, or
---`:only` the right: stop comparing, keep editing). Otherwise the tab closes:
---a lone revision or file list is no use.
function M.dissolve(view)
  local keep = view.wins.right
  if views[view.tab] ~= view or not vim.api.nvim_win_is_valid(keep) then return M.close(view) end
  local buf = vim.api.nvim_win_get_buf(keep)
  if vim.bo[buf].buftype ~= '' then return M.close(view) end
  forget(view)
  vim.t[view.tab].title = nil
  for _, win in ipairs({ view.wins.left, view.wins.list }) do
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.api.nvim_win_call(keep, function() vim.cmd.diffoff() end)
  local wo = vim.wo[keep][0] -- [0]: :setlocal, not :set
  wo.winhighlight, wo.fillchars, wo.winbar, wo.statusline = '', '', '', ''
  wo.foldtext, wo.number, wo.relativenumber = vim.go.foldtext, vim.go.number, vim.go.relativenumber
  wo.foldlevel = math.max(vim.go.foldlevelstart, 0)
  require('code').folds(keep) -- (syntax folds, as every window has)
end

---Close a view's tab (or, if it's the last tab, all but one plain window).
function M.close(view)
  if views[view.tab] ~= view then return end
  forget(view)
  if not vim.api.nvim_tabpage_is_valid(view.tab) then return end
  if #vim.api.nvim_list_tabpages() > 1 then
    return vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(view.tab))
  end
  vim.cmd('silent! diffoff!')
  if vim.api.nvim_win_is_valid(view.wins.right) then vim.api.nvim_set_current_win(view.wins.right) end
  vim.cmd('silent! only')
  if vim.bo.buftype ~= '' then vim.cmd.enew() end
end

local timer = assert(vim.uv.new_timer())

---Something may have changed (a write, focus, entering the tab): refresh the
---current tab's view, once things settle.
function M.changed()
  if not M.get() then return end
  timer:stop()
  timer:start(150, 0, vim.schedule_wrap(function()
    local view = M.get()
    if view then refresh(view) end
  end))
end

---Forget views whose tab was closed.
function M.close_stale()
  for tab, view in pairs(views) do
    if not vim.api.nvim_tabpage_is_valid(tab) then forget(view) end
  end
end

return M
