-- Test 2: sticky scope header (indent fallback, per-window, clear-on-reveal, resize)
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

vim.o.lines = 20
vim.o.columns = 80

local ctx = require("ui.context")

local file = vim.fn.stdpath("run") .. "/sticky_test.lua"
local body = { "function alpha()", "  local x = 1" }
for i = 1, 30 do body[#body + 1] = "  x = x + " .. i end
body[#body + 1] = "end"
body[#body + 1] = ""
body[#body + 1] = "function beta()"
body[#body + 1] = "  local y = 2"
for i = 1, 30 do body[#body + 1] = "  y = y + " .. i end
body[#body + 1] = "end"
local f = io.open(file, "w"); f:write(table.concat(body, "\n") .. "\n"); f:close()

vim.cmd("edit " .. vim.fn.fnameescape(file))
local buf = vim.api.nvim_get_current_buf()
local w0 = vim.api.nvim_get_current_win()

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg.relative == "win" then
      out[#out + 1] = { win = w, cfg = cfg, buf = vim.api.nvim_win_get_buf(w) }
    end
  end
  return out
end

local function header_texts()
  local texts = {}
  for _, fl in ipairs(floats()) do
    local t = vim.api.nvim_buf_get_lines(fl.buf, 0, -1, false)[1] or ""
    texts[#texts + 1] = t
  end
  table.sort(texts)
  return texts
end

-- 1. deep inside alpha -> header shows "function alpha()"
vim.api.nvim_win_set_cursor(w0, { 25, 0 })
local okr, errr = pcall(ctx._recompute, w0)
if not okr then fail("recompute errored: " .. tostring(errr)); return end
ctx._schedule(w0)
if not vim.wait(1500, function() return #floats() == 1 end) then
  fail("header float did not appear deep inside alpha; floats=" .. #floats()); return
end
local fl = floats()[1]
if fl.cfg.row ~= 0 or fl.cfg.height ~= 1 then
  fail("float not pinned at row 0 / height 1: row=" .. tostring(fl.cfg.row) .. " h=" .. tostring(fl.cfg.height)); return
end
local texts = header_texts()
if texts[1] ~= "function alpha()" then fail("header text wrong: '" .. tostring(texts[1]) .. "'"); return end

-- 2. scroll back to top -> opener visible -> float closes
vim.api.nvim_win_set_cursor(w0, { 1, 0 })
ctx._schedule(w0)
if not vim.wait(1500, function() return #floats() == 0 end) then
  fail("header float did not close when opener scrolled into view"); return
end

-- 3. per-window: two splits of the same file, different scopes
vim.api.nvim_win_set_cursor(w0, { 25, 0 })
vim.cmd("vsplit")
local w1 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(w1, { 60, 0 })  -- inside beta
ctx._schedule(w0)
ctx._schedule(w1)
if not vim.wait(1500, function() return #floats() == 2 end) then
  fail("expected 2 per-window headers, got " .. #floats()); return
end
texts = header_texts()
if texts[1] ~= "function alpha()" or texts[2] ~= "function beta()" then
  fail("per-window header texts wrong: " .. vim.inspect(texts)); return
end
-- both floats anchored to their own host window at row 0
for _, x in ipairs(floats()) do
  if x.cfg.row ~= 0 then fail("float not at row 0"); return end
end

-- 4. resize -> float width tracks host window
local before = floats()[1].cfg.width
vim.api.nvim_win_set_width(w0, math.max(20, (before or 40) - 10))
ctx._schedule(w0)
vim.wait(300)
local ok_resize = false
for _, x in ipairs(floats()) do
  local host_w = vim.api.nvim_win_get_width(w0)
  local textoff = vim.fn.getwininfo(w0)[1].textoff or 0
  if x.cfg.width == host_w - textoff then ok_resize = true end
end
if not ok_resize then fail("float width did not track resized host window"); return end

-- 5. no-op cases: plain text buffer -> no floats (close splits first)
vim.cmd("only!")
ctx._recompute(vim.api.nvim_get_current_win())
vim.cmd("enew!")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "just plain text", "no scopes here" })
ctx._recompute(vim.api.nvim_get_current_win())
if #floats() ~= 0 then fail("header shown for scopeless buffer: " .. vim.inspect(header_texts())); return end

pass()
