-- mason_spec.lua — tests for core/mason.lua at the LSP config registry boundary.
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

-- module loads
local ok, err = pcall(require, "core.mason")
if not ok then fail("require core.mason: " .. tostring(err)); return end

-- setup() already ran at config load (via lsp/init.lua which init.lua requires);
-- assert the LSP config hooks it installs are present, without re-invoking setup
-- (which would spawn/initialize LSP servers). Read config via the index form.
local clangd = vim.lsp.config["clangd"]
local lua_ls = vim.lsp.config["lua_ls"]
if type(clangd) ~= "table" then fail("clangd LSP config not installed by setup()"); return end
if type(lua_ls) ~= "table" then fail("lua_ls LSP config not installed by setup()"); return end

-- clangd config carries the --query-driver flags
local cmd = clangd.cmd or {}
local has_qd = false
for _, c in ipairs(cmd) do if type(c) == "string" and c:find("query%-driver") then has_qd = true end end
if not has_qd then fail("clangd config missing --query-driver"); return end

-- lua_ls config exposes the "vim" global for diagnostics
local globals = lua_ls.settings
  and lua_ls.settings.Lua
  and lua_ls.settings.Lua.diagnostics
  and lua_ls.settings.Lua.diagnostics.globals
local has_vim = false
if type(globals) == "table" then
  for _, g in ipairs(globals) do if g == "vim" then has_vim = true end end
end
if not has_vim then fail("lua_ls config missing 'vim' global"); return end

pass()
