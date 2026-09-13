local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local ok, err = pcall(require, "ui.context")
if not ok then fail("require ui.context: " .. tostring(err)); return end

-- partial theme: Comment has fg, CursorLine has NO bg (underline-only style).
-- Use `highlight clear` (not set_hl {}) so default-tracking resets properly.
vim.cmd("highlight clear")
vim.api.nvim_set_hl(0, "Comment", { fg = 0xabcdef })
vim.api.nvim_set_hl(0, "CursorLine", { underline = true })
local okfire, ferr = pcall(vim.api.nvim_exec_autocmds, "ColorScheme", { group = "StickyScope" })
if not okfire then fail("autocmd errored with partial groups: " .. tostring(ferr)); return end
local hl = vim.api.nvim_get_hl(0, { name = "StickyScope", link = false })
io.stdout:write("partial sticky=" .. vim.inspect(hl) .. "\n"); io.stdout:flush()
if hl.fg ~= 0xabcdef then fail("partial derivation lost Comment fg: " .. vim.inspect(hl)); return end
if hl.bg ~= nil then fail("unexpected bg: " .. vim.inspect(hl)); return end

pass()
