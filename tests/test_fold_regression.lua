-- Test 3: /fold // /unfold // /unfoldall regression through scopes.dispatch
-- (drives the refactored path directly; UI typing is unreliable headlessly)
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local scopes = require("core.execution_panel.scopes")

local file = vim.fn.stdpath("run") .. "/fold_test.lua"
local body = { "function outer()", "  local a = 1" }
for i = 1, 20 do body[#body + 1] = "  a = a + " .. i end
body[#body + 1] = "  if a > 0 then"
for i = 1, 10 do body[#body + 1] = "    a = a - " .. i end
body[#body + 1] = "  end"
body[#body + 1] = "end"
local f = io.open(file, "w"); f:write(table.concat(body, "\n") .. "\n"); f:close()

vim.cmd("edit " .. vim.fn.fnameescape(file))
vim.cmd("normal! 5G")  -- inside outer(), before the if-block
local win = vim.api.nvim_get_current_win()
local bufnr = vim.api.nvim_get_current_buf()

-- minimal panel ctx: dispatch only needs state.origin.pos and state.prev_win
local st = { origin = { pos = { 5 } }, prev_win = win }
scopes.init({
  state = st,
  set_dropdown = function() end,
  set_dropdown_height = function() end,
})

-- /fold at line 5: innermost indent scope = outer() body (lines 2..35)
scopes.dispatch("fold", win, bufnr)
if vim.fn.foldclosed(2) ~= 2 then
  fail("/fold: expected closed fold at line 2, got " .. tostring(vim.fn.foldclosed(2))); return
end
if vim.fn.foldclosed(24) ~= 2 then
  fail("/fold: if-block at 24 should be inside the outer fold (nested foldclosed=" ..
    tostring(vim.fn.foldclosed(24)) .. ")"); return
end

-- /unfold: opens the innermost closed fold enclosing the cursor
vim.cmd("normal! 5G")
scopes.dispatch("unfold", win, bufnr)
-- outer body fold opened -> line 2 visible again
if vim.fn.foldclosed(2) ~= -1 then
  fail("/unfold: outer fold still closed"); return
end

-- cursor inside the if-block: /fold folds just the if scope
st.origin.pos = { 25 }
scopes.dispatch("fold", win, bufnr)
if vim.fn.foldclosed(24) ~= 24 then
  fail("/fold at if-block: expected fold at 24, got " .. tostring(vim.fn.foldclosed(24))); return
end
-- outer body must NOT be folded by this (no ascending past the innermost scope)
if vim.fn.foldclosed(2) ~= -1 then
  fail("/fold at if-block incorrectly folded the outer scope"); return
end

-- /unfoldall clears everything and restores fold settings
scopes.dispatch("unfoldall", win, bufnr)
if vim.fn.foldclosed(24) ~= -1 then fail("/unfoldall left folds"); return end
if vim.wo[win].foldmethod ~= "manual" and vim.wo[win].foldmethod ~= "indent" then
  -- restore_fold_opts puts back the pre-panel value (default from config)
  fail("foldmethod after unfoldall: " .. vim.wo[win].foldmethod); return
end

-- foldall: every indent scope folds
scopes.dispatch("foldall", win, bufnr)
if vim.fn.foldclosed(2) ~= 2 then fail("/foldall: outer not folded"); return end
-- the closed outer fold makes foldclosed(24) report 2; assert the nested
-- if-block fold exists via foldlevel (nested manual fold -> level 2)
if vim.fn.foldlevel(24) < 2 then fail("/foldall: if-block not folded"); return end

pass()
