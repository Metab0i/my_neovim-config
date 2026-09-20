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

-- The +/- accents must be bold and brighter than the body tint they sit on.
local addhl = vim.api.nvim_get_hl(0, { name = "GitDiffAdd", link = false })
local delhl = vim.api.nvim_get_hl(0, { name = "GitDiffDelete", link = false })
check(addhl.bold == true, "GitDiffAdd accent should be bold")
check(delhl.bold == true, "GitDiffDelete accent should be bold")
local function lum(c)
  if not c then return 0 end
  local r, g, b = math.floor(c / 0x10000) % 0x100, math.floor(c / 0x100) % 0x100, c % 0x100
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end
check(lum(delhl.fg) > lum(delbg.fg),
  "GitDiffDelete accent fg should be brighter than the GitDiffDeleteBg body fg")
-- ...and the glyph's own background segment must be brighter than the line tint.
check(lum(addhl.bg) > lum(addbg.bg),
  "GitDiffAdd accent segment bg should be brighter than the GitDiffAddBg line tint")
check(lum(delhl.bg) > lum(delbg.bg),
  "GitDiffDelete accent segment bg should be brighter than the GitDiffDeleteBg line tint")

-- b.txt HEAD x1,x2; add x3 -> an added line. Expect ONE extmark carrying the
-- bold green "+" accent (overlay virtual text) AND the full-line-width tint via
-- `line_hl_group` (line_hl_group fills the whole line incl. the empty space to
-- the right).
vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/b.txt"))
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x1", "x2", "x3" })
vim.cmd("GitDiff")
check(gd._state() == true, "failed to enable")

local add_mark = nil
for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local d = mm[4]
  if d.virt_text and d.virt_text[1] and d.virt_text[1][1]:find("+") then add_mark = d end
end
check(add_mark ~= nil, "expected the inline + marker extmark")
if add_mark then
  check(add_mark.virt_text[1][2] == "GitDiffAdd", "inline + should use the bold GitDiffAdd accent hl")
  check(add_mark.virt_text_pos == "overlay", "inline + should use virt_text_pos=overlay")
  check(add_mark.line_hl_group == "GitDiffAddBg",
    "inline + should carry line_hl_group=GitDiffAddBg (full-line tint), got " .. tostring(add_mark.line_hl_group))
  check(add_mark.priority == 200, "tint should have priority 200, got " .. tostring(add_mark.priority))
end

-- Removed lines (deletion in a.txt): a bold "-" accent chunk, the red-tinted
-- body text chunk, and a whitespace pad chunk in the tint hl group.
vim.cmd("GitDiff") -- off
vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_FIXTURE_DIR .. "/a.txt"))
buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3" })
vim.cmd("GitDiff")
local virt_accent_hl, virt_text_hl, virt_pad_hl = nil, nil, nil
for _, mm in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mm[4].virt_lines then
    local line_chunks = mm[4].virt_lines[1]
    if line_chunks and line_chunks[1] then virt_accent_hl = line_chunks[1][2] end
    if line_chunks and line_chunks[2] then virt_text_hl = line_chunks[2][2] end
    if line_chunks and line_chunks[3] then virt_pad_hl = line_chunks[3][2] end
  end
end
check(virt_accent_hl == "GitDiffDelete", "removal accent chunk hl expected GitDiffDelete, got " .. tostring(virt_accent_hl))
check(virt_text_hl == "GitDiffDeleteBg", "removal text chunk hl expected GitDiffDeleteBg, got " .. tostring(virt_text_hl))
check(virt_pad_hl == "GitDiffDeleteBg", "removal pad chunk hl expected GitDiffDeleteBg, got " .. tostring(virt_pad_hl))

-- ColorScheme re-derives the new groups (should not error and keep colors).
vim.api.nvim_exec_autocmds("ColorScheme", { group = "GitDiff" })
local addbg2 = vim.api.nvim_get_hl(0, { name = "GitDiffAddBg", link = false })
check(hex(addbg2.bg) == "#6b5a00", "after ColorScheme GitDiffAddBg.bg should persist")
-- Re-deriving without `hi clear` must not keep brightening the accent.
local addhl2 = vim.api.nvim_get_hl(0, { name = "GitDiffAdd", link = false })
local delhl2 = vim.api.nvim_get_hl(0, { name = "GitDiffDelete", link = false })
check(addhl2.fg == addhl.fg, "GitDiffAdd accent must be idempotent across ColorScheme")
check(delhl2.fg == delhl.fg, "GitDiffDelete accent must be idempotent across ColorScheme")

vim.cmd("GitDiff") -- cleanup

if #failures == 0 then
  io.stdout:write("TEST_RESULT: PASS\n")
else
  io.stdout:write("TEST_RESULT: FAIL: " .. table.concat(failures, " | ") .. "\n")
end
io.stdout:flush()