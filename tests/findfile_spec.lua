-- findfile_spec.lua — tests for core/execution_panel/findfile.lua fuzzy filtering
-- Exercises the fuzzy ranking + selection logic through a minimal mock ctx.
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local findfile = require("core.execution_panel.findfile")

local dir = vim.fn.stdpath("run") .. "/findfile_test"
os.execute("rm -rf " .. vim.fn.shellescape(dir))
vim.fn.mkdir(dir, "p")
local files = {}
for _, n in ipairs({ "alpha.lua", "beta.txt", "alphabeta.lua", "gamma.py", "delta.lua" }) do
  local fh = io.open(dir .. "/" .. n, "w"); fh:write("x\n"); fh:close()
  files[#files + 1] = vim.fs.normalize(dir .. "/" .. n)
end

local state = {
  file_list = files, root = dir, cwd = dir, query = "",
  suggestions = {}, selection = 1,
}
local rendered = { lines = nil, sel = nil }
local ctx = {
  state = state,
  set_dropdown_height = function() end,
  set_dropdown = function(lines, sel) rendered.lines = lines; rendered.sel = sel end,
}
findfile.init(ctx)

-- 1. basename match ranked above path-only match
findfile.refresh("alpha")
if #state.suggestions == 0 then fail("no suggestions for alpha"); return end
-- alpha.lua and alphabeta.lua have basename matches; delta/others path matches
if #state.suggestions < 2 then fail("expected >=2 suggestions for alpha"); return end
-- the two basename matches sort first
local first_disp = state.suggestions[1].disp:lower()
if not (first_disp:find("alpha%.lua$") or first_disp:find("alphabeta%.lua$")) then
  fail("top suggestion should be a basename match, got '" .. first_disp .. "'"); return
end

-- 2. exact file query
findfile.refresh("beta.txt")
if #state.suggestions == 0 then fail("no suggestion for beta.txt"); return end
if not state.suggestions[1].disp:find("beta%.txt$") then fail("beta.txt not top"); return end

-- 3. no matches -> empty, selection clamped to 1
findfile.refresh("zzzqqq")
if #state.suggestions ~= 0 then fail("no-match query should be empty"); return end
if state.selection ~= 1 then fail("selection not clamped to 1"); return end

-- 4. move_selection wraps around
findfile.refresh("alpha")
local n = #state.suggestions
if n < 2 then fail("need >=2 for wrap test"); return end
state.selection = 1
findfile.move_selection(1)
if state.selection ~= 2 then fail("move_selection(+1) -> 2, got " .. state.selection); return end
findfile.move_selection(-1)
if state.selection ~= 1 then fail("move_selection(-1) -> 1, got " .. state.selection); return end
-- wrap: from 1 going up -> n
state.selection = 1
findfile.move_selection(-1)
if state.selection ~= n then fail("wrap up -> " .. n .. ", got " .. state.selection); return end

-- 5. render produced dropdown lines equal to the suggestions
findfile.refresh("alpha")
if rendered.lines == nil then fail("render did not call set_dropdown"); return end
if #rendered.lines ~= #state.suggestions then fail("dropdown line count mismatch"); return end

-- 6. open_selection edits the selected file
local s2 = state.suggestions[1]
findfile.refresh("alpha")
ctx.close = function() end
findfile.open_selection()
local cur = vim.fn.expand("%:p")
if not vim.fs.normalize(cur):find("findfile_test") then
  fail("open_selection did not open a findfile_test file: " .. cur); return
end

os.execute("rm -rf " .. vim.fn.shellescape(dir))
pass()