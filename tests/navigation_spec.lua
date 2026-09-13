-- navigation_spec.lua — tests for core/navigation.lua (editor settings + keymaps)
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

-- 1. editor options set by navigation.lua
local opts = {
  { "number",      vim.o.number,      true },
  { "relativenumber", vim.o.relativenumber, true },
  { "numberwidth", vim.o.numberwidth, 1 },
  { "cursorline",  vim.o.cursorline,  true },
  { "cursorlineopt", vim.o.cursorlineopt, "number" },
  { "scrolloff",   vim.o.scrolloff,   1 },
  { "shiftwidth",  vim.o.shiftwidth,  2 },
  { "softtabstop", vim.o.softtabstop, 2 },
  { "wrap",        vim.wo.wrap,       true },
  { "breakindent", vim.wo.breakindent, true },
  { "clipboard",   vim.o.clipboard,   "unnamed" },
  { "laststatus",  vim.o.laststatus,  3 },
}
for _, o in ipairs(opts) do
  if o[2] ~= o[3] then fail(o[1] .. " = " .. tostring(o[2]) .. " ~= " .. tostring(o[3])); return end
end

-- 2. leader key is a space
if vim.g.mapleader ~= " " then fail("mapleader ~= ' ': " .. tostring(vim.g.mapleader)); return end

-- 3. keymaps exist: t <Esc>, i <C-z>, i <C-r>, n <CR>
local function has(mode, lhs)
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if m.lhs == lhs then return true end
  end
  return false
end
if not has("t", "<Esc>") then fail("terminal <Esc> mapping missing"); return end
if not has("i", "<C-Z>") then fail("insert <C-z> mapping missing"); return end
if not has("i", "<C-R>") then fail("insert <C-r> mapping missing"); return end
if not has("n", "<CR>") then fail("normal <CR> mapping missing"); return end

-- 4. CursorLineNr highlight group is defined
local clnr = vim.api.nvim_get_hl(0, { name = "CursorLineNr", link = false })
if not clnr or (not clnr.fg and not clnr.bold) then
  fail("CursorLineNr highlight not set: " .. vim.inspect(clnr)); return
end

pass()