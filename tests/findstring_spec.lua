-- findstring_spec.lua — tests for core/execution_panel/findstring.lua
-- Exercises the empty-pattern path and the async cross-file search via a mock ctx.
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local findstring = require("core.execution_panel.findstring")

-- temp dir with a couple of files; open one in the current window
local dir = vim.fn.stdpath("run") .. "/findstr_test"
os.execute("rm -rf " .. vim.fn.shellescape(dir))
vim.fn.mkdir(dir, "p")
local fa = io.open(dir .. "/a.txt", "w"); fa:write("needle here\nneedle again\n"); fa:close()
local fb = io.open(dir .. "/b.txt", "w"); fb:write("nothing to find\n"); fb:close()
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))

local state = {
  open = true,
  prev_win = vim.api.nvim_get_current_win(),
  target_buf = vim.api.nvim_get_current_buf(),
  origin = nil,
  fstr = { active = false, pattern = "", results = {}, selection = 1,
           match_list = {}, match_idx = 1, preview_abs = nil, _timer = nil, _match_id = nil },
}
local hint_fstr, status = false, nil
local ctx = {
  state = state,
  render_hint_fstr = function() hint_fstr = true end,
  render_status = function(s) status = s end,
  set_dropdown_height = function() end,
  set_dropdown = function() end,
}
findstring.init(ctx)

-- 1. empty /fstr -> hint, no search
findstring.refresh("/fstr")
if not hint_fstr then fail("empty pattern did not render hint"); return end
if state.fstr.pattern ~= "" then fail("pattern should be empty"); return end

-- 2. /fstr <pattern> -> sets pattern and asynchronously populates results
if vim.fn.executable("rg") == 0 and vim.fn.executable("grep") == 0 then
  io.stdout:write("(no rg/grep; skipping async search assertions)\n"); io.stdout:flush()
  pass(); return
end
findstring.refresh("/fstr needle")
if state.fstr.pattern ~= "needle" then fail("pattern ~= needle: " .. state.fstr.pattern); return end
if not vim.wait(4000, function() return #state.fstr.results > 0 end) then
  fail("async search returned no results; status=" .. tostring(status)); return
end
local found = false
for _, r in ipairs(state.fstr.results) do
  if r.abs:find("a%.txt$") then
    found = true
    if r.count ~= 2 then fail("a.txt needle count ~= 2: " .. tostring(r.count)); return end
  end
end
if not found then fail("a.txt (with needle) not in results: " .. vim.inspect(state.fstr.results)); return end

-- 3. results are sorted: higher count first
if #state.fstr.results >= 2 then
  if state.fstr.results[1].count < state.fstr.results[2].count then
    fail("results not sorted by descending count"); return
  end
end

os.execute("rm -rf " .. vim.fn.shellescape(dir))
pass()