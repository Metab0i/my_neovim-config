-- discovery_spec.lua — tests for core/execution_panel/discovery.lua (pure logic)
local function pass() io.stdout:write("TEST_RESULT: PASS\n"); io.stdout:flush() end
local function fail(m) io.stdout:write("TEST_RESULT: FAIL: " .. tostring(m) .. "\n"); io.stdout:flush() end

local d = require("core.execution_panel.discovery")

-- 1. _relpath_under: relative path under base, "." for equal, nil outside
local cases = {
  { "/a/b/c.txt", "/a/b", "c.txt" },
  { "/a/b/c.txt", "/a",   "b/c.txt" },
  { "/a/b",       "/a/b", "." },
  { "/a/bc.txt",  "/a/b", nil },  -- sibling, not prefix
  { "/x/c.txt",   "/a",   nil },
  { nil,          "/a",   nil },
}
for _, c in ipairs(cases) do
  local got = d._relpath_under(c[1], c[2])
  if got ~= c[3] then fail("relpath_under(" .. tostring(c[1]) .. "," .. tostring(c[2]) .. ") = " .. tostring(got) .. " ~= " .. tostring(c[3])); return end
end

-- 2. find_token: standalone token boundaries (space-delimited; not part of a word)
-- finds "-m" only when it is whitespace-delimited on both sides
local t1 = d.find_token("-m foo", "-m")
if t1 ~= 1 then fail("find_token should find leading standalone -m, got " .. tostring(t1)); return end
local t2 = d.find_token("a -m b", "-m")
if t2 == nil then fail("find_token should find -m in 'a -m b'"); return end
local t3 = d.find_token("a x-m b", "-m")
if t3 ~= nil then fail("find_token must NOT match -m glued to a word"); return end
local t4 = d.find_token("a -mx b", "-m")
if t4 ~= nil then fail("find_token must NOT match -m followed by a word char"); return end
if d.find_token("hello", "xyz") ~= nil then fail("find_token found absent token"); return end

-- 3. find_matches_on_line: vim regex occurrences, 0-based col/end_col
local re = vim.regex("foo")
local ms = d.find_matches_on_line(re, "foo bar foo")
if #ms ~= 2 then fail("expected 2 matches, got " .. #ms); return end
if ms[1].col ~= 0 or ms[1].end_col ~= 3 then fail("match1 wrong: " .. vim.inspect(ms[1])); return end
if ms[2].col ~= 8 or ms[2].end_col ~= 11 then fail("match2 wrong: " .. vim.inspect(ms[2])); return end
if #d.find_matches_on_line(re, "no match here") ~= 0 then fail("unexpected matches"); return end
if #d.find_matches_on_line(re, nil) ~= 0 then fail("nil line should yield 0 matches"); return end
-- zero-width regex must not infinite-loop; returns occurrences or empties cleanly
pcall(function() d.find_matches_on_line(vim.regex("a*"), "aaaa") end)

-- 4. line_matches_in_file on a loaded buffer
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "cat dog cat", "bird", "cat" })
local lm = d.line_matches_in_file(buf, "cat")
if #lm ~= 3 then fail("line_matches_in_file: expected 3, got " .. #lm .. " " .. vim.inspect(lm)); return end
if lm[1].row ~= 0 or lm[1].col ~= 0 then fail("line_matches first wrong: " .. vim.inspect(lm[1])); return end
if lm[3].row ~= 2 or lm[3].col ~= 0 then fail("line_matches third wrong: " .. vim.inspect(lm[3])); return end
if #d.line_matches_in_file(buf, "zzz") ~= 0 then fail("line_matches found absent"); return end

-- 5. list_files / build_file_list / grep_files against a real temp dir
local dir = vim.fn.stdpath("run") .. "/disc_test"
os.execute("rm -rf " .. vim.fn.shellescape(dir))
vim.fn.mkdir(dir, "p")
vim.fn.mkdir(dir .. "/sub", "p")
local fh = io.open(dir .. "/alpha.txt", "w"); fh:write("hello world hello\n"); fh:close()
fh = io.open(dir .. "/beta.txt", "w"); fh:write("unique needle here\n"); fh:close()
fh = io.open(dir .. "/sub/gamma.lua", "w"); fh:write("hello again\n"); fh:close()

local files = d.list_files(dir)
local have = {}
for _, f in ipairs(files) do have[f] = true end
if not have[vim.fs.normalize(dir .. "/alpha.txt")] then fail("list_files missing alpha.txt"); return end
if not have[vim.fs.normalize(dir .. "/beta.txt")] then fail("list_files missing beta.txt"); return end
if not have[vim.fs.normalize(dir .. "/sub/gamma.lua")] then fail("list_files missing nested gamma.lua"); return end

-- build_file_list via a buffer whose file_dir is `dir`
local fbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(fbuf, dir .. "/alpha.txt")
vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "hello" })
local blist = d.build_file_list(fbuf)
-- search_dirs includes file_dir + git_root + cwd, so the list is a superset;
-- assert the temp-dir files are present (not that it is limited to dir)
local seen = {}
for _, f in ipairs(blist) do seen[f] = true end
for _, expect in ipairs({ "alpha.txt", "beta.txt", "sub/gamma.lua" }) do
  if not seen[vim.fs.normalize(dir .. "/" .. expect)] then
    fail("build_file_list missing " .. expect); return
  end
end

-- grep_files: literal substring, per-file counts, deduped
if vim.fn.executable("rg") == 1 or vim.fn.executable("grep") == 1 then
  local res = d.grep_files("hello", fbuf)
  if #res == 0 then fail("grep_files found no hello"); return end
  local count_total = 0
  local saw_alpha, saw_gamma = false, false
  for _, r in ipairs(res) do
    count_total = count_total + r.count
    if r.abs:find("alpha%.txt$") then saw_alpha = true; if r.count ~= 2 then fail("alpha count ~= 2"); return end end
    if r.abs:find("gamma%.lua$") then saw_gamma = true end
  end
  if not saw_alpha then fail("grep_files missed alpha.txt"); return end
  if not saw_gamma then fail("grep_files missed gamma.lua (nested)"); return end

  -- first_match_in_file
  local fm = d.first_match_in_file(vim.fs.normalize(dir .. "/beta.txt"), "needle")
  if fm == nil or fm.row ~= 0 then fail("first_match_in_file wrong: " .. vim.inspect(fm)); return end
  if d.first_match_in_file(vim.fs.normalize(dir .. "/beta.txt"), "absent") ~= nil then fail("first_match found absent"); return end
else
  io.stdout:write("(rg/grep absent, skipping search assertions)\n"); io.stdout:flush()
end

-- 6. grep_files with empty pattern -> empty
local eres = d.grep_files("", fbuf)
if #eres ~= 0 then fail("grep_files empty pattern should be empty"); return end

os.execute("rm -rf " .. vim.fn.shellescape(dir))
pass()