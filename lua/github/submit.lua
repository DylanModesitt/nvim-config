-- github/submit.lua: send your comments on a pull request to it, as one
-- review. A float to write the review's summary in, above the comments that
-- go with it (delete one's line to keep it back); ZZ, then Comment, Approve
-- or Request changes (on your own pull request, only Comment).
--
-- Each comment goes on its lines if GitHub's diff has them, else on its file,
-- quoting them. Sent, it's GitHub's: a thread, no longer a comment here. If
-- any can't be sent, the review isn't: what was sent waits in it, pending on
-- GitHub (only you see it), and :PR submit sends it once you've fixed the
-- rest.

local git = require('git')
local gh = require('github')
local store = require('review.store')
local task = require('task')

local M = {}

local ns = vim.api.nvim_create_namespace('github.submit')

---Your comments on a pull request: on lines of its files (either side), and
---replies to its threads.
---@param pr github.PR
---@return review.Comment[]
local function comments(pr)
  local files, threads = {}, {}
  for path in vim.gsplit(git.run(pr.root, { 'diff', '--name-only', '-z', pr.left.rev, pr.head_oid }) or '', '\0') do
    files[path] = true
  end
  for _, t in ipairs(pr.threads) do threads[t.id] = t end
  return vim.tbl_filter(function(c)
    if c.thread then return threads[c.thread] ~= nil end
    return files[c.path] and (c.rev == pr.left.rev or c.rev == pr.right.rev)
  end, store.get(pr.root).comments)
end

---Where a comment is in GitHub's diff: its side and lines. One on the
---checkout's files finds its code in the pushed head. Nil if it can't.
---@return string? side, integer? first, integer? last
local function position(pr, c)
  if c.outdated then return end
  if c.rev == pr.left.rev then return 'LEFT', c.line, c.end_line end
  if c.rev ~= 'worktree' then return 'RIGHT', c.line, c.end_line end
  local text = git.run(pr.root, { 'show', pr.head_oid .. ':' .. c.path })
  local at = text and require('review.marks').find(vim.split(text, '\n', { plain = true }), c.code, c.line)
  if at then return 'RIGHT', at, at + #c.code - 1 end
end

---A comment on its file, quoting the lines it's about.
local function on_file(review, c)
  local range = c.line == c.end_line and ('Line %d'):format(c.line) or ('Lines %d-%d'):format(c.line, c.end_line)
  local lang = vim.filetype.match({ filename = c.path }) or ''
  local quote = ('%s:\n```%s\n%s\n```\n\n'):format(range, lang, table.concat(c.code, '\n'))
  return {
    field = 'addPullRequestReviewThread',
    type = 'AddPullRequestReviewThreadInput',
    input = { pullRequestReviewId = review, path = c.path, body = quote .. c.body, subjectType = 'FILE' },
  }
end

---The mutation adding a comment to `review`.
local function adding(pr, review, c)
  if c.thread then
    return {
      field = 'addPullRequestReviewThreadReply',
      type = 'AddPullRequestReviewThreadReplyInput',
      input = { pullRequestReviewId = review, pullRequestReviewThreadId = c.thread, body = c.body },
    }
  end
  local side, first, last = position(pr, c)
  if not side then return on_file(review, c) end
  return {
    field = 'addPullRequestReviewThread',
    type = 'AddPullRequestReviewThreadInput',
    input = {
      pullRequestReviewId = review,
      path = c.path,
      body = c.body,
      subjectType = 'LINE',
      side = side,
      line = last,
      startLine = first < last and first or nil,
      startSide = first < last and side or nil,
    },
  }
end

---Run mutations as one request. Returns those that worked and those that
---didn't (each with its `error`).
local function run(ops)
  if #ops == 0 then return {}, {} end
  local params, fields, vars = {}, {}, {}
  for i, op in ipairs(ops) do
    params[i] = ('$i%d: %s!'):format(i, op.type)
    fields[i] = ('m%d: %s(input: $i%d) { clientMutationId }'):format(i, op.field, i)
    vars['i' .. i] = op.input
  end
  local query = ('mutation(%s) {\n%s\n}'):format(table.concat(params, ', '), table.concat(fields, '\n'))
  local data, errors = gh.graphql(query, vars)
  local why = {}
  for _, e in ipairs(errors or {}) do
    if e.path then why[e.path[1]] = e.message end
  end
  local done, failed = {}, {}
  for i, op in ipairs(ops) do
    if data['m' .. i] then
      table.insert(done, op)
    else
      op.error = why['m' .. i] or (errors and errors[1].message) or 'failed'
      table.insert(failed, op)
    end
  end
  return done, failed
end

local verdicts = { COMMENT = 'Commented', APPROVE = 'Approved', REQUEST_CHANGES = 'Requested changes' }

---Send `chosen` comments to the pull request as a review: `event` (COMMENT,
---APPROVE or REQUEST_CHANGES), with `body` as its summary.
---@param pr github.PR
---@param chosen review.Comment[]
local function send(pr, chosen, event, body)
  vim.notify(('Sending your review of #%d…'):format(pr.number))
  local review = pr.review
  if not review then
    review = gh.query([[mutation($pr: ID!, $commit: GitObjectID!) {
      addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit }) { pullRequestReview { id } }
    }]], { pr = pr.id, commit = pr.head_oid }).addPullRequestReview.pullRequestReview.id
    pr.review = review
  end

  local ops = vim.tbl_map(function(c)
    local op = adding(pr, review, c)
    op.comment = c
    return op
  end, chosen)
  local done, failed = run(ops)
  -- Lines GitHub's diff doesn't have: on their file instead.
  local retry = vim.tbl_filter(function(op) return op.input.subjectType == 'LINE' end, failed)
  failed = vim.tbl_filter(function(op) return op.input.subjectType ~= 'LINE' end, failed)
  local retried, still = run(vim.tbl_map(function(op)
    local again = on_file(review, op.comment)
    again.comment = op.comment
    return again
  end, retry))
  vim.list_extend(done, retried)
  vim.list_extend(failed, still)

  local sent = {}
  for _, op in ipairs(done) do sent[op.comment.id] = true end
  local s = store.get(pr.root)
  s.comments = vim.tbl_filter(function(c) return not sent[c.id] end, s.comments)
  store.save(s)

  if #failed > 0 then
    require('github.pr').reload(pr)
    local why = vim.tbl_map(function(op)
      return ('  %s:%d: %s'):format(op.comment.path, op.comment.line, op.error)
    end, failed)
    return task.fail(('%d of your comments could not be sent, so neither was the review (the rest wait in it, '
      .. 'pending):\n%s'):format(#failed, table.concat(why, '\n')))
  end

  gh.query([[mutation($id: ID!, $event: PullRequestReviewEvent!, $body: String) {
    submitPullRequestReview(input: { pullRequestReviewId: $id, event: $event, body: $body }) {
      pullRequestReview { state }
    }
  }]], { id = review, event = event, body = body ~= '' and body or nil })
  pr.review = nil
  require('github.pr').reload(pr)
  local notes = {}
  if #done > 0 then table.insert(notes, ('%d comment%s'):format(#done, #done == 1 and '' or 's')) end
  if #retried > 0 then table.insert(notes, ('%d on its file (not in the diff)'):format(#retried)) end
  vim.notify(('%s on #%d%s'):format(verdicts[event], pr.number,
    #notes > 0 and (', with ' .. table.concat(notes, ', ')) or ''))
end

---A comment, as one line in the list of what's sent.
local function describe(pr, c)
  local text = vim.split(c.body, '\n')[1]
  if c.thread then
    local t = vim.iter(pr.threads):find(function(t) return t.id == c.thread end)
    return ('↳ %s:%d  to %s: %s'):format(vim.fs.basename(c.path), c.line, t.posts[1].author, text)
  end
  return ('● %s:%d  %s'):format(vim.fs.basename(c.path), c.line, text)
end

---Open the float to send a review of the pull request you're looking at.
function M.open()
  task.run(function()
    local pr = require('github.pr').current() or task.fail('Open a pull request first (:PR)')
    local list = comments(pr)
    local pending = 0
    for _, t in ipairs(pr.threads) do
      for _, p in ipairs(t.posts) do pending = pending + (p.pending and 1 or 0) end
    end
    local rule = #list == 0 and 'no comments' or ('%d comment%s'):format(#list, #list == 1 and '' or 's')
    if pending > 0 then rule = ('%s, and %d pending on GitHub'):format(rule, pending) end

    local buf, win, parts = require('review.compose').float({
      name = ('review://%s/review'):format(pr.key),
      title = (' Review #%d '):format(pr.number),
      footer = ' ZZ send · ZQ cancel ',
      center = true,
      above = { '' },
      rule = rule .. ' (delete a line to keep it back)',
      text = vim.tbl_map(function(c) return describe(pr, c) end, list),
    })
    if not buf then return end
    ---@cast win integer
    local marks = {}
    for i, c in ipairs(list) do
      marks[c.id] = vim.api.nvim_buf_set_extmark(buf, ns, i + 1, 0, { invalidate = true })
    end
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    local function submit()
      local above = parts()
      local chosen = vim.tbl_filter(function(c)
        local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, marks[c.id], { details = true })
        return m[1] ~= nil and not m[3].invalid
      end, list)
      local events = pr.mine and { 'COMMENT' } or { 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }
      local buttons = pr.mine and '&Comment\nCa&ncel' or '&Comment\n&Approve\n&Request changes\nCa&ncel'
      local what = #chosen == 0 and 'your review' or ('your review, with %d comment%s'):format(#chosen,
        #chosen == 1 and '' or 's')
      local choice = vim.fn.confirm(('Send %s, to #%d?'):format(what, pr.number), buttons, 1)
      local event = events[choice]
      if not event then return end
      vim.bo[buf].modified = false
      vim.api.nvim_win_close(win, true)
      task.run(function() send(pr, chosen, event, vim.trim(table.concat(above, '\n'))) end)
    end
    vim.keymap.set('n', 'ZZ', submit, { buf = buf, desc = 'Send the review' })
    -- (:w doesn't send it: sending closes the window, which :x or :wq would
    -- then do again, to the window beneath.)
    vim.api.nvim_create_autocmd('BufWriteCmd', {
      buf = buf,
      callback = function() vim.notify('ZZ sends the review, ZQ cancels it') end,
    })
  end)
end

return M
