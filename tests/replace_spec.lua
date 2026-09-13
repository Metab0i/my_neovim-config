-- replace_spec.lua — tests for core/execution_panel/replace.lua
-- Drives the pure logic (parse + match computation + apply) through a minimal
-- mock ctx; the real panel window/dropdown plumbing is not exercised here.
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local replace = require("core.execution_panel.replace")

-- target buffer: "foo foo bar", "baz foo", "qux"
local target = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(target, 0, -1, false, { "foo foo bar", "baz foo", "qux" })

local state = {
  match_str = "", replacement_str = "", re_obj = nil, re_valid = true,
  matches = {}, current_idx = 1, target_buf = target,
  ns = vim.api.nvim_create_namespace("ExecPanelTest"),
  prev_win = vim.api.nvim_get_current_win(),
}
local calls = { hint = 0, status = nil, help = 0, dropdown = 0 }
local ctx = {
  state = state,
  clear_extmarks = function() end,
  render_hint = function() calls.hint = calls.hint + 1 end,
  render_status = function(s) calls.status = s end,
  render_help = function() calls.help = calls.help + 1 end,
  set_dropdown_height = function() calls.dropdown = calls.dropdown + 1 end,
  set_dropdown = function() end,
  reposition_panel = function() end,
}
replace.init(ctx)

-- 1. parse + match computation
replace.refresh("/replace -m foo -r bar")
if state.match_str ~= "foo" then fail("match_str ~= foo: " .. state.match_str); return end
if state.replacement_str ~= "bar" then fail("replacement_str ~= bar: " .. state.replacement_str); return end
if not state.re_valid then fail("foo should be a valid regex"); return end
-- "foo" occurs on line0 col0, line0 col4, line1 col4 -> 3 matches
if #state.matches ~= 3 then fail("expected 3 matches, got " .. #state.matches .. " " .. vim.inspect(state.matches)); return end

-- 2. help mode
replace.refresh("/replace -h")
if state.help ~= true then fail("state.help not set"); return end
if calls.dropdown < 1 then fail("help mode did not render the help dropdown"); return end

-- 3. invalid regex
replace.refresh("/replace -m [ -r x")
if state.re_valid ~= false then fail("'[' should be flagged invalid"); return end
if not (calls.status or ""):match("^ Invalid regex") then fail("invalid regex status not shown: " .. tostring(calls.status)); return end

-- 4. replace_one replaces exactly the current match (current_idx=1 -> line0 col0)
replace.refresh("/replace -m foo -r bar")
replace.replace_one()
local lines0 = vim.api.nvim_buf_get_lines(target, 0, 1, false)[1]
if lines0 ~= "bar foo bar" then fail("replace_one: line0 = '" .. lines0 .. "'"); return end
-- other lines untouched
local lines1 = vim.api.nvim_buf_get_lines(target, 1, 2, false)[1]
if lines1 ~= "baz foo" then fail("replace_one touched line1: '" .. lines1 .. "'"); return end

-- 5. replace_all replaces every occurrence
vim.api.nvim_buf_set_lines(target, 0, -1, false, { "foo foo bar", "baz foo", "qux" })
replace.refresh("/replace -m foo -r X")
replace.replace_all()
local got = vim.api.nvim_buf_get_lines(target, 0, -1, false)
if got[1] ~= "X X bar" then fail("replace_all line0: '" .. got[1] .. "'"); return end
if got[2] ~= "baz X" then fail("replace_all line1: '" .. got[2] .. "'"); return end
if got[3] ~= "qux" then fail("replace_all touched line2"); return end

-- 6. capture-group reference in replacement is resolved per match (vim substitute)
vim.api.nvim_buf_set_lines(target, 0, -1, false, { "key:value" })
replace.refresh("/replace -m \\(\\w\\+\\):\\(\\w\\+\\) -r \\2=\\1")
if not state.re_valid then fail("capture regex invalid"); return end
replace.replace_one()
local l0 = vim.api.nvim_buf_get_lines(target, 0, 1, false)[1]
if l0 ~= "value=key" then fail("capture replacement: '" .. l0 .. "'"); return end

-- 7. empty /replace (no -m) -> render_hint, nothing crashes
replace.refresh("/replace")
if calls.hint < 1 then fail("empty replace did not render hint"); return end

pass()