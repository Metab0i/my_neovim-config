-- execution_panel/discovery.lua
-- Centralized file- and content-search rules for the execution panel.
-- Pure logic, no UI: the rules around which directories are searched and what
-- is excluded, shared by the file-find and string-find submodules.

local M = {}

----------------------------------------------------------------- path helpers

local function relpath_under(abs, base)
  if not abs or not base then return nil end
  local a = vim.fs.normalize(abs)
  local b = vim.fs.normalize(base)
  if b == "/" then b = "" end
  if a == b then return "." end
  if vim.startswith(a, b .. "/") then return a:sub(#b + 2) end
  return nil
end
M._relpath_under = relpath_under

function M.display_path(abs, root, cwd)
  if root then
    local r = relpath_under(abs, root)
    if r then return r end
  end
  local c = relpath_under(abs, cwd)
  if c then return c end
  return abs
end

-- ordered, deduped set of directories to search for the file whose buffer is
-- `bufnr`: the file's own directory, its git root, then nvim's cwd.
function M.search_dirs(bufnr)
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local name = bufnr and vim.api.nvim_buf_get_name(bufnr) or ""
  local file_dir = (name ~= "" and vim.fs.dirname(vim.fs.normalize(name))) or nil
  local git_root = nil
  if bufnr then git_root = vim.fs.root(bufnr, { ".git" }) end
  local seen, dirs = {}, {}
  local function add(d)
    if not d then return end
    d = vim.fs.normalize(d)
    if seen[d] then return end
    seen[d] = true
    table.insert(dirs, d)
  end
  add(file_dir); add(git_root); add(cwd)
  return dirs, file_dir, cwd
end

----------------------------------------------------------------- shell helper

local function run(cmd, cwd)
  local ok, obj = pcall(function() return vim.system(cmd, { cwd = cwd, text = true }):wait() end)
  if not ok or not obj or obj.code ~= 0 or not obj.stdout then return nil end
  return obj.stdout
end

----------------------------------------------------------------- file discovery

function M.list_files(dir)
  local files = {}
  if not dir then return files end
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--files", "--hidden",
      "--glob", "!.git", "--glob", "!.git/**",
      "--glob", "!node_modules", "--glob", "!node_modules/**" }
  elseif vim.fn.executable("find") == 1 then
    cmd = { "find", dir, "-type", "f",
      "-not", "-path", "*/.git/*",
      "-not", "-path", "*/node_modules/*" }
  else
    return files
  end
  local out = run(cmd, dir)
  if not out then return files end
  for line in out:gmatch("[^\r\n]+") do
    if line ~= "" then
      local abs
      if cmd[1] == "rg" then abs = vim.fs.normalize(dir .. "/" .. line)
      else abs = vim.fs.normalize(line) end
      table.insert(files, abs)
    end
  end
  return files
end

function M.build_file_list(bufnr)
  local dirs, file_dir, cwd = M.search_dirs(bufnr)
  local seen, list = {}, {}
  for _, d in ipairs(dirs) do
    for _, f in ipairs(M.list_files(d)) do
      if not seen[f] then seen[f] = true; table.insert(list, f) end
    end
  end
  table.sort(list, function(a, b)
    return M.display_path(a, file_dir, cwd):lower() < M.display_path(b, file_dir, cwd):lower()
  end)
  return list, file_dir, cwd
end

----------------------------------------------------------------- content search

