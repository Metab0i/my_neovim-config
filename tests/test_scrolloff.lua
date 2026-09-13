-- Test 4: scrolloff=1 keeps the cursor off the header-covered top row
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

-- 1. config sets scrolloff
if vim.o.scrolloff ~= 1 then fail("scrolloff is " .. tostring(vim.o.scrolloff) .. ", expected 1"); return end

vim.o.lines = 15
vim.o.columns = 80

local ctx = require("ui.context")
local file = vim.fn.stdpath("run") .. "/scroll_test.lua"
local body = { "function deep()" }
for i = 1, 60 do body[#body + 1] = "  x = x + " .. i end
body[#body + 1] = "end"
local f = io.open(file, "w"); f:write(table.concat(body, "\n") .. "\n"); f:close()
vim.cmd("edit " .. vim.fn.fnameescape(file))
local w0 = vim.api.nvim_get_current_win()

local function has_float()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg.relative == "win" then return true end
  end
  return false
end

-- 2. deep inside the scope: header shows, cursor is NOT on the covered row
vim.cmd("normal! 40G")
ctx._recompute(w0)
if not has_float() then fail("header not shown deep inside scope"); return end
local cur, top = vim.fn.line("."), vim.fn.line("w0")
if cur == top then fail("cursor sits on covered top row under an active header"); return end

-- 3. scroll up with k: while a header would be shown (opener=1 < w0), the
--    cursor must stay below w0. Loop bounded above file top (w0==1 is header-free).
local steps = 0
while steps < 200 do
  vim.cmd("normal! k")
  steps = steps + 1
  top = vim.fn.line("w0")
  if top == 1 then break end  -- file top: header-free, cursor may be on w0
  -- inside the function body (opener line 1 < w0) => invariant must hold
  cur = vim.fn.line(".")
  if cur < top then fail("cursor above topline??"); return end
  if cur == top then
    fail(("cursor reached covered row w0=%d at cursor line %d (scrolloff not honored)")
      :format(top, cur)); return
  end
end
if steps >= 200 then fail("k loop never reached file top"); return end

-- 4. control: with scrolloff=0 the cursor CAN reach w0 (proves scrolloff does the work)
vim.o.scrolloff = 0
vim.cmd("normal! 40G")
for _ = 1, 60 do
  vim.cmd("normal! k")
  if vim.fn.line("w0") == 1 then break end
end
if vim.fn.line(".") ~= vim.fn.line("w0") then
  fail("control run failed: expected cursor on w0 with scrolloff=0")
  vim.o.scrolloff = 1
  return
end
vim.o.scrolloff = 1

pass()
