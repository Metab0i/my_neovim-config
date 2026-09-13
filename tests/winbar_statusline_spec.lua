-- winbar_statusline_spec.lua — tests for ui/winbar.lua and ui/statusline.lua
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

-- both modules load (they run at config load via init.lua)
local ok, err = pcall(require, "ui.winbar")
if not ok then fail("require ui.winbar: " .. tostring(err)); return end
ok, err = pcall(require, "ui.statusline")
if not ok then fail("require ui.statusline: " .. tostring(err)); return end

-- 1. winbar option is set to show modified flag + full path
if not (vim.wo.winbar or ""):find("%m") then fail("winbar missing %m: " .. tostring(vim.wo.winbar)); return end
if not (vim.wo.winbar or ""):find("%F") then fail("winbar missing %F: " .. tostring(vim.wo.winbar)); return end

-- 2. statusline global is set and renders without error
if vim.o.statusline ~= "%!v:lua.StatusLine()" then
  fail("statusline option wrong: " .. vim.o.statusline); return
end
local status
local okstatus, errstatus = pcall(function() status = _G.StatusLine() end)
if not okstatus then fail("StatusLine() errored: " .. tostring(errstatus)); return end
if type(status) ~= "string" then fail("StatusLine() did not return a string"); return end
-- renders the diagnostics counters + LSP name + percentage placeholders
if not status:find("Err:") then fail("statusline missing Err: counter: " .. status); return end
if not status:find("Warn:") then fail("statusline missing Warn: counter"); return end
if not status:find("No LSP") and not status:find("|") then fail("statusline missing LSP segment"); return end

pass()