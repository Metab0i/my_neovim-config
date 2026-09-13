-- gitdiff test suite (run via the neovim-test harness against the real config)
local gd = require("gitdiff")
local ns = vim.api.nvim_get_namespaces()["gitdiff"]

local failures = {}
local function check(cond, msg)
  if not cond then failures[#failures + 1] = msg end
end

local function marks(bufnr)
  local list = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local plus, removed = {}, {}
  for _, m in ipairs(list) do
    local row, det = m[2], m[4]
    if det.sign_text and det.sign_text:find("+") then
      plus[#plus + 1] = row
    end
    if det.virt_lines then
      local texts = {}
      for _, line in ipairs(det.virt_lines) do texts[#texts + 1] = line[1][1] end
      removed[#removed + 1] = { row = row, above = det.virt_lines_above, lines = texts }
    end
  end
  table.sort(plus)
  return plus, removed
end

local function eqrows(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function curbuf() return vim.api.nvim_get_current_buf() end
local function edit(f) vim.cmd("edit " .. vim.fn.fnameescape(f)) end
-- Headless nvim never fires TextChanged/TextChangedI (gated on a real redraw
-- cycle), so programmatic edits drive the module's own recompute entry point
-- (gd._schedule, the same function the TextChanged autocmd calls). The
-- autocmd wiring itself is asserted separately in S0.
local function setbuf(lines)
  vim.api.nvim_buf_set_lines(curbuf(), 0, -1, false, lines)
  gd._schedule(curbuf())
  vim.wait(200, function() return false end) -- let the 40ms debounce flush
end

-- --------------------------------------------------- S0: autocmd wiring exists
local ac = vim.api.nvim_get_autocmds({ group = "GitDiff" })
local have = {}
for _, a in ipairs(ac) do have[a.event] = true end
for _, ev in ipairs({ "BufEnter", "WinEnter", "TextChanged", "TextChangedI", "FocusGained", "ColorScheme" }) do
  check(have[ev], "S0: missing " .. ev .. " autocmd")
end

-- ----------------------------------------------------------- S1: mixed edits
edit(vim.env.TEST_FIXTURE_DIR .. "/a.txt")
local a_buf = curbuf()
setbuf({ "l1", "l3X", "l4", "new", "l5" }) -- delete l2, modify l3, add "new"
vim.cmd("GitDiff")
check(gd._state() == true, "S1: toggle did not enable")
check(vim.go.signcolumn == "yes", "S1: signcolumn not forced to yes")
local plus, removed = marks(a_buf)
check(eqrows(plus, { 1, 3 }), "S1: expected + signs on rows 1,3 got " .. vim.inspect(plus))
check(#removed == 1, "S1: expected 1 removal run got " .. #removed)
if #removed == 1 then
  local r = removed[1]
  check(r.row == 1 and r.above == true, "S1: removal run misplaced " .. vim.inspect(r))
  check(r.lines[1] == "-l2" and r.lines[2] == "-l3", "S1: removal chunks " .. vim.inspect(r.lines))
end

-- ------------------------------------------------------- S2: live recompute
setbuf({ "l1", "l3X", "l4", "l5" }) -- delete "new" (TextChanged -> debounced recompute)
plus = marks(a_buf)
check(eqrows(plus, { 1 }), "S2: live update expected + on row 1, got " .. vim.inspect(plus))

-- clean state: exact HEAD content -> no marks at all
setbuf({ "l1", "l2", "l3", "l4", "l5" })
plus, removed = marks(a_buf)
check(#plus == 0 and #removed == 0, "S2b: identical content should show no marks")

-- ------------------------------------------------------------- S3: toggle off
vim.cmd("GitDiff")
check(gd._state() == false, "S3: second toggle did not disable")
plus, removed = marks(a_buf)
check(#plus == 0 and #removed == 0, "S3: marks not cleared on disable")
check(vim.go.signcolumn == "auto", "S3: signcolumn not restored, got " .. vim.go.signcolumn)

-- --------------------------------------------- S4: global toggle follows files
-- a.txt differs from HEAD again (S2b left it identical -> zero marks)
setbuf({ "l1", "l3X", "l4", "l5" })
vim.cmd("GitDiff") -- enable while a.txt is current
local edit_a = {}
edit_a.plus, _ = marks(a_buf)
check(#edit_a.plus == 1, "S4: a.txt should have its own marks, got " .. vim.inspect(edit_a.plus))
edit(vim.env.TEST_FIXTURE_DIR .. "/b.txt")
local b_buf = curbuf()
setbuf({ "x1", "x3" }) -- modify x2
plus = marks(b_buf)
check(eqrows(plus, { 1 }), "S4: b.txt expected + on row 1, got " .. vim.inspect(plus))
-- a.txt keeps its overlay (marks from its BufEnter, still present)
check(#edit_a.plus == 1, "S4: a.txt lost its marks, got " .. vim.inspect(edit_a.plus))

-- ------------------------------------------------------------ S5: EOF removal
edit(vim.env.TEST_FIXTURE_DIR .. "/a.txt")
setbuf({ "l1", "l2", "l3", "l4" }) -- removed l5 at EOF
plus, removed = marks(a_buf)
check(#plus == 0, "S5: expected no additions, got " .. vim.inspect(plus))
check(#removed == 1, "S5: expected 1 removal run, got " .. #removed)
if #removed == 1 then
  local r = removed[1]
  check(r.row == 3 and r.above == false, "S5: EOF removal must sit BELOW last line " .. vim.inspect(r))
  check(r.lines[1] == "-l5", "S5: EOF removal text " .. vim.inspect(r.lines))
end

-- ------------------------------------------------------------ S6: BOF removal
setbuf({ "l3", "l4", "l5" }) -- removed l1,l2 at BOF
plus, removed = marks(a_buf)
check(#removed == 1, "S6: expected 1 removal run, got " .. #removed)
if #removed == 1 then
  local r = removed[1]
  check(r.row == 0 and r.above == true, "S6: BOF removal must sit above line 1 " .. vim.inspect(r))
  check(r.lines[1] == "-l1" and r.lines[2] == "-l2", "S6: BOF removal text " .. vim.inspect(r.lines))
end

-- ------------------------------------------------- S7: removals + addition mixed
setbuf({ "l1", "X", "l5" }) -- l2,l3,l4 replaced by X
-- xdiff orders the hunk as -l2 -l3 -l4 +X: one run above the added line
plus, removed = marks(a_buf)
check(eqrows(plus, { 1 }), "S7: expected + on row 1 (X), got " .. vim.inspect(plus))
check(#removed == 1, "S7: expected 1 removal run, got " .. vim.inspect(removed))
if #removed == 1 then
  local r = removed[1]
  check(r.row == 1 and r.above == true, "S7: removal must sit above X " .. vim.inspect(r))
  check(r.lines[1] == "-l2" and r.lines[2] == "-l3" and r.lines[3] == "-l4",
    "S7: removal text " .. vim.inspect(r.lines))
end

-- ------------------------------------------------------ S8: whole-file delete
setbuf({ "" }) -- empty buffer
plus, removed = marks(a_buf)
check(#removed == 1, "S8: expected 1 removal run, got " .. #removed)
if #removed == 1 then
  local r = removed[1]
  check(r.row == 0 and r.above == true, "S8: whole-file removal placement " .. vim.inspect(r))
  local n = 0
  for _ in ipairs(r.lines) do n = n + 1 end
  check(n == 5, "S8: expected 5 removed lines, got " .. n .. " " .. vim.inspect(r.lines))
end

-- ------------------------------------------------------- S9: untracked file
edit(vim.env.TEST_FIXTURE_DIR .. "/untracked.txt")
setbuf({ "z1", "z2", "z3" })
plus = marks(curbuf())
check(eqrows(plus, { 0, 1, 2 }), "S9: untracked expects + on every line, got " .. vim.inspect(plus))

-- ---------------------------------------------------- S10: non-git repository
vim.cmd("GitDiff") -- turn off first
check(gd._state() == false, "S10: pre-toggle-off failed")
edit(vim.env.TEST_NON_GIT_DIR .. "/c.txt")
vim.cmd("GitDiff")
check(gd._state() == false, "S10: toggle must stay off in a non-git dir")
plus = marks(curbuf())
check(#plus == 0, "S10: non-git buffer got marks")

-- ------------------------------------------------------------ S11: scratch buffer
gd._apply(999999) -- must not throw on an invalid buffer
vim.cmd("enew!") -- empty unnamed buffer; enabled is false -> no-op path
check(gd._state() == false, "S11: unexpected enabled state")

-- -------------------------------------------------------------- cleanup + verdict
if gd._state() then vim.cmd("GitDiff") end
if #failures == 0 then
  io.stdout:write("TEST_RESULT: PASS\n")
else
  io.stdout:write("TEST_RESULT: FAIL: " .. table.concat(failures, " | ") .. "\n")
end
io.stdout:flush()