local gd = require("gitdiff")
local ns = vim.api.nvim_get_namespaces()["gitdiff"]
local failures = {}
local function check(c, m) if not c then failures[#failures + 1] = m end end

-- line_hl_group is a plain, always-supported extmark option (no 0.12-only
-- rejection dance like end_col=-1): it accepts a highlight group and fills the
-- whole line. Verify it round-trips through nvim_buf_get_extmarks details.
local buf0 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf0, 0, -1, false, { "hello" })
local ok = pcall(vim.api.nvim_buf_set_extmark, buf0, ns, 0, 0, {
  hl_group = "GitDiffAddBg", line_hl_group = "GitDiffAddBg", priority = 200,
})
check(ok, "line_hl_group extmark should be accepted")

-- Empty added line + trailing text: HEAD x1,x2; buffer x1, "", x2extra
-- With line_hl_group the empty added line now ALSO gets the full-width tint
-- (a deliberate behavior change vs the old text-only range).
vim.cmd("edit! " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/b.txt"))
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x1", "", "x2extra" })
vim.cmd("GitDiff")
check(gd._state() == true, "failed to enable")
local adds = {}
for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local d = mm[4]
  if d.line_hl_group == "GitDiffAddBg" then adds[#adds + 1] = mm[2] end
end
check(#adds == 2, "expected 2 added-line tints (empty + x2extra), got " .. #adds)
local by_row = {}
for _, r in ipairs(adds) do by_row[r] = true end
check(by_row[1] == true, "expected a tint on the empty added line (row 1)")
check(by_row[2] == true, "expected a tint on x2extra (row 2)")
vim.cmd("GitDiff")

-- Multibyte removed line: virt_lines pad chunk must be placed without error and
-- carry the delete-bg hl (padding uses strdisplaywidth, so no overflow error).
-- a.txt HEAD l1..l5; buffer l1,l2,l3 -> l4/l5 removed.
vim.cmd("edit! " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/a.txt"))
buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3" })
vim.cmd("GitDiff")
local pad_ok, text_chunk, pad_chunk = false, nil, nil
for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local d = mm[4]
  if d.virt_lines then
    pad_ok = true
    local line_chunks = d.virt_lines[1]
    if line_chunks then
      text_chunk = line_chunks[1]
      pad_chunk = line_chunks[2]
    end
  end
end
check(pad_ok, "expected removed-line virt_lines with a full-width pad chunk")
check(text_chunk and text_chunk[2] == "GitDiffDeleteBg", "virt_line text chunk should use GitDiffDeleteBg")
check(pad_chunk and pad_chunk[2] == "GitDiffDeleteBg", "virt_line pad chunk should use GitDiffDeleteBg")
vim.cmd("GitDiff")

if #failures == 0 then
  io.stdout:write("TEST_RESULT: PASS\n")
else
  io.stdout:write("TEST_RESULT: FAIL: " .. table.concat(failures, " | ") .. "\n")
end
io.stdout:flush()