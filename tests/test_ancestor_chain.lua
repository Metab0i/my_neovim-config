-- Test: multi-line ancestor-chain sticky header (plan tests 1-7)
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

vim.o.lines = 30
vim.o.columns = 80

local scope = require("core.scope_engine")
local ctx = require("ui.context")

-- 1. enclosing_chain unit: outermost-first, deduped by opener
local ranges = {
  { opener = 3, end_ = 20, indent = 4 },
  { opener = 3, end_ = 20, indent = 4 },  -- duplicate (LSP + heuristic)
  { opener = 1, end_ = 30, indent = 0 },
  { opener = 2, end_ = 25, indent = 2 },
}
local chain = scope.enclosing_chain(ranges, 10)
if #chain ~= 3 then fail("chain length " .. #chain .. " ~= 3 (dedup failed)"); return end
if chain[1].opener ~= 1 or chain[2].opener ~= 2 or chain[3].opener ~= 3 then
  fail("chain not outermost-first: " .. vim.inspect(chain)); return
end
local inner = scope.find_innermost(ranges, 10)
if inner == nil or inner.opener ~= 3 then fail("find_innermost regressed"); return end

-- 2-6. integration against a real nested buffer
local file = vim.fn.stdpath("run") .. "/ancestor_test.lua"
local body = {
  "function outer()",      -- 1
  "  function inner()",    -- 2
  "    if x then",         -- 3
  "      if y then",       -- 4
}
for i = 1, 60 do body[#body + 1] = "        z = z + " .. i end
body[#body + 1] = "      end"
body[#body + 1] = "    end"
body[#body + 1] = "  end"
body[#body + 1] = "end"
local f = io.open(file, "w"); f:write(table.concat(body, "\n") .. "\n"); f:close()
vim.cmd("edit " .. vim.fn.fnameescape(file))
local buf = vim.api.nvim_get_current_buf()
local w = vim.api.nvim_get_current_win()

local function floats_for(host)
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg.relative == "win" and cfg.win == host then
      out[#out + 1] = { win = win, cfg = cfg, buf = vim.api.nvim_win_get_buf(win) }
    end
  end
  return out
end
local function header(host)
  local fl = floats_for(host)
  if #fl == 0 then return nil end
  return fl[1].cfg, vim.api.nvim_buf_get_lines(fl[1].buf, 0, -1, false)
end
-- observable float identity + geometry. nvim_win_get_config returns a fresh
-- table each call, so compare fields, not table identity. winid is part of the
-- signature so a rebuild (new winid) is also caught.
local function float_sig(host)
  local fl = floats_for(host)
  if #fl == 0 then return nil end
  local c = fl[1].cfg
  return fl[1].win .. ":" .. (c.width or -1) .. "x" .. (c.height or -1)
    .. "@" .. (c.col or -1) .. "," .. (c.row or -1)
end
local function topline_of(host) return vim.fn.getwininfo(host)[1].topline end

-- 2. cursor deep -> 4-line chain, outermost-first
vim.api.nvim_win_set_cursor(w, { 50, 0 })
local okr, errr = pcall(ctx._recompute, w)
if not okr then fail("recompute errored: " .. tostring(errr)); return end
if not vim.wait(1000, function() return #floats_for(w) == 1 end) then
  fail("no float deep inside nesting (topline=" .. topline_of(w) .. ")"); return
end
local cfg, lines = header(w)
if cfg.height ~= 4 then fail("height " .. tostring(cfg.height) .. " ~= 4 (topline=" .. topline_of(w) .. ")"); return end
local want = { "function outer()", "  function inner()", "    if x then", "      if y then" }
for i = 1, 4 do
  if lines[i] ~= want[i] then
    fail("header line " .. i .. " '" .. tostring(lines[i]) .. "' ~= '" .. want[i] .. "'"); return
  end
end

-- 3. prefix shrinks as openers scroll into view: pin the viewport so exactly
--    two openers are visible, header keeps the rest
vim.api.nvim_win_call(w, function() vim.fn.cursor(3, 1); vim.cmd("normal! zt") end)
vim.api.nvim_win_call(w, function() vim.fn.cursor(5, 1) end)  -- cursor down, viewport stays
local t3 = topline_of(w)
ctx._recompute(w)
cfg, lines = header(w)
-- openers are 1..4; header shows openers < topline, capped to rows above cursor,
-- each line indented 2 spaces per shown level
local exp3 = {}
for _, o in ipairs({ 1, 2, 3, 4 }) do
  if o < t3 then exp3[#exp3 + 1] = o end
end
local avail3 = vim.api.nvim_win_call(w, vim.fn.winline) - 1
while #exp3 > avail3 do table.remove(exp3, 1) end
for i, o in ipairs(exp3) do exp3[i] = string.rep("  ", i - 1) .. want[o] end
if cfg == nil or cfg.height ~= #exp3 then
  fail("topline=" .. t3 .. ": expected height " .. #exp3 .. ", got "
    .. tostring(cfg and cfg.height) .. " lines=" .. vim.inspect(lines)); return
end
for i = 1, #exp3 do
  if lines[i] ~= exp3[i] then
    fail("shrunk header line " .. i .. " '" .. tostring(lines[i]) .. "' ~= '" .. exp3[i] .. "'"); return
  end
end
if #exp3 == 4 then fail("test setup: no opener scrolled into view"); return end

-- 4. cursor safety: pin the cursor to the first visible row (scrolloff=1 may
--    bump it one down); the header must never cover the cursor row
local t4 = topline_of(w)
vim.api.nvim_win_call(w, function() vim.fn.cursor(t4, 1) end)
ctx._recompute(w)
cfg, lines = header(w)
local wl4 = vim.api.nvim_win_call(w, vim.fn.winline)
if cfg ~= nil and cfg.height > wl4 - 1 then
  fail("header height " .. cfg.height .. " covers cursor at winline " .. wl4); return
end
if wl4 == 1 and #floats_for(w) ~= 0 then fail("header shown with zero rows above cursor"); return end

-- 4b. cursor below -> header height capped to rows above cursor, never covered
vim.api.nvim_win_call(w, function() vim.fn.cursor(5, 1) end)
ctx._recompute(w)
cfg, lines = header(w)
local exp4b = {}
for _, o in ipairs({ 1, 2, 3, 4 }) do
  if o < topline_of(w) then exp4b[#exp4b + 1] = want[o] end
end
local avail4b = vim.api.nvim_win_call(w, vim.fn.winline) - 1
while #exp4b > avail4b do table.remove(exp4b, 1) end
if #exp4b == 0 then
  if #floats_for(w) ~= 0 then fail("4b: expected no header"); return end
else
  if cfg == nil or cfg.height ~= #exp4b then fail("4b: expected height " .. #exp4b); return end
  local cursor_row = vim.api.nvim_win_call(w, vim.fn.winline) - 1
  if cursor_row < cfg.height then fail("cursor row " .. cursor_row .. " covered by height " .. cfg.height); return end
end

-- 5. trim keeps innermost: 8-deep chain, only 2 rows above cursor
ctx._close_all()
local deep = vim.fn.stdpath("run") .. "/deep_test.lua"
local dbody = {}
for i = 1, 8 do
  dbody[#dbody + 1] = string.rep("  ", i - 1) .. "if c" .. i .. " then"
end
for i = 1, 60 do dbody[#dbody + 1] = string.rep("  ", 8) .. "z = z + " .. i end
for i = 8, 1, -1 do dbody[#dbody + 1] = string.rep("  ", i - 1) .. "end" end
local fd = io.open(deep, "w"); fd:write(table.concat(dbody, "\n") .. "\n"); fd:close()
vim.cmd("edit " .. vim.fn.fnameescape(deep))
local w2 = vim.api.nvim_get_current_win()
vim.api.nvim_win_call(w2, function() vim.fn.cursor(10, 1); vim.cmd("normal! zt") end)
vim.api.nvim_win_call(w2, function() vim.fn.cursor(12, 1) end)  -- cursor row 3 -> avail 2
ctx._recompute(w2)
cfg, lines = header(w2)
if cfg == nil then fail("5: no float for deep chain (topline=" .. topline_of(w2) .. ")"); return end
-- innermost kept: the deepest n = min(8, avail, MAX_LINES) openers, outermost-first
local avail5 = vim.api.nvim_win_call(w2, vim.fn.winline) - 1
local n5 = math.min(8, avail5, 6)
if cfg.height ~= n5 then fail("5: height " .. tostring(cfg.height) .. " ~= " .. n5); return end
for i = 1, n5 do
  local opener = 8 - n5 + i
  local expect = string.rep("  ", i - 1) .. "if c" .. opener .. " then"
  if lines[i] ~= expect then
    fail("5: line " .. i .. " '" .. tostring(lines[i]) .. "' ~= '" .. expect .. "'"); return
  end
end

-- 6. shrink leaves no stale trailing lines in the scratch buffer
vim.api.nvim_win_call(w2, function() vim.fn.cursor(8, 1) end)  -- scroll upward
ctx._recompute(w2)
cfg, lines = header(w2)
local t6, avail6 = topline_of(w2), vim.api.nvim_win_call(w2, vim.fn.winline) - 1
local n6 = 0
for o = 1, 8 do if o < t6 then n6 = n6 + 1 end end
if n6 > avail6 then n6 = avail6 end
if n6 > 6 then n6 = 6 end
if cfg == nil or cfg.height ~= n6 then fail("6: expected height " .. n6 .. ", got " .. tostring(cfg and cfg.height)); return end
local deepest6 = 0
for o = 1, 8 do if o < t6 then deepest6 = o end end
local expect6 = string.rep("  ", cfg.height - 1) .. "if c" .. deepest6 .. " then"
if lines[#lines] ~= expect6 then
  fail("6: innermost line '" .. tostring(lines[#lines]) .. "' ~= '" .. expect6 .. "'"); return
end
local scratch = vim.api.nvim_win_get_buf(floats_for(w2)[1].win)
local nscratch = vim.api.nvim_buf_line_count(scratch)
if nscratch ~= n6 then fail("6: scratch has " .. nscratch .. " lines, expected " .. n6); return end

-- 7. regression: flat single function -> 1-line header
ctx._close_all()
local flat = vim.fn.stdpath("run") .. "/flat_test.lua"
local fbody = { "function solo()" }
for i = 1, 60 do fbody[#fbody + 1] = "  q = q + " .. i end
fbody[#fbody + 1] = "end"
local ff = io.open(flat, "w"); ff:write(table.concat(fbody, "\n") .. "\n"); ff:close()
vim.cmd("edit " .. vim.fn.fnameescape(flat))
local w3 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(w3, { 50, 0 })
ctx._recompute(w3)
cfg, lines = header(w3)
if cfg == nil or cfg.height ~= 1 or lines[1] ~= "function solo()" then
  fail("7: flat function header wrong: " .. vim.inspect(lines)); return
end

-- 8. flicker guard: identical recompute must not reconfigure the float
ctx._close_all()
vim.cmd("edit " .. vim.fn.fnameescape(file))  -- nested 4-deep chain
local w8 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(w8, { 50, 0 })
ctx._recompute(w8)
cfg = header(w8)
if cfg == nil then fail("8: no float"); return end
local sig_before = float_sig(w8)
ctx._recompute(w8)  -- identical state: nothing changed
if float_sig(w8) ~= sig_before then
  fail("8: no-op recompute changed the float (winid/geometry) "
    .. sig_before .. " -> " .. tostring(float_sig(w8))); return
end
-- but a real change must reconfigure: pin the viewport near the top so the
-- dynamic trim shrinks the header height (4 -> 2 lines)
vim.api.nvim_win_call(w8, function() vim.cmd("normal! zt") end)
vim.api.nvim_win_call(w8, function() vim.fn.cursor(52, 1) end)  -- 2 rows above cursor
ctx._recompute(w8)
cfg = header(w8)
local avail8 = vim.api.nvim_win_call(w8, vim.fn.winline) - 1
if cfg == nil then fail("8: float lost after trim"); return end
if cfg.height ~= avail8 or avail8 >= 4 then
  fail("8: expected trimmed height " .. avail8 .. ", got " .. tostring(cfg.height)); return
end
-- the resize reconfigured the SAME float in place (height changed, winid kept)
if string.match(float_sig(w8), "^(%d+):") ~= string.match(sig_before, "^(%d+):") then
  fail("8: trim rebuilt the float instead of resizing in place"); return
end

-- 9. event.all mass scroll: float survives (no teardown/rebuild); once the
--    viewport settles, a repeated recompute must not reconfigure at all
vim.api.nvim_win_set_cursor(w8, { 50, 0 })
ctx._recompute(w8)
cfg = header(w8)
if cfg == nil then fail("9: no float before mass scroll"); return end
local winid_before = floats_for(w8)[1].win
vim.api.nvim_win_call(w8, function() vim.cmd("normal! zt") end)  -- topline = 50
vim.api.nvim_win_call(w8, function() vim.fn.cursor(52, 1) end)   -- cursor below top row
ctx._recompute(w8)
cfg = header(w8)
if cfg == nil then fail("9: float lost after mass scroll"); return end
if floats_for(w8)[1].win ~= winid_before then
  fail("9: float was torn down and rebuilt on event.all"); return
end
local sig9 = float_sig(w8)
ctx._recompute(w8)  -- settled state: repeated recompute is a no-op
if float_sig(w8) ~= sig9 then
  fail("9: settled recompute reconfigured the float ("
    .. sig9 .. " -> " .. tostring(float_sig(w8))); return
end

pass()