-- Locate a standalone token (e.g. "-m", "-r") in a string.
function M.find_token(s, tok)
  local i = 1
  while true do
    local j = s:find(tok, i, true)
    if not j then return nil end
    local left_ok = (j == 1) or (s:sub(j - 1, j - 1):match("%s") ~= nil)
    local after = j + #tok
    local right_ok = (after > #s) or (s:sub(after, after):match("%s") ~= nil)
    if left_ok and right_ok then return j end
    i = j + 1
  end
end

-- every non-empty match of a compiled vim regex on a single line
-- returns list of {col=0based_start, end_col=0based_end_exclusive}
function M.find_matches_on_line(re, line)
  local out = {}
  if line == nil then return out end
  local pos = 0
  while pos <= #line do
    local sub = line:sub(pos + 1)
    local s, e = re:match_str(sub)
    if not s then break end
    local rs = pos + s
    local re_ = pos + e
    if re_ > rs then
      table.insert(out, { col = rs, end_col = re_ })
      pos = re_
    else
      pos = re_ + 1
    end
  end
  return out
end

-- Cross-file literal-substring search. Returns results = list of
-- { abs, count, disp }, plus file_dir/cwd for relative display.
-- `count` is total occurrences (rg --count-matches / equivalent).
function M.grep_files(pattern, bufnr)
  local results = {}
  if pattern == "" then return results, nil, nil end
  local dirs, file_dir, cwd = M.search_dirs(bufnr)

  if vim.fn.executable("rg") == 1 then
    for _, d in ipairs(dirs) do
      local cmd = { "rg", "-F", "--count-matches", "--no-heading", "-n",
        "--glob", "!.git", "--glob", "!.git/**",
        "--glob", "!node_modules", "--glob", "!node_modules/**",
        "--", pattern, d }
      local out = run(cmd)
      if out then
        for line in out:gmatch("[^\r\n]+") do
          local path, cnt = line:match("^(.-):(%d+)%s*$")
          if path and cnt then
            table.insert(results, { abs = vim.fs.normalize(path), count = tonumber(cnt) or 0 })
          end
        end
      end
    end
  elseif vim.fn.executable("grep") == 1 then
    for _, d in ipairs(dirs) do
      local cmd = { "grep", "-rIonF",
        "--exclude-dir=.git", "--exclude-dir=node_modules",
        "--", pattern, d }
      local out = run(cmd)
      local counts = {}
      if out then
        for line in out:gmatch("[^\r\n]+") do
          local path = line:match("^(.-):%d+:")
          if path then counts[path] = (counts[path] or 0) + 1 end
        end
      end
      for p, c in pairs(counts) do
        table.insert(results, { abs = vim.fs.normalize(p), count = c })
      end
    end
  end

  local seen, dedup = {}, {}
  for _, r in ipairs(results) do
    if not seen[r.abs] then
      seen[r.abs] = true
      table.insert(dedup, { abs = r.abs, count = r.count, disp = M.display_path(r.abs, file_dir, cwd) })
    end
  end
  return dedup, file_dir, cwd
end

-- first occurrence of literal `pattern` in file `abs`
-- returns {row=0based, col=0based_byte, end_col=0based_exclusive} or nil
function M.first_match_in_file(abs, pattern)
  if not pattern or pattern == "" or not abs then return nil end
  if vim.fn.executable("rg") == 1 then
    local cmd = { "rg", "--column", "-n", "-F", "--no-heading", "-m", "1", "--", pattern, abs }
    local out = run(cmd)
    if not out then return nil end
    local line = out:match("([^\r\n]+)")
    if not line then return nil end
    local row, col = line:match("^(%d+):(%d+):")
    if row and col then
      return { row = tonumber(row) - 1, col = tonumber(col) - 1, end_col = tonumber(col) - 1 + #pattern }
    end
    return nil
  end
  if vim.fn.executable("grep") == 1 then
    local cmd = { "grep", "-nF", "--", pattern, abs }
    local out = run(cmd)
    if not out then return nil end
    local line = out:match("([^\r\n]+)")
    if not line then return nil end
    local rowstr = line:match("^(%d+):")
    if not rowstr then return nil end
    local content = line:sub(#rowstr + 2)
    local s = content:find(pattern, 1, true)
    if not s then return nil end
    return { row = tonumber(rowstr) - 1, col = s - 1, end_col = s - 1 + #pattern }
  end
  return nil
end

-- all occurrences of literal `pattern` in a loaded buffer `bufnr`
-- returns list of {row=0based, col=0based_byte, end_col=0based_exclusive}
function M.line_matches_in_file(bufnr, pattern)
  local out = {}
  if not pattern or pattern == "" or not bufnr then return out end
  if not vim.api.nvim_buf_is_valid(bufnr) then return out end
  local n = vim.api.nvim_buf_line_count(bufnr)
  for row = 0, n - 1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    if line then
      local start = 1
      while true do
        local s, e = line:find(pattern, start, true)
        if not s then break end
        table.insert(out, { row = row, col = s - 1, end_col = e })
        start = e + 1
      end
    end
  end
  return out
end

return M