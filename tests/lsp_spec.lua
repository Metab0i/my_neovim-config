-- lsp_spec.lua — behavior tests for lsp/init.lua (keymaps + hover border).
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

-- lsp/init.lua runs at config load (via init.lua); assert its keymaps are present.
-- <leader> = " " so leader keys resolve to " gd", " rn", " ca".
local expectations = {
  { "n", "<C-Space>", "diagnostics at cursor" },
  { "n", " gd",       "go to definition" },
  { "n", "gr",        "references" },
  { "n", " rn",       "rename" },
  { "n", " ca",       "code action" },
  { "n", "K",         "hover" },
  { "n", "<S-Tab>",   "hover" },
}
for _, e in ipairs(expectations) do
  local found = false
  for _, m in ipairs(vim.api.nvim_get_keymap(e[1])) do
    if m.lhs == e[2] then found = true break end
  end
  if not found then fail("missing keymap '" .. e[2] .. "' (" .. e[3] .. ")"); return end
end

-- 1. hover border defaults to rounded (lsp/init.lua patch). Depending on the
--    nvim version, nvim_win_get_config().border returns the string ("rounded")
--    or the expanded glyph table; accept either.
local ROUNDED = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }
local SINGLE  = { "┌", "─", "┐", "│", "┘", "─", "└", "│" }
local function border_matches(b, name, glyphs)
  if b == name then return true end
  if type(b) == "table" then return vim.deep_equal(b, glyphs) end
  return false
end

local _, pwin = vim.lsp.util.open_floating_preview({ "line one", "line two" }, "txt", {})
if not (pwin and vim.api.nvim_win_is_valid(pwin)) then
  fail("open_floating_preview did not open a window"); return
end
local pcfg = vim.api.nvim_win_get_config(pwin)
if not border_matches(pcfg.border, "rounded", ROUNDED) then
  fail("patched border not rounded: " .. vim.inspect(pcfg.border)); return
end
vim.api.nvim_win_close(pwin, true)

-- 2. an explicit border is preserved (the patch only supplies a default).
local _, swin = vim.lsp.util.open_floating_preview({ "x" }, "txt", { border = "single" })
if not (swin and vim.api.nvim_win_is_valid(swin)) then
  fail("explicit-border float did not open"); return
end
local scfg = vim.api.nvim_win_get_config(swin)
if not border_matches(scfg.border, "single", SINGLE) then
  fail("explicit border overridden: " .. vim.inspect(scfg.border)); return
end
vim.api.nvim_win_close(swin, true)

-- 3. no diagnostics at cursor -> no diagnostics float opens
vim.cmd("enew!")
local nwin = #vim.api.nvim_list_wins()
vim.api.nvim_feedkeys(" <C-Space>", "t", false)
vim.wait(200, function() return #vim.api.nvim_list_wins() > nwin end)
if #vim.api.nvim_list_wins() > nwin then
  fail("diagnostics float opened with no diagnostics"); return
end

pass()
