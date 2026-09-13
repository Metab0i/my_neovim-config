local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local ok, err = pcall(require, "ui.context")
if not ok then fail("require ui.context: " .. tostring(err)); return end

-- truly empty Comment/CursorLine -> derivation finds nothing -> Comment-link fallback
vim.cmd("highlight clear")
vim.api.nvim_set_hl(0, "Comment", {})
vim.api.nvim_set_hl(0, "CursorLine", {})
io.stdout:write("comment=" .. vim.inspect(vim.api.nvim_get_hl(0, { name = "Comment", link = false })) .. "\n"); io.stdout:flush()
local okfire, ferr = pcall(vim.api.nvim_exec_autocmds, "ColorScheme", { group = "StickyScope" })
if not okfire then fail("autocmd errored with empty groups: " .. tostring(ferr)); return end
local hl = vim.api.nvim_get_hl(0, { name = "StickyScope" })
io.stdout:write("sticky=" .. vim.inspect(hl) .. "\n"); io.stdout:flush()
if hl.link ~= "Comment" then fail("expected Comment-link fallback, got: " .. vim.inspect(hl)); return end

-- partial: fg only, no bg (theme with underline-only CursorLine) -> no error.
-- Reset with `highlight clear` (not nvim_set_hl(.., {})), which would mark
-- StickyScope as user-defined and make the module's `default=true` set a no-op.
vim.cmd("highlight clear")
vim.api.nvim_set_hl(0, "Comment", { fg = 0xabcdef })
vim.api.nvim_set_hl(0, "CursorLine", {})
okfire, ferr = pcall(vim.api.nvim_exec_autocmds, "ColorScheme", { group = "StickyScope" })
if not okfire then fail("autocmd errored with partial groups: " .. tostring(ferr)); return end
hl = vim.api.nvim_get_hl(0, { name = "StickyScope", link = false })
io.stdout:write("partial sticky=" .. vim.inspect(hl) .. "\n"); io.stdout:flush()
if hl.fg ~= 0xabcdef then fail("partial derivation lost Comment fg: " .. vim.inspect(hl)); return end

pass()
