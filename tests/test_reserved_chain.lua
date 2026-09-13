-- Test: the sticky scope header keeps the FULL ancestor chain pinned during
-- upward scroll, releasing one row at a time only as each opener is revealed.
--
-- This is the regression test for the reported bug: the old winline()-based
-- trim collapsed the header to the innermost scope alone as soon as the cursor
-- neared the top, so the viewport shifted while openers were still scrolled out.
-- The contract asserted here: at every step of an upward scroll,
--   * header height == min(#scrolled-out scopes, MAX_LINES, winh - 1);
--   * the window-local scrolloff reservation == that height;
--   * the cursor row is never above the header (never covered).
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

vim.o.lines = 30
vim.o.columns = 80

local ctx = require("ui.context")

-- 4-deep chain: openers on lines 1..4, long body, closers at the end
local file = vim.fn.stdpath("run") .. "/reserved_chain.lua"
local body = {
  "function outer()",      -- 1
  "  function inner()",    -- 2
  "    if x then",         -- 3
  "      if y then",       -- 4
}
for i = 1, 80 do body[#body + 1] = "        z = z + " .. i end
body[#body + 1] = "      end"
body[#body + 1] = "    end"
body[#body + 1] = "  end"
body[#body + 1] = "end"
local f = io.open(file, "w"); f:write(table.concat(body, "\n") .. "\n"); f:close()
vim.cmd("edit " .. vim.fn.fnameescape(file))
local w = vim.api.nvim_get_current_win()
local OPENERS = { 1, 2, 3, 4 }

local function floats_for(host)
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg.relative == "win" and cfg.win == host then
      out[#out + 1] = { win = win, cfg = cfg }
    end
  end
  return out
end
local function header(host)
  local fl = floats_for(host)
  if #fl == 0 then return nil end
  return fl[1].cfg
end
local function topline_of(host) return vim.fn.getwininfo(host)[1].topline end
local function winh_of(host) return vim.fn.getwininfo(host)[1].height end
local function so_of(host)
  -- raw window-local value: vim.wo[] resolves a cleared (-1) local to the global
  return vim.api.nvim_get_option_value("scrolloff", { win = host, scope = "local" })
end
local function count_out(host)
  local t, c = topline_of(host), 0
  for _, o in ipairs(OPENERS) do if o < t then c = c + 1 end end
  return c
end
local function want_n(host)
  return math.min(count_out(host), 6, math.max(0, winh_of(host) - 1))
end

-- start deep, then let the reservation apply (scrolloff acts on a real move)
vim.api.nvim_win_set_cursor(w, { 60, 0 })
ctx._recompute(w)
if #floats_for(w) ~= 1 then fail("no header when starting deep"); return end
if header(w).height ~= 4 then
  fail("expected a 4-line pinned chain when deep, got " .. tostring(header(w).height)); return
end
vim.api.nvim_win_call(w, function() vim.cmd("normal! j"); vim.cmd("normal! k") end)
ctx._recompute(w)

local steps, saw_multi = 0, false
while steps < 400 do
  vim.api.nvim_win_call(w, function() vim.cmd("normal! k") end)
  steps = steps + 1
  ctx._recompute(w)
  local t = topline_of(w)
  local cnt = count_out(w)
  local n = want_n(w)
  local cfg = header(w)
  if n == 0 then
    if cfg ~= nil then
      fail("step " .. steps .. ": header shown with no scrolled-out scope (topline " .. t .. ")"); return
    end
  else
    if cfg == nil or cfg.height ~= n then
      fail("step " .. steps .. ": height " .. tostring(cfg and cfg.height) .. " ~= " .. n
        .. " (topline " .. t .. ", scrolled-out " .. cnt .. ")"); return
    end
    if n > 1 then saw_multi = true end
    if so_of(w) ~= n then
      fail("step " .. steps .. ": window scrolloff " .. so_of(w) .. " ~= " .. n); return
    end
    local row = vim.api.nvim_win_call(w, vim.fn.winline) - 1
    if row < n then
      fail("step " .. steps .. ": cursor row " .. row .. " covered by height " .. n); return
    end
  end
  if t == 1 then break end
end
if steps >= 400 then fail("k loop never reached file top"); return end
if not saw_multi then fail("chain was never pinned beyond one scope during scroll-up"); return end
-- at the file top the header is gone and the reservation is cleared
if so_of(w) ~= -1 then fail("scrolloff " .. tostring(so_of(w)) .. " ~= -1 after reaching file top"); return end

pass()
