-- Test: multi-line ancestor-chain sticky header (reservation model).
--
-- Contract:
--   * enclosing_chain is outermost-first, deduped by opener;
--   * header height = min(#scopes whose opener < topline, MAX_LINES, winh-1):
--     the full scrolled-out chain stays pinned -- there is no winline()-based
--     trim that would collapse it to one line during upward scroll;
--   * the window-local scrolloff is reserved to that height (screen rows);
--   * when capped at MAX_LINES the innermost scopes are kept, outermost-first;
--   * closing the header clears the window-local scrolloff reservation.
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

vim.o.lines = 30
vim.o.columns = 80

local scope = require("core.scope_engine")
local ctx = require("ui.context")

local MAX = 6

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
if (scope.find_innermost(ranges, 10) or {}).opener ~= 3 then fail("find_innermost regressed"); return end

-- helpers
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
local function float_sig(host)
  local fl = floats_for(host)
  if #fl == 0 then return nil end
  local c = fl[1].cfg
  return fl[1].win .. ":" .. (c.width or -1) .. "x" .. (c.height or -1)
    .. "@" .. (c.col or -1) .. "," .. (c.row or -1)
end
local function topline_of(host) return vim.fn.getwininfo(host)[1].topline end
local function winh_of(host) return vim.fn.getwininfo(host)[1].height end
local function so_of(host)
  -- raw window-local value: vim.wo[] resolves a cleared (-1) local to the global
  return vim.api.nvim_get_option_value("scrolloff", { win = host, scope = "local" })
end
-- count of `openers` still scrolled out of view (opener < topline)
local function count_out(host, openers)
  local t, c = topline_of(host), 0
  for _, o in ipairs(openers) do if o < t then c = c + 1 end end
  return c
end
-- the height the reservation contract prescribes for this state
local function want_n(host, openers)
  return math.min(count_out(host, openers), MAX, math.max(0, winh_of(host) - 1))
end

-- integration buffer: 4 openers (lines 1..4), 60-line body, closers
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
local w = vim.api.nvim_get_current_win()
local OPENERS = { 1, 2, 3, 4 }
-- header text = opener line with leading whitespace stripped, re-indented 2
-- spaces per shown level; this mirrors it for expected-value construction.
local WANT_STRIP = { "function outer()", "function inner()", "if x then", "if y then" }

-- 2. cursor deep -> full 4-line chain, reservation == height
vim.api.nvim_win_set_cursor(w, { 50, 0 })
local okr, errr = pcall(ctx._recompute, w)
if not okr then fail("recompute errored: " .. tostring(errr)); return end
if not vim.wait(500, function() return #floats_for(w) == 1 end) then
  fail("no float deep inside nesting (topline=" .. topline_of(w) .. ")"); return
end
local cfg, lines = header(w)
local n2 = want_n(w, OPENERS)
if n2 ~= 4 then fail("2: setup: expected 4 scrolled-out openers (topline=" .. topline_of(w) .. ")"); return end
if cfg.height ~= n2 then fail("2: height " .. tostring(cfg.height) .. " ~= " .. n2); return end
for i = 1, n2 do
  local expect = string.rep("  ", i - 1) .. WANT_STRIP[i]
  if lines[i] ~= expect then fail("2: line " .. i .. " '" .. tostring(lines[i]) .. "' ~= '" .. expect .. "'"); return end
end
if so_of(w) ~= n2 then fail("2: window scrolloff " .. tostring(so_of(w)) .. " ~= " .. n2); return end

-- 3. viewport pinned near the top -> height == count_out (NOT trimmed to the
--    rows above the cursor); only still-scrolled-out openers shown
vim.wo[w].scrolloff = 0
vim.api.nvim_win_call(w, function() vim.fn.cursor(3, 1); vim.cmd("normal! zt") end)
vim.api.nvim_win_call(w, function() vim.fn.cursor(5, 1) end)
ctx._recompute(w)
cfg, lines = header(w)
local t3 = topline_of(w)
local cnt3, n3 = count_out(w, OPENERS), want_n(w, OPENERS)
if n3 == 0 or n3 == 4 then fail("3: setup: expected a partial chain (topline=" .. t3 .. ")"); return end
local exp3 = {}
for i = 1, n3 do exp3[i] = string.rep("  ", i - 1) .. WANT_STRIP[cnt3 - n3 + i] end
if cfg == nil or cfg.height ~= n3 then
  fail("3: topline=" .. t3 .. " expected height " .. n3 .. ", got " .. tostring(cfg and cfg.height)
    .. " lines=" .. vim.inspect(lines)); return
end
for i = 1, n3 do
  if lines[i] ~= exp3[i] then fail("3: line " .. i .. " '" .. tostring(lines[i]) .. "' ~= '" .. exp3[i] .. "'"); return end
end
if so_of(w) ~= n3 then fail("3: window scrolloff " .. tostring(so_of(w)) .. " ~= " .. n3); return end

-- 4. reservation bounded by winh-1; once applied the cursor is never covered
local winh4 = winh_of(w)
if so_of(w) > math.max(0, winh4 - 1) then
  fail("4: scrolloff " .. so_of(w) .. " exceeds winh-1 " .. (winh4 - 1)); return
end
-- scrolloff applies lazily (next real move): bounce the cursor to enforce it
vim.api.nvim_win_call(w, function() vim.cmd("normal! j"); vim.cmd("normal! k") end)
ctx._recompute(w)
cfg = header(w)
if cfg ~= nil then
  local row = vim.api.nvim_win_call(w, vim.fn.winline) - 1
  if row < cfg.height then fail("4: cursor row " .. row .. " covered by height " .. cfg.height); return end
end

-- 5. cap: 8-deep chain -> height MAX (6), innermost 6 kept, outermost-first
ctx._close_all()
local deep = vim.fn.stdpath("run") .. "/deep_test.lua"
local dbody = {}
for i = 1, 8 do dbody[#dbody + 1] = string.rep("  ", i - 1) .. "if c" .. i .. " then" end
for i = 1, 60 do dbody[#dbody + 1] = string.rep("  ", 8) .. "z = z + " .. i end
for i = 8, 1, -1 do dbody[#dbody + 1] = string.rep("  ", i - 1) .. "end" end
local fd = io.open(deep, "w"); fd:write(table.concat(dbody, "\n") .. "\n"); fd:close()
vim.cmd("edit " .. vim.fn.fnameescape(deep))
local w2 = vim.api.nvim_get_current_win()
local DEEP = { 1, 2, 3, 4, 5, 6, 7, 8 }
vim.wo[w2].scrolloff = 0
vim.api.nvim_win_call(w2, function() vim.fn.cursor(50, 1); vim.cmd("normal! zt") end)
ctx._recompute(w2)
cfg, lines = header(w2)
if cfg == nil then fail("5: no float for deep chain (topline=" .. topline_of(w2) .. ")"); return end
local cnt5, n5 = count_out(w2, DEEP), want_n(w2, DEEP)
if cnt5 ~= 8 then fail("5: setup: expected 8 scrolled-out (topline=" .. topline_of(w2) .. ")"); return end
if cfg.height ~= n5 then fail("5: height " .. tostring(cfg.height) .. " ~= " .. n5); return end
for i = 1, n5 do
  local opener = cnt5 - n5 + i
  local expect = string.rep("  ", i - 1) .. "if c" .. opener .. " then"
  if lines[i] ~= expect then fail("5: line " .. i .. " '" .. tostring(lines[i]) .. "' ~= '" .. expect .. "'"); return end
end
if so_of(w2) ~= n5 then fail("5: scrolloff " .. tostring(so_of(w2)) .. " ~= " .. n5); return end

-- 6. shrink leaves no stale trailing lines in the scratch buffer
vim.api.nvim_win_call(w2, function() vim.fn.cursor(8, 1) end)
ctx._recompute(w2)
cfg, lines = header(w2)
local cnt6, n6 = count_out(w2, DEEP), want_n(w2, DEEP)
if n6 == 0 then
  if cfg ~= nil then fail("6: header shown with no scrolled-out scopes"); return end
else
  if cfg == nil or cfg.height ~= n6 then
    fail("6: expected height " .. n6 .. ", got " .. tostring(cfg and cfg.height)); return
  end
  local scratch = vim.api.nvim_win_get_buf(floats_for(w2)[1].win)
  if vim.api.nvim_buf_line_count(scratch) ~= n6 then
    fail("6: scratch has " .. vim.api.nvim_buf_line_count(scratch) .. " lines, expected " .. n6); return
  end
  local deepest6 = 0
  for _, o in ipairs(DEEP) do if o < topline_of(w2) then deepest6 = o end end
  local expect6 = string.rep("  ", n6 - 1) .. "if c" .. deepest6 .. " then"
  if lines[#lines] ~= expect6 then
    fail("6: innermost line '" .. tostring(lines[#lines]) .. "' ~= '" .. expect6 .. "'"); return
  end
end

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
if so_of(w3) ~= 1 then fail("7: scrolloff " .. tostring(so_of(w3)) .. " ~= 1"); return end

-- 8. flicker guard: identical recompute must not reconfigure; a reveal resizes
--    the SAME float in place
ctx._close_all()
vim.cmd("edit " .. vim.fn.fnameescape(file))
local w8 = vim.api.nvim_get_current_win()
vim.wo[w8].scrolloff = 0
vim.api.nvim_win_set_cursor(w8, { 50, 0 })
ctx._recompute(w8)
cfg = header(w8)
if cfg == nil then fail("8: no float"); return end
local sig_before = float_sig(w8)
ctx._recompute(w8)  -- identical state: nothing changed
if float_sig(w8) ~= sig_before then
  fail("8: no-op recompute changed the float (" .. sig_before .. " -> " .. tostring(float_sig(w8)) .. ")"); return
end
-- real change: pin the viewport so opener 4 is revealed -> height 4 -> 3
vim.wo[w8].scrolloff = 0
vim.api.nvim_win_call(w8, function() vim.fn.cursor(4, 1); vim.cmd("normal! zt") end)
ctx._recompute(w8)
cfg = header(w8)
local cnt8, n8 = count_out(w8, OPENERS), want_n(w8, OPENERS)
if cnt8 ~= 3 then fail("8: setup: expected 3 scrolled-out (topline=" .. topline_of(w8) .. ")"); return end
if cfg == nil or cfg.height ~= n8 then
  fail("8: expected height " .. n8 .. ", got " .. tostring(cfg and cfg.height)); return
end
if string.match(float_sig(w8), "^(%d+):") ~= string.match(sig_before, "^(%d+):") then
  fail("8: reveal rebuilt the float instead of resizing in place"); return
end

-- 9. event.all mass scroll: float survives (no teardown/rebuild); a settled
--    repeated recompute is a no-op
vim.wo[w8].scrolloff = 0
vim.api.nvim_win_set_cursor(w8, { 50, 0 })
ctx._recompute(w8)
cfg = header(w8)
if cfg == nil then fail("9: no float before mass scroll"); return end
local winid_before = floats_for(w8)[1].win
vim.api.nvim_win_call(w8, function() vim.cmd("normal! zt") end)  -- topline = cursor
vim.api.nvim_win_call(w8, function() vim.fn.cursor(52, 1) end)
ctx._recompute(w8)
cfg = header(w8)
if cfg == nil then fail("9: float lost after mass scroll"); return end
if floats_for(w8)[1].win ~= winid_before then
  fail("9: float was torn down and rebuilt on event.all"); return
end
local sig9 = float_sig(w8)
ctx._recompute(w8)  -- settled state: repeated recompute is a no-op
if float_sig(w8) ~= sig9 then
  fail("9: settled recompute reconfigured the float (" .. sig9 .. " -> " .. tostring(float_sig(w8)) .. ")"); return
end

-- 10. closing the header clears the window-local scrolloff reservation
if so_of(w8) == -1 then fail("10: setup: expected a reservation before close"); return end
ctx._close_all()
if so_of(w8) ~= -1 then
  fail("10: scrolloff " .. tostring(so_of(w8)) .. " ~= -1 after close"); return
end

pass()
