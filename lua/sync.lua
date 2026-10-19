-- sync.lua: buffers and files stay in sync both ways, because the files on
-- disk are what agents (and git, tests, dev servers) read and write.
--
-- Disk to buffer: buffers reload as soon as their file changes. Buffer to
-- disk: edits are saved at rest points. Where both changed, nothing is
-- overwritten either way until you settle it: :w keeps yours, :e! takes theirs.

local api = vim.api
local group = api.nvim_create_augroup('sync', {})

-- Disk -> buffer --------------------------------------------------------------
-- 'autoread' only acts when something runs :checktime. Here one OS watcher
-- (libuv fs_event: FSEvents on macOS) per directory holding a loaded file
-- buffer runs :checktime on that directory's buffers when it changes. No
-- polling; idle cost is zero. Directories rather than files, because tools
-- often save by renaming a temp file over the original, which would leave a
-- per-file watcher pointing at the old, deleted file.
--
-- Unmodified buffers reload silently (`u` undoes a reload).

local watchers = {} ---@type table<string, uv.uv_fs_event_t>
local queued = {} ---@type table<string, true>

---Loaded, named file buffers whose file lives directly in `dir`.
local function bufs_in(dir)
  return vim.tbl_filter(function(buf)
    local name = api.nvim_buf_get_name(buf)
    return api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and name ~= ''
      and vim.fs.dirname(name) == dir
  end, api.nvim_list_bufs())
end

local function check(dir)
  queued[dir] = nil
  for _, buf in ipairs(bufs_in(dir)) do
    vim.cmd.checktime(buf)
  end
end

local function watch(dir)
  if watchers[dir] then return end
  local w = assert(vim.uv.new_fs_event())
  local ok = w:start(dir, {}, function(err)
    -- One check per burst of events (an agent writing several files, a checkout).
    if err or queued[dir] then return end
    queued[dir] = true
    vim.defer_fn(function() check(dir) end, 50)
  end)
  if ok then
    watchers[dir] = w
  else
    w:close() -- e.g. a new file whose directory doesn't exist yet
  end
end

local function unwatch_if_unused(dir)
  local w = watchers[dir]
  if w and #bufs_in(dir) == 0 then
    w:stop()
    w:close()
    watchers[dir] = nil
  end
end

local function file_dir(buf)
  local name = api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype == '' and name ~= '' then return vim.fs.dirname(name) end
end

api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'BufWritePost', 'BufFilePost' }, {
  group = group,
  callback = function(ev)
    local dir = file_dir(ev.buf)
    if dir then watch(dir) end
  end,
})

api.nvim_create_autocmd({ 'BufUnload', 'BufFilePre' }, {
  group = group,
  callback = function(ev)
    local dir = file_dir(ev.buf)
    -- Recount once the buffer is actually gone/renamed.
    if dir then vim.schedule(function() unwatch_if_unused(dir) end) end
  end,
})

-- Safety net: anything changed while Neovim wasn't looking.
api.nvim_create_autocmd('FocusGained', {
  group = group,
  command = 'checktime',
})

-- Decide what a detected change does (replaces the W11/W12 prompts). A file
-- that changed under unsaved edits, or was deleted, is marked in conflict
-- (b:conflict) and left alone until you settle it. Nvim itself still asks
-- before a :w overwrites a file that changed since it was read.
api.nvim_create_autocmd('FileChangedShell', {
  group = group,
  callback = function(ev)
    local reason, name = vim.v.fcs_reason, vim.fn.fnamemodify(ev.file, ':~:.')
    vim.v.fcs_choice = ''
    if reason == 'changed' or reason == 'mode' then
      vim.v.fcs_choice = 'reload'
    elseif reason == 'conflict' then
      vim.b[ev.buf].conflict = 'conflict'
      vim.notify(name .. ' changed on disk while you had unsaved changes. Autosave is paused '
        .. 'for it: :e! loads the version on disk, :w asks before overwriting it.', vim.log.levels.WARN)
    elseif reason == 'deleted' then
      vim.b[ev.buf].conflict = 'deleted'
      vim.notify(name .. ' was deleted on disk. Autosave is paused for it: :w writes it back.',
        vim.log.levels.WARN)
    end
    vim.schedule(function() vim.cmd.redrawstatus({ bang = true }) end) -- show/clear the marker
  end,
})

-- Settled by :e! or a :w that went through. (BufWritePost also fires when you
-- answer "n" to that prompt; the buffer is still modified then.)
api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'BufWritePost' }, {
  group = group,
  callback = function(ev)
    if not vim.bo[ev.buf].modified then vim.b[ev.buf].conflict = nil end
  end,
})

-- The warning above is easily missed mid-typing, so a conflicted buffer also
-- says so in its statusline, after the [+], until it's settled: [conflict] or
-- [deleted].
vim.o.statusline = vim.o.statusline:gsub('%%m%%r',
  "%%m%%r%%{%% get(b:, 'conflict', '') != '' ? '%%#WarningMsg#[' .. b:conflict .. ']%%* ' : '' %%}", 1)

-- Buffer -> disk (autosave) ---------------------------------------------------
-- Modified file buffers are written at rest points: leaving insert mode, after
-- a normal-mode change (dd, p, u, :s, gq, ...), and on switching buffers or
-- apps. Never mid-typing, so watchers and dev servers only see whole edits.

local function save(buf)
  local bo = vim.bo[buf]
  if not bo.modified or bo.buftype ~= '' or bo.readonly or not bo.modifiable then return end
  if api.nvim_buf_get_name(buf) == '' or vim.b[buf].conflict then return end
  -- Catch a write the watcher hasn't reported yet: it becomes a conflict
  -- rather than something this save silently overwrites.
  vim.cmd.checktime(buf)
  if vim.b[buf].conflict or not bo.modified then return end
  api.nvim_buf_call(buf, function()
    local ok, err = pcall(function() vim.cmd('silent lockmarks update') end)
    if not ok then vim.notify('Autosave: ' .. err, vim.log.levels.ERROR) end
  end)
end

api.nvim_create_autocmd({ 'InsertLeave', 'TextChanged', 'BufLeave', 'FocusLost' }, {
  group = group,
  nested = true, -- the write runs BufWritePre/Post autocmds (LSP didSave, ...) like any :w
  callback = function()
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(buf) then save(buf) end
    end
  end,
})
