-- gitdiff robustness tests: glob-magic filenames, new-dir walk-up, repo_failed self-heal
local gd = require("gitdiff")
local ns = vim.api.nvim_get_namespaces()["gitdiff"]
local failures = {}
local function check(c, m) if not c then failures[#failures + 1] = m end end

local function plus_rows(buf)
  local rows = {}
  for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mm[4].sign_text and mm[4].sign_text:find("+") then rows[#rows + 1] = mm[2] end
  end
  table.sort(rows)
  return rows
end
local function all_rows(buf)
  local plus = plus_rows(buf)
  local virt = false
  for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mm[4].virt_lines then virt = true end
  end
  return plus, virt
end

-- R1: filename with glob magic (we[ir]d.txt). It IS tracked in HEAD with
-- lines p,q. Changing the second line must yield exactly ONE addition (row 1)
-- and no removals -- a pre-fix regression would pattern-match the pathspec to
-- zero files and classify the tracked buffer as untracked (all-added).
vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/we[ir]d.txt"))
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "p", "q2" })
vim.cmd("GitDiff")
check(gd._state() == true, "R1: failed to enable on glob-magic file")
local plus, virt = all_rows(buf)
check(#plus == 1 and plus[1] == 1, "R1: expected single + on row 1 (tracked), got " .. vim.inspect(plus))
check(virt, "R1: expected a - removal mark for the changed line")
vim.cmd("GitDiff") -- disable

-- R2: brand-new file in a brand-new directory (sub2/ does not exist).
-- The parent-dir walk-up must find the repo root, classify untracked, and
-- render every line as an addition (not "not a git repo").
vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/sub2/new.txt"))
local buf2 = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "n1", "n2" })
vim.cmd("GitDiff")
check(gd._state() == true, "R2: walk-up failed; new-dir file should enable (untracked)")
plus = plus_rows(buf2)
check(#plus == 2 and plus[1] == 0 and plus[2] == 1, "R2: expected + on all lines, got " .. vim.inspect(plus))
vim.cmd("GitDiff")

-- R3: self-heal of the negative repo cache. c.txt is currently outside any
-- repo; toggle must refuse and record repo_failed. Then git-init a repo
-- there; a second toggle (no buffer close/reopen) must now enable, because
-- toggle() clears the cached failure first.
vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_NON_GIT_DIR .. "/c.txt"))
local buf3 = vim.api.nvim_get_current_buf()
vim.cmd("GitDiff")
check(gd._state() == false, "R3a: should stay off in a non-git dir")
vim.system({ "git", "-C", vim.env.TEST_NON_GIT_DIR, "init", "-q" }):wait(3000)
vim.system({ "git", "-C", vim.env.TEST_NON_GIT_DIR, "-c", "user.name=t", "-c",
  "user.email=t@e", "add", "--all" }):wait(3000)
vim.system({ "git", "-C", vim.env.TEST_NON_GIT_DIR, "-c", "user.name=t", "-c",
  "user.email=t@e", "commit", "-qm", "late init" }):wait(3000)
vim.cmd("GitDiff")
check(gd._state() == true, "R3b: retry after git init should self-heal and enable")
vim.cmd("GitDiff")

-- cleanup: drop the throwaway repo so the fixture is reusable
vim.system({ "rm", "-rf", vim.env.TEST_NON_GIT_DIR .. "/.git" }):wait(3000)

if #failures == 0 then
  io.stdout:write("TEST_RESULT: PASS\n")
else
  io.stdout:write("TEST_RESULT: FAIL: " .. table.concat(failures, " | ") .. "\n")
end
io.stdout:flush()
