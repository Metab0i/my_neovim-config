-- gitdiff supplementary tests: FocusGained refresh + WinEnter/split path
local gd = require("gitdiff")
local ns = vim.api.nvim_get_namespaces()["gitdiff"]
local failures = {}
local function check(c, m) if not c then failures[#failures + 1] = m end end
local function plus_rows(buf)
  local rows = {}
  for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mm[4].virt_text and mm[4].virt_text[1] and mm[4].virt_text[1][1]:find("+") then rows[#rows + 1] = mm[2] end
  end
  table.sort(rows)
  return rows
end

vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/a.txt"))
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3" })
vim.cmd("GitDiff")
check(#plus_rows(buf) == 0, "setup: expected no + rows for pure deletion")
gd._schedule(buf)
vim.wait(200, function() return false end)

-- FocusGained while ON: clears caches and recomputes; marks must remain correct.
vim.api.nvim_exec_autocmds("FocusGained", { group = "GitDiff" })
vim.wait(100, function() return false end)
local marks_after = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
local has_virt = false
for _, mm in ipairs(marks_after) do if mm[4].virt_lines then has_virt = true end end
check(has_virt, "FocusGained: removal marks should persist after refresh")

-- Split: open a window, enter it; the new window's buffer gets overlay via WinEnter
edit_ok = pcall(function() vim.cmd("split " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/b.txt")) end)
check(edit_ok, "split failed")
local bbuf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(bbuf, 0, -1, false, { "x1", "x2", "x3" })
gd._schedule(bbuf)
vim.wait(200, function() return false end)
-- b HEAD is x1,x2; buffer x1,x2,x3 -> addition of x3 on row 2
local rows = plus_rows(bbuf)
check(#rows == 1 and rows[1] == 2, "split/WinEnter: expected + on row 2, got " .. vim.inspect(rows))

vim.cmd("GitDiff") -- toggle off; clear_all must sweep both buffers
check(not gd._state(), "toggle off")
for _, b in ipairs({ buf, bbuf }) do
  check(#vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}) == 0,
    "buffer " .. b .. " marks not cleared after disable")
end

if #failures == 0 then
  io.stdout:write("TEST_RESULT: PASS\n")
else
  io.stdout:write("TEST_RESULT: FAIL: " .. table.concat(failures, " | ") .. "\n")
end
io.stdout:flush()
