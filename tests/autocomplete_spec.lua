-- autocomplete_spec.lua — behavior tests for lua/autocomplete.lua at the nvim
-- boundary. The full LSP round-trip needs a live server + insert mode, which is
-- fragile headlessly; those paths are a documented manual-verification gap.
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local ac = require("autocomplete")

-- 1. observable initial state: not active
if ac._is_active() ~= false then fail("initial _is_active should be false"); return end

-- 2. the insert <C-space> toggle keymap exists (system boundary: keymap wiring)
local found = false
for _, m in ipairs(vim.api.nvim_get_keymap("i")) do
  if m.lhs == "<C-Space>" then found = true end
end
if not found then fail("insert <C-space> autocomplete mapping missing"); return end

-- 3. toggle from normal mode is a safe no-op: no window/float opens and the
--    module stays inactive (exercises the get_mode() ~= "i" guard).
local nwin = #vim.api.nvim_list_wins()
ac.toggle()
if ac._is_active() ~= false then fail("toggle in normal mode became active"); return end
if #vim.api.nvim_list_wins() ~= nwin then fail("toggle in normal mode opened a window"); return end

pass()
