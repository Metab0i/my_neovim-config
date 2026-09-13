-- Test 1: modules load, navhistory ring = 15, keymaps present
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

for _, mod in ipairs({ "core.scope_engine", "core.navhistory", "ui.context",
                       "core.execution_panel", "ui.winbar", "ui.statusline" }) do
  local ok, m = pcall(require, mod)
  if not ok then fail("require('" .. mod .. "') failed: " .. tostring(m)); return end
end

local eng = require("core.scope_engine")
if type(eng.compute_indent_ranges) ~= "function"
    or type(eng.find_innermost) ~= "function"
    or type(eng.fetch_document_symbols) ~= "function"
    or type(eng.FOLDABLE) ~= "table" then
  fail("scope_engine API incomplete"); return
end
if not eng.FOLDABLE[12] then fail("FOLDABLE missing Function kind"); return end

-- find_innermost sanity: deepest indent wins, ties -> latest opener
local ranges = {
  { opener = 1,  end_ = 100, indent = 0 },
  { opener = 5,  end_ = 50,  indent = 2 },
  { opener = 10, end_ = 20,  indent = 4 },
}
local best = eng.find_innermost(ranges, 15)
if not best or best.opener ~= 10 then fail("find_innermost deepest failed"); return end
if eng.find_innermost(ranges, 200) ~= nil then fail("find_innermost outside failed"); return end

-- navhistory ring: 20 moves in a real file -> back stops after 15
local dir = vim.fn.stdpath("run")
local file = dir .. "/navhist_test.lua"
local f = io.open(file, "w")
for i = 1, 25 do f:write("line" .. i .. "\n") end
f:close()
vim.cmd("edit " .. vim.fn.fnameescape(file))
local nav = require("core.navhistory")
nav._reset()
-- NOTE: this headless harness does not deliver CursorMoved autocommands,
-- so drive the recorder directly (still exercises the full ring/back/forward logic)
for i = 1, 20 do
  vim.cmd("normal! " .. i .. "G")
  nav._record()
end
local st = nav._state()
if #st.back > 15 then fail("back ring exceeded 15: " .. #st.back); return end
-- 20 moves: current = line 20, back holds 15 (lines 19..5); the 4 oldest trimmed
nav.back()
local st2 = nav._state()
if st2.current.line ~= 19 then fail("back() did not land on line 19: " .. tostring(st2.current and st2.current.line)); return end
for _ = 1, 14 do nav.back() end
local st3 = nav._state()
if #st3.back ~= 0 then fail("back ring not exhausted after 15 steps: " .. #st3.back); return end
if st3.current.line ~= 5 then fail("oldest retained entry should be line 5, got " .. tostring(st3.current and st3.current.line)); return end
nav.forward()
if nav._state().current.line ~= 6 then fail("forward() broken"); return end

-- keymaps exist
local maps = vim.api.nvim_get_keymap("n")
local found = { mleft = false, mright = false }
for _, m in ipairs(maps) do
  if m.lhs == "\27[1;3D" or m.lhs == "<M-Left>" then found.mleft = true end
  if m.lhs == "\27[1;3C" or m.lhs == "<M-Right>" then found.mright = true end
end
if not (found.mleft and found.mright) then fail("M-Left/M-Right mappings missing"); return end

pass()
