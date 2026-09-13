local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local ok, err = pcall(require, "ui.context")
if not ok then fail("require ui.context: " .. tostring(err)); return end

-- 1. load-time derivation: StickyScope has fg from Comment, bg from CursorLine
local hl = vim.api.nvim_get_hl(0, { name = "StickyScope", link = false })
local cmt = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
local cl  = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
io.stdout:write("sticky=" .. vim.inspect(hl) .. "\n"); io.stdout:flush()
if cmt.fg and hl.fg ~= cmt.fg then fail("fg not derived from Comment"); return end
if cl.bg and hl.bg ~= cl.bg then fail("bg not derived from CursorLine"); return end
if not hl.fg and not hl.bg and not hl.link then fail("no attrs and no link fallback"); return end

-- 2. realistic theme switch: `hi clear` wipes StickyScope, new CursorLine bg,
--    ColorScheme fires -> default re-derives from the NEW theme
vim.cmd("highlight clear")
vim.api.nvim_set_hl(0, "Comment", { fg = 0x112233 })
vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x334455 })
vim.api.nvim_exec_autocmds("ColorScheme", { group = "StickyScope" })
hl = vim.api.nvim_get_hl(0, { name = "StickyScope", link = false })
io.stdout:write("after-switch sticky=" .. vim.inspect(hl) .. "\n"); io.stdout:flush()
if hl.fg ~= 0x112233 then fail("recompute did not track new Comment fg: " .. vim.inspect(hl)); return end
if hl.bg ~= 0x334455 then fail("recompute did not track new CursorLine bg: " .. vim.inspect(hl)); return end

-- 3. default=true semantics: a colorscheme that sets StickyScope itself must
--    NOT be clobbered by the default
vim.cmd("highlight clear")
vim.api.nvim_set_hl(0, "Comment", { fg = 0x112233 })
vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x334455 })
vim.api.nvim_set_hl(0, "StickyScope", { fg = 0xff0000, bg = 0x00ff00 })  -- theme's own def
vim.api.nvim_exec_autocmds("ColorScheme", { group = "StickyScope" })
hl = vim.api.nvim_get_hl(0, { name = "StickyScope", link = false })
if hl.fg ~= 0xff0000 or hl.bg ~= 0x00ff00 then
  fail("default clobbered theme's own StickyScope: " .. vim.inspect(hl)); return
end

-- 4. no groups at all -> Comment-link fallback, no error.
-- `highlight clear` alone does NOT empty Comment/CursorLine (the default
-- colorscheme re-populates them with colors), so empty them explicitly to
-- trigger the link fallback. highlight clear resets StickyScope's user-defined
-- status so the module's `default=true` set is not a no-op.
vim.cmd("highlight clear")
vim.api.nvim_set_hl(0, "Comment", {})
vim.api.nvim_set_hl(0, "CursorLine", {})
local okfire, ferr = pcall(vim.api.nvim_exec_autocmds, "ColorScheme", { group = "StickyScope" })
if not okfire then fail("autocmd errored with cleared groups: " .. tostring(ferr)); return end
hl = vim.api.nvim_get_hl(0, { name = "StickyScope" })
io.stdout:write("cleared sticky=" .. vim.inspect(hl) .. "\n"); io.stdout:flush()
if hl.link ~= "Comment" then fail("expected Comment-link fallback, got: " .. vim.inspect(hl)); return end
local sep = vim.api.nvim_get_hl(0, { name = "StickyScopeSeparator" })
if sep.link ~= "Comment" then fail("separator fallback broken: " .. vim.inspect(sep)); return end

pass()
