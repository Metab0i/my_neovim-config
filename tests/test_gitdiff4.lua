-- gitdiff tint tests: GitDiffAddBg (added lines) + GitDiffDeleteBg (removed lines)
local gd = require("gitdiff")
local ns = vim.api.nvim_get_namespaces()["gitdiff"]
local failures = {}
local function check(c, m) if not c then failures[#failures + 1] = m end end
local function hex(c) return c and string.format("#%06x", c) or nil end

-- The two highlight groups exist with the right colors.
local addbg = vim.api.nvim_get_hl(0, { name = "GitDiffAddBg", link = false })
local delbg = vim.api.nvim_get_hl(0, { name = "GitDiffDeleteBg", link = false })
check(hex(addbg.bg) == "#6b5a00", "GitDiffAddBg.bg expected #6b5a00, got " .. tostring(hex(addbg.bg)))
check(hex(delbg.bg) == "#6a1a1a", "GitDiffDeleteBg.bg expected #6a1a1a, got " .. tostring(hex(delbg.bg)))
check(delbg.fg ~= nil, "GitDiffDeleteBg should keep a foreground (red - text)")

-- b.txt HEAD x1,x2; add x3 -> an added line. Expect ONE extmark carrying the
-- green "+" sign AND the full-line-width tint via `line_hl_group`
-- (line_hl_group fills the whole line incl. the empty space to the right).
vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/b.txt"))
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x1", "x2", "x3" })
vim.cmd("GitDiff")
check(gd._state() == true, "failed to enable")

local sign_mark = nil
for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local d = mm[4]
  if d.sign_text and d.sign_text:find("+") then sign_mark = d end
end
check(sign_mark ~= nil, "expected the green + sign extmark")
if sign_mark then
  check(sign_mark.sign_hl_group == "GitDiffAdd", "sign should use GitDiffAdd hl")
  check(sign_mark.line_hl_group == "GitDiffAddBg",
    "sign should carry line_hl_group=GitDiffAddBg (full-line tint), got " .. tostring(sign_mark.line_hl_group))
  check(sign_mark.priority == 200, "tint should have priority 200, got " .. tostring(sign_mark.priority))
end

-- Removed lines (deletion in a.txt): red tinted virtual line chunk, padded to
-- the full line width with a second whitespace chunk in the same hl group.
vim.cmd("GitDiff") -- off
vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/a.txt"))
buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3" })
vim.cmd("GitDiff")
local virt_chunk_hl, virt_pad_hl = nil, nil
for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mm[4].virt_lines then
    local line_chunks = mm[4].virt_lines[1]
    if line_chunks and line_chunks[1] then virt_chunk_hl = line_chunks[1][2] end
    if line_chunks and line_chunks[2] then virt_pad_hl = line_chunks[2][2] end
  end
end
check(virt_chunk_hl == "GitDiffDeleteBg", "removal virt_line text chunk hl expected GitDiffDeleteBg, got " .. tostring(virt_chunk_hl))
check(virt_pad_hl == "GitDiffDeleteBg", "removal virt_line pad chunk hl expected GitDiffDeleteBg, got " .. tostring(virt_pad_hl))

-- ColorScheme re-derives the new groups (should not error and keep colors).
vim.api.nvim_exec_autocmds("ColorScheme", { group = "GitDiff" })
local addbg2 = vim.api.nvim_get_hl(0, { name = "GitDiffAddBg", link = false })
check(hex(addbg2.bg) == "#6b5a00", "after ColorScheme GitDiffAddBg.bg should persist")

vim.cmd("GitDiff") -- cleanup

if #failures == 0 then
  io.stdout:write("TEST_RESULT: PASS\n")
else
  io.stdout:write("TEST_RESULT: FAIL: " .. table.concat(failures, " | ") .. "\n")
end
io.stdout:flush()