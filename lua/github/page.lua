-- github/page.lua: a pull request to read, in a float: its description,
-- where it stands (checks, reviews, labels) and its conversation, as
-- markdown. GitHub's Conversation tab, less the review threads (those show
-- in its diff).
--
--   q   close it          o   open it on GitHub

local gh = require('github')
local task = require('task')

local M = {}

local QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number title url body state isDraft createdAt reviewDecision
      additions deletions changedFiles baseRefName headRefName
      author { login }
      labels(first: 20) { nodes { name } }
      reviewRequests(first: 20) {
        nodes { requestedReviewer { ... on User { login } ... on Team { name } ... on Bot { login } } }
      }
      latestOpinionatedReviews(first: 20) { nodes { author { login } state } }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
          __typename
          ... on CheckRun { name status conclusion }
          ... on StatusContext { context state }
        } } } } }
      }
      comments(first: 100) { nodes { author { login } body createdAt } }
      reviews(first: 100) { nodes { author { login } body state submittedAt } }
    }
  }
}]]

local states = { OPEN = 'Open', MERGED = 'Merged', CLOSED = 'Closed' }
local decisions = { APPROVED = 'Approved', CHANGES_REQUESTED = 'Changes requested', REVIEW_REQUIRED = 'Review required' }
local verdicts = { APPROVED = 'approved', CHANGES_REQUESTED = 'requested changes', COMMENTED = 'reviewed',
  DISMISSED = 'review dismissed' }
local failing = { FAILURE = true, ERROR = true, TIMED_OUT = true, CANCELLED = true, ACTION_REQUIRED = true,
  STARTUP_FAILURE = true }

local function login(who) return who and (who.login or who.name) or 'ghost' end

---Its checks, in a phrase: what failed, else what's running, else all passed.
local function checks(rollup)
  if not rollup then return end
  local passed, failed, running = 0, {}, 0
  for _, c in ipairs(rollup.contexts.nodes) do
    local result = c.conclusion or c.state
    if c.__typename == 'CheckRun' and c.status ~= 'COMPLETED' or result == 'PENDING' or result == 'EXPECTED' then
      running = running + 1
    elseif failing[result] then
      table.insert(failed, c.name or c.context)
    elseif result == 'SUCCESS' then
      passed = passed + 1
    end
  end
  if #failed > 0 then return ('✗ %d failing: %s'):format(#failed, table.concat(failed, ', ')) end
  if running > 0 then return ('● %d running, %d passed'):format(running, passed) end
  return ('✓ %d checks passed'):format(passed)
end

---The page, as markdown lines.
local function render(p)
  local ago = require('review').ago
  local lines = { '# ' .. p.title, '' }
  local function add(text) vim.list_extend(lines, vim.split(text, '\n')) end

  add(('**#%d** · %s%s · %s wants to merge `%s` into `%s` · %s'):format(p.number, states[p.state] or p.state,
    p.isDraft and ' (draft)' or '', login(p.author), p.headRefName, p.baseRefName, ago(gh.epoch(p.createdAt))))
  local commit = p.commits.nodes[1]
  local status = vim.tbl_filter(function(x) return x ~= false end, {
    checks(commit and commit.commit.statusCheckRollup) or false,
    decisions[p.reviewDecision] or false,
    ('+%d −%d in %d files'):format(p.additions, p.deletions, p.changedFiles),
  })
  add(table.concat(status, ' · '))
  local people = {}
  for _, r in ipairs(p.latestOpinionatedReviews.nodes) do
    table.insert(people, ('%s (%s)'):format(login(r.author), verdicts[r.state] or r.state:lower()))
  end
  for _, r in ipairs(p.reviewRequests.nodes) do
    table.insert(people, ('%s (requested)'):format(login(r.requestedReviewer)))
  end
  local about = {}
  if #people > 0 then table.insert(about, 'Reviewers: ' .. table.concat(people, ', ')) end
  if #p.labels.nodes > 0 then
    table.insert(about, 'Labels: ' .. table.concat(vim.tbl_map(function(l) return l.name end, p.labels.nodes), ', '))
  end
  if #about > 0 then add(table.concat(about, ' · ')) end

  local body = gh.clean(p.body)
  add('\n---\n')
  add(body ~= '' and body or '_No description._')

  -- The conversation: comments, and reviews that say something.
  local posts = {}
  for _, c in ipairs(p.comments.nodes) do
    table.insert(posts, { author = login(c.author), body = gh.clean(c.body), time = gh.epoch(c.createdAt) })
  end
  for _, r in ipairs(p.reviews.nodes) do
    local body = gh.clean(r.body)
    if r.state ~= 'PENDING' and (body ~= '' or r.state ~= 'COMMENTED') then
      table.insert(posts, { author = login(r.author), body = body, time = gh.epoch(r.submittedAt), verdict = verdicts[r.state] })
    end
  end
  table.sort(posts, function(a, b) return a.time < b.time end)
  if #posts > 0 then add(('\n---\n\n## Conversation (%d)'):format(#posts)) end
  for _, post in ipairs(posts) do
    add(('\n### %s%s · %s\n'):format(post.author, post.verdict and (' ' .. post.verdict) or '', ago(post.time)))
    if post.body ~= '' then add(post.body) end
  end
  return lines
end

---Read a pull request (of `repo`, 'owner/name'), in a float.
---@param repo string
---@param number integer
function M.open(repo, number)
  task.run(function()
    vim.notify(('Loading #%d…'):format(number))
    local owner, name = gh.split(repo)
    local p = gh.query(QUERY, { owner = owner, name = name, number = number }).repository.pullRequest
    local lines = render(p)
    vim.cmd.echo('""')

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable, vim.bo[buf].filetype = false, 'markdown'
    local width = math.min(100, vim.o.columns - 8)
    local function place(height)
      return { relative = 'editor', row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2), width = width, height = height }
    end
    local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend('force', place(vim.o.lines - 6), {
      style = 'minimal',
      title = (' %s#%d '):format(name, number),
      footer = ' q close · o GitHub ',
      footer_pos = 'right',
    }))
    local wo = vim.wo[win][0]
    wo.wrap, wo.linebreak, wo.conceallevel, wo.concealcursor = true, true, 2, 'nc'
    -- As tall as its text, wrapped and concealed (or as the screen allows).
    vim.api.nvim_win_set_config(win, place(math.min(vim.api.nvim_win_text_height(win, {}).all, vim.o.lines - 6)))
    vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buf = buf, desc = 'Close' })
    vim.keymap.set('n', 'o', function() vim.ui.open(p.url) end, { buf = buf, desc = 'Open it on GitHub' })
  end)
end

return M
