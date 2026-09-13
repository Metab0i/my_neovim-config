-- notice_spec.lua — tests for core/notice.lua popup lifecycle
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local notice = require("core.notice")

local function win_count()
  return #vim.api.nvim_list_wins()
end

local base = win_count()

-- 1. set() opens a float window
notice.set("hello test", 60000)
if win_count() ~= base + 1 then fail("set() did not open a float: " .. win_count() .. " ~= " .. base + 1); return end

-- 2. clear() closes it
notice.clear()
if win_count() ~= base then fail("clear() did not close the float: " .. win_count() .. " ~= " .. base); return end

-- 3. set() replaces the previous notice (clear-then-open, net +1 from base)
notice.set("first", 60000)
notice.set("second", 60000)
if win_count() ~= base + 1 then fail("second set should net one float, got " .. win_count()); return end

-- 4. M.get returns nil (documented stub)
if notice.get() ~= nil then fail("notice.get() should return nil"); return end

notice.clear()
pass()