-- peek_spec.lua — behavior tests for lua/peek.lua (public peek_row placement
-- math + keymap wiring).
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local peek = require("peek")

-- 1. peek_row placement math (public API, pure, no LSP required)
-- cursor low in the viewport with room above -> place above the cursor
local r1 = peek.peek_row(20, 1, 40, 10)
if r1 ~= 9 then fail("peek_row(20,1,40,10): space above -> " .. tostring(r1) .. " ~= 9"); return end
-- cursor near top, room below -> place below the cursor
local r2 = peek.peek_row(5, 1, 40, 10)
if r2 ~= 6 then fail("peek_row(5,1,40,10): space below -> " .. tostring(r2) .. " ~= 6"); return end
-- no room either side (tiny window) -> clamp to w0
local r3 = peek.peek_row(2, 1, 10, 10)
if r3 ~= 1 then fail("peek_row(2,1,10,10): clamp -> " .. tostring(r3) .. " ~= 1"); return end
-- boundary: exactly height+1 above -> place above
local r4 = peek.peek_row(12, 1, 40, 10)
if r4 ~= 1 then fail("peek_row(12,1,40,10): exact boundary -> " .. tostring(r4) .. " ~= 1"); return end
-- boundary: exactly height+1 below (and not enough above) -> place below
local r5 = peek.peek_row(30, 25, 41, 10)
if r5 ~= 31 then fail("peek_row(30,25,41,10): below boundary -> " .. tostring(r5) .. " ~= 31"); return end

-- 2. the toggle keymap exists (<leader> = " " so lhs is " pd")
local found = false
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
  if m.lhs == " pd" then found = true end
end
if not found then fail("<leader>pd peek mapping missing"); return end

pass()
