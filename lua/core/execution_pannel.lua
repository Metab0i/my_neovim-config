-- Execution Pannel
-- A single-line input spanning the top of the viewport.
-- File search (fuzzy by path substring) and in-buffer mass-replacement
-- (/replace -m <vimregex> -r <replacement>).

local M = {}

local state = {
  open = false,
  mode = "file",        -- "file" | "replace"
  help = false,         -- true when in /replace help sub-mode
  info = false,         -- true when in /? info sub-mode
  in_buf = nil, in_win = nil,
  d_buf = nil, d_win = nil,
  dns = nil,            -- dropdown selection namespace
  augroup = nil,
  prev_win = nil,
  target_buf = nil,
  file_list = {},       -- absolute file paths
  root = nil, cwd = nil,
  query = "",
  suggestions = {},     -- {disp=,abs=} entries
  selection = 1,
  -- replace state
  match_str = "", replacement_str = "",
  re_obj = nil, re_valid = true,
  matches = {},         -- {row=,col=,end_col=}
  current_idx = 1,
  shift_ns = nil,       -- namespace for virt_lines shift extmark
  shift_id = nil,       -- extmark id for the shift
}

local ns = nil  -- buffer highlighting namespace (created lazily)

local close_panel_self  -- forward declaration

-- Number of empty virtual lines to place above row 0 of the target buffer,
-- pushing file content down below the floating panel so the top of the file
-- stays visible while the panel is open.
local SHIFT_VLINES = 6

------------------------------------------------------------------ helpers

M._is_open = function() return state.open end
M._state = function() return state end

local function relpath_under(abs, base)
  if not abs or not base then return nil end
  local a = vim.fs.normalize(abs)
  local b = vim.fs.normalize(base)
  if b == "/" then b = "" end
  if a == b then return "." end
  if vim.startswith(a, b .. "/") then return a:sub(#b + 2) end
  return nil
end

local function display_path(abs, root, cwd)
  if root then
    local r = relpath_under(abs, root)
    if r then return r end
  end
  local c = relpath_under(abs, cwd)
  if c then return c end
  return abs
end

-- locate a standalone token (e.g. "-m", "-r") in a string
local function find_token(s, tok)
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

-- find every (non-empty) match of a compiled regex on a single line
-- returns list of {col=0based_start, end_col=0based_end_exclusive}
local function find_matches_on_line(re, line)
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
      -- empty/zero-width match: advance one byte to avoid infinite loop
      pos = re_ + 1
    end
  end
  return out
end

local function recompute_matches()
  state.matches = {}
  if not state.re_obj then return end
  local n = vim.api.nvim_buf_line_count(state.target_buf)
  for row = 0, n - 1 do
    local line = vim.api.nvim_buf_get_lines(state.target_buf, row, row + 1, false)[1]
    for _, mm in ipairs(find_matches_on_line(state.re_obj, line)) do
      table.insert(state.matches, { row = row, col = mm.col, end_col = mm.end_col })
    end
  end
end

local function clear_extmarks()
  if ns and state.target_buf and vim.api.nvim_buf_is_valid(state.target_buf) then
    vim.api.nvim_buf_clear_namespace(state.target_buf, ns, 0, -1)
  end
end

local function clear_shift_extmark()
  if state.shift_ns and state.target_buf and vim.api.nvim_buf_is_valid(state.target_buf) then
    vim.api.nvim_buf_clear_namespace(state.target_buf, state.shift_ns, 0, -1)
  end
  state.shift_id = nil
end

local function set_shift_extmark()
  if not state.target_buf or not vim.api.nvim_buf_is_valid(state.target_buf) then return end
  if state.shift_ns == nil then
    state.shift_ns = vim.api.nvim_create_namespace("ExecPannelShift")
  end
  clear_shift_extmark()
  local vl = {}
  for _ = 1, SHIFT_VLINES do vl[#vl + 1] = {} end
  state.shift_id = vim.api.nvim_buf_set_extmark(state.target_buf, state.shift_ns, 0, 0, {
    virt_lines = vl,
    virt_lines_above = true,
    priority = 1,
  })
end

local function define_hl()
  if ns == nil then ns = vim.api.nvim_create_namespace("ExecPannel") end
  -- ExecPannelMatch: Search attributes + strikethrough
  local base = vim.api.nvim_get_hl(0, { name = "Search" })
  local merged = vim.tbl_deep_extend("force", base, { strikethrough = true })
  pcall(vim.api.nvim_set_hl, 0, "ExecPannelMatch", merged)
end

------------------------------------------------------------------ dropdown

local function set_dropdown(lines, selected_row)
  if not state.d_buf or not vim.api.nvim_buf_is_valid(state.d_buf) then return end
  if #lines == 0 then lines = { "" } end
  vim.api.nvim_buf_set_option(state.d_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.d_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.d_buf, "modifiable", false)
  -- selection highlight
  if state.dns then
    vim.api.nvim_buf_clear_namespace(state.d_buf, state.dns, 0, -1)
  end
  if selected_row then
    local idx = selected_row -- 0-based
    local l = lines[idx + 1] or ""
    local len = math.max(#l, 1)
    pcall(vim.api.nvim_buf_set_extmark, state.d_buf, state.dns, idx, 0, {
      end_col = len,
      hl_group = "PmenuSel",
      priority = 200,
    })
  end
end

local function set_dropdown_height(h)
  if not state.d_win or not vim.api.nvim_win_is_valid(state.d_win) then return end
  h = math.max(1, math.min(h, math.max(1, vim.o.lines - 5)))
  vim.api.nvim_win_set_height(state.d_win, h)
end

local function render_hint()
  set_dropdown({ "  /? for more info" }, nil)
  set_dropdown_height(1)
end

local function render_info()
  local lines = {
    "  Type to search for files",
    "  /replace -help  for more info on replacing text in open file",
  }
  set_dropdown_height(#lines)
  set_dropdown(lines, nil)
end

local function render_file_mode()
  set_dropdown_height(math.min(#state.suggestions, vim.o.lines - 5))
  local lines = {}
  for _, s in ipairs(state.suggestions) do
    table.insert(lines, "  " .. s.disp)
  end
  local sel = nil
  if #lines > 0 then
    sel = state.selection - 1
  end
  set_dropdown(lines, sel)
end

local function render_help()
  local lines = {
    " /replace -m <match_substr_or_regex> -r <replacement>",
    " Enter        - replaces the first match at the top of the doc or currently focused match",
    " Alt + Enter  - replaces all matches in the doc",
    " Shift + Up/Down - Cycle through matches",
  }
  set_dropdown_height(#lines)
  set_dropdown(lines, nil)
end

local function render_status(line)
  set_dropdown_height(1)
  set_dropdown({ line }, nil)
end

local function render_replace_status()
  if not state.re_valid then
    render_status(" Invalid regex ")
    return
  end
  local n = #state.matches
  if n == 0 then
    render_status(" No matches ")
    return
  end
  local cur = state.current_idx
  if cur < 1 or cur > n then cur = 1 end
  render_status(" "
    .. n .. " match" .. (n == 1 and "" or "es")
    .. "  -  current " .. cur .. "/" .. n
    .. "  -  Enter:replace one  Alt+Enter:all  J/K or S-Up/Down:cycle  Esc:close ")
end

------------------------------------------------------------------ file

local function list_files(dir)
  local files = {}
  if not dir then return files end
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--files", "--hidden", "--glob", "!.git" }
  elseif vim.fn.executable("find") == 1 then
    cmd = { "find", dir, "-type", "f", "-not", "-path", "*/.git/*" }
  else
    return files
  end
  local ok, obj = pcall(function() return vim.system(cmd, { cwd = dir, text = true }):wait() end)
  if not ok or not obj or obj.code ~= 0 or not obj.stdout then return files end
  for line in obj.stdout:gmatch("[^\r\n]+") do
    if line ~= "" then
      local abs
      if cmd[1] == "rg" then
        abs = vim.fs.normalize(dir .. "/" .. line)
      else
        abs = vim.fs.normalize(line)
      end
      table.insert(files, abs)
    end
  end
  return files
end

local function build_file_list()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local root = vim.fs.root(0, { ".git" })
  local seen = {}
  local list = {}
  local dirs = {}
  if root then table.insert(dirs, root) end
  if not root or cwd ~= vim.fs.normalize(root) then
    table.insert(dirs, cwd)
  end
  for _, d in ipairs(dirs) do
    for _, f in ipairs(list_files(d)) do
      if not seen[f] then
        seen[f] = true
        table.insert(list, f)
      end
    end
  end
  table.sort(list, function(a, b)
    local da = display_path(a, root, cwd)
    local db = display_path(b, root, cwd)
    return da:lower() < db:lower()
  end)
  return list, root, cwd
end

local function refresh_file(query)
  state.query = query
  local q = query:lower()
  local scored = {}
  for _, abs in ipairs(state.file_list) do
    local disp = display_path(abs, state.root, state.cwd)
    local base = vim.fs.basename(abs)
    local dl = disp:lower()
    local bl = base:lower()
    local bi = dl:find(q, 1, true)  -- substring in full path
    local bsi = bl:find(q, 1, true) -- substring in basename
    if bi or bsi then
      local rank = 0
      if bsi then rank = rank + 100000 - bsi end  -- basename hit dominates; earlier wins
      rank = rank + (1000 - #base)               -- shorter basename preferred
      if not bsi then rank = rank - 50000 end     -- path-only match lower than basename
      rank = rank + (1000 - #disp)               -- shorter path preferred
      table.insert(scored, { disp = disp, abs = abs, rank = rank })
    end
  end
  table.sort(scored, function(a, b) return a.rank > b.rank end)
  state.suggestions = scored
  if state.selection < 1 then state.selection = 1 end
  if state.selection > #scored then state.selection = #scored end
  if state.selection < 1 then state.selection = 1 end
  render_file_mode()
end

local function open_selection()
  if #state.suggestions == 0 then return end
  local s = state.suggestions[state.selection] or state.suggestions[1]
  if not s then return end
  local abs = s.abs
  close_panel_self()
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
end

local function move_selection(dir)
  if #state.suggestions == 0 then return end
  local n = #state.suggestions
  state.selection = state.selection + dir
  if state.selection < 1 then state.selection = n end
  if state.selection > n then state.selection = 1 end
  render_file_mode()
end

------------------------------------------------------------------ replace

local function parse_replace(line)
  -- returns: "help"|nil, match_str, replacement_str
  local rest = line:gsub("^%s*/replace%s*", "")
  local r = rest:match("^%s*$")
  if r ~= nil then return nil, nil, nil end -- bare /replace: nothing yet
  -- help tokens
  if rest:match("^%s*%?%s*$")
     or rest:match("^%s*help%s*$")
     or rest:match("^%s*%-h%s*$")
     or rest:match("^%s*%-help%s*$") then
    return "help", nil, nil
  end
  local m_pos = find_token(rest, "-m")
  if not m_pos then
    -- no -m yet: not a live replace
    return nil, nil, nil
  end
  local after_m = m_pos + 2
  local ms = after_m
  while ms <= #rest and rest:sub(ms, ms):match("%s") do ms = ms + 1 end
  local r_pos = find_token(rest, "-r")
  local match_end = #rest + 1
  if r_pos and r_pos > m_pos then
    match_end = r_pos
    while match_end - 1 >= ms and rest:sub(match_end - 1, match_end - 1):match("%s") do
      match_end = match_end - 1
    end
  end
  local match_str = rest:sub(ms, match_end - 1)
  local replacement_str = ""
  if r_pos and r_pos > m_pos then
    local after_r = r_pos + 2
    local rs = after_r
    while rs <= #rest and rest:sub(rs, rs):match("%s") do rs = rs + 1 end
    replacement_str = rest:sub(rs)
  end
  return nil, match_str, replacement_str
end

local function scroll_to_current()
  if #state.matches == 0 then return end
  local cur = state.matches[state.current_idx]
  if not cur then return end
  if state.prev_win and vim.api.nvim_win_is_valid(state.prev_win) then
    pcall(vim.api.nvim_win_set_cursor, state.prev_win, { cur.row + 1, cur.col })
    pcall(vim.api.nvim_win_call, state.prev_win, function()
      vim.cmd("normal! zz")
    end)
  end
end

local function draw_replace_preview()
  clear_extmarks()
  if not state.re_obj or state.match_str == "" then return end
  recompute_matches()
  if #state.matches == 0 then return end
  if state.current_idx < 1 or state.current_idx > #state.matches then
    state.current_idx = 1
  end
  for _, m in ipairs(state.matches) do
    pcall(vim.api.nvim_buf_set_extmark, state.target_buf, ns, m.row, m.col, {
      end_col = m.end_col,
      hl_group = "ExecPannelMatch",
      priority = 101,
    })
    pcall(vim.api.nvim_buf_set_extmark, state.target_buf, ns, m.row, m.end_col, {
      virt_text = { { state.replacement_str, "Substitute" } },
      virt_text_pos = "inline",
      priority = 100,
    })
  end
  local cur = state.matches[state.current_idx]
  if cur then
    pcall(vim.api.nvim_buf_set_extmark, state.target_buf, ns, cur.row, cur.col, {
      end_col = cur.end_col,
      hl_group = "IncSearch",
      priority = 200,
    })
  end
end

local function update_replace()
  draw_replace_preview()
  scroll_to_current()
  render_replace_status()
end

local function refresh_replace(line)
  clear_extmarks()
  local prev_match_str = state.match_str
  state.matches = {}
  local kind, m, r = parse_replace(line)
  if kind == "help" then
    state.help = true
    state.current_idx = 1
    render_help()
    return
  end
  state.help = false
  local new_match_str = m or ""
  -- only reset the cycle pointer when the regex (-m) actually changes;
  -- editing the replacement (-r) or cycling must NOT move the pointer.
  if new_match_str ~= prev_match_str then
    state.current_idx = 1
  end
  state.match_str = new_match_str
  state.replacement_str = r or ""
  if m == nil then
    -- not yet a valid replace form (missing -m) -> show hint
    render_hint()
    return
  end
  if state.match_str == "" then
    state.re_obj = nil
    state.re_valid = true
    state.current_idx = 1
    update_replace() -- shows "No matches"
    return
  end
  local ok, re = pcall(vim.regex, state.match_str)
  if not ok then
    state.re_obj = nil
    state.re_valid = false
    state.current_idx = 1
    render_status(" Invalid regex: " .. tostring(re):sub(1, 40))
    return
  end
  state.re_obj = re
  state.re_valid = true
  -- clamp pointer into the (possibly new) match list
  if #state.matches > 0 and (state.current_idx < 1 or state.current_idx > #state.matches) then
    state.current_idx = 1
  end
  update_replace()
end

local function cycle_match(dir)
  if #state.matches == 0 then return end
  local n = #state.matches
  state.current_idx = state.current_idx + dir
  if state.current_idx < 1 then state.current_idx = n end
  if state.current_idx > n then state.current_idx = 1 end
  -- redraw IncSearch overlay without full rescan
  clear_extmarks()
  recompute_matches()
  if #state.matches == 0 then render_replace_status(); return end
  if state.current_idx < 1 or state.current_idx > #state.matches then
    state.current_idx = 1
  end
  for i, m in ipairs(state.matches) do
    pcall(vim.api.nvim_buf_set_extmark, state.target_buf, ns, m.row, m.col, {
      end_col = m.end_col,
      hl_group = "ExecPannelMatch",
      priority = 101,
    })
    pcall(vim.api.nvim_buf_set_extmark, state.target_buf, ns, m.row, m.end_col, {
      virt_text = { { state.replacement_str, "Substitute" } },
      virt_text_pos = "inline",
      priority = 100,
    })
  end
  local cur = state.matches[state.current_idx]
  if cur then
    pcall(vim.api.nvim_buf_set_extmark, state.target_buf, ns, cur.row, cur.col, {
      end_col = cur.end_col,
      hl_group = "IncSearch",
      priority = 200,
    })
  end
  scroll_to_current()
  render_replace_status()
end

local function replace_one()
  if #state.matches == 0 then return end
  if not state.re_valid or not state.re_obj then return end
  if state.current_idx < 1 or state.current_idx > #state.matches then
    state.current_idx = 1
  end
  local m = state.matches[state.current_idx]
  local line = vim.api.nvim_buf_get_lines(state.target_buf, m.row, m.row + 1, false)[1]
  local match_text = line:sub(m.col + 1, m.end_col)
  local resolved = vim.fn.substitute(match_text, state.match_str, state.replacement_str, "")
  local newline = line:sub(1, m.col) .. resolved .. line:sub(m.end_col + 1)
  local row = m.row
  -- commit replacement
  vim.api.nvim_buf_set_lines(state.target_buf, m.row, m.row + 1, false, { newline })
  -- recompute and advance current index to first match at/below the replaced row
  recompute_matches()
  if #state.matches == 0 then
    state.current_idx = 1
  else
    local placed = false
    for i, mm in ipairs(state.matches) do
      if mm.row > row or (mm.row == row and mm.col >= m.col) then
        state.current_idx = i
        placed = true
        break
      end
    end
    if not placed then state.current_idx = 1 end
  end
  draw_replace_preview()
  scroll_to_current()
  render_replace_status()
end

local function replace_all()
  if #state.matches == 0 then return end
  if not state.re_valid or not state.re_obj then return end
  local rows = {}
  for _, m in ipairs(state.matches) do rows[m.row] = true end
  for row, _ in pairs(rows) do
    local line = vim.api.nvim_buf_get_lines(state.target_buf, row, row + 1, false)[1]
    if line then
      local newline = vim.fn.substitute(line, state.match_str, state.replacement_str, "g")
      vim.api.nvim_buf_set_lines(state.target_buf, row, row + 1, false, { newline })
    end
  end
  clear_extmarks()
  recompute_matches()
  state.current_idx = 1
  if #state.matches > 0 then
    draw_replace_preview()
    scroll_to_current()
  end
  render_replace_status()
end

------------------------------------------------------------------ refresh

local function refresh()
  if not state.open then return end
  if state._in_refresh then return end   -- guard against recursive TextChangedI
  state._in_refresh = true
  local line = vim.api.nvim_buf_get_lines(state.in_buf, 0, 1, false)[1] or ""
  if line == "" then
    state.mode = "file"
    state.help = false
    state.info = false
    clear_extmarks()
    state.matches = {}
    state.query = ""
    render_hint()
  elseif line:match("^%s*/%?%s*$") then
    state.mode = "file"
    state.help = false
    state.info = true
    clear_extmarks()
    state.matches = {}
    render_info()
  elseif line:match("^%s*/replace") then
    state.mode = "replace"
    state.info = false
    refresh_replace(line)
  else
    state.mode = "file"
    state.help = false
    state.info = false
    clear_extmarks()
    state.matches = {}
    refresh_file(line)
  end
  state._in_refresh = false
end

------------------------------------------------------------------ open/close

function close_panel_self()
  clear_extmarks()
  clear_shift_extmark()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_name, state.augroup)
    state.augroup = nil
  end
  if state.d_win and vim.api.nvim_win_is_valid(state.d_win) then
    pcall(vim.api.nvim_win_close, state.d_win, true)
  end
  if state.in_win and vim.api.nvim_win_is_valid(state.in_win) then
    pcall(vim.api.nvim_win_close, state.in_win, true)
  end
  if state.d_buf and vim.api.nvim_buf_is_valid(state.d_buf) then
    pcall(vim.api.nvim_buf_delete, state.d_buf, { force = true })
  end
  if state.in_buf and vim.api.nvim_buf_is_valid(state.in_buf) then
    pcall(vim.api.nvim_buf_delete, state.in_buf, { force = true })
  end
  state.in_win, state.d_win, state.in_buf, state.d_buf = nil, nil, nil, nil
  state.dns = nil
  state.suggestions = {}
  state.selection = 1
  state.matches = {}
  state.current_idx = 1
  state.re_obj = nil
  state.mode = "file"
  state.help = false
  state.info = false
  state.open = false
  if state.prev_win and vim.api.nvim_win_is_valid(state.prev_win) then
    pcall(vim.api.nvim_set_current_win, state.prev_win)
  end
  state.prev_win = nil
  state.target_buf = nil
  pcall(vim.cmd, "stopinsert")
end

local function set_keymaps()
  local opts = { buffer = state.in_buf, nowait = true, silent = true }

  vim.keymap.set({ "i", "n" }, "<Esc>", close_panel_self, opts)

  vim.keymap.set("i", "<CR>", function()
    if state.mode == "replace" then
      if not state.help then replace_one() end
    elseif not state.info then
      open_selection()
    end
  end, opts)

  vim.keymap.set("i", "<M-CR>", function()
    if state.mode == "replace" and not state.help then replace_all() end
  end, opts)

  vim.keymap.set("i", "<Tab>", function()
    if state.mode == "file" and not state.info then move_selection(1) end
  end, opts)
  vim.keymap.set("i", "<S-Tab>", function()
    if state.mode == "file" and not state.info then move_selection(-1) end
  end, opts)
  vim.keymap.set("i", "<Down>", function()
    if state.mode == "file" and not state.info then move_selection(1) end
  end, opts)
  vim.keymap.set("i", "<Up>", function()
    if state.mode == "file" and not state.info then move_selection(-1) end
  end, opts)

  vim.keymap.set("i", "<S-Down>", function()
    if state.mode == "replace" and not state.help then cycle_match(1)
    elseif not state.info then move_selection(1) end
  end, opts)
  vim.keymap.set("i", "<S-Up>", function()
    if state.mode == "replace" and not state.help then cycle_match(-1)
    elseif not state.info then move_selection(-1) end
  end, opts)

  -- J / K : cycle matches in replace mode; type the letter otherwise.
  -- Non-expr so cycle_match can modify buffers/windows (expr maps run under
  -- textlock, which forbids buffer/window changes -> E565).
  vim.keymap.set("i", "J", function()
    if state.mode == "replace" and not state.help then
      cycle_match(1)
    else
      vim.api.nvim_feedkeys("J", "n", false)
    end
  end, { buffer = state.in_buf, silent = true, nowait = true })
  vim.keymap.set("i", "K", function()
    if state.mode == "replace" and not state.help then
      cycle_match(-1)
    else
      vim.api.nvim_feedkeys("K", "n", false)
    end
  end, { buffer = state.in_buf, silent = true, nowait = true })
end

local function open_panel()
  if state.open then return end
  state.prev_win = vim.api.nvim_get_current_win()
  state.target_buf = vim.api.nvim_get_current_buf()
  state.open = true
  state.mode = "file"
  state.help = false
  state.info = false
  state.query = ""
  state.selection = 1
  state.matches = {}
  state.current_idx = 1
  state.match_str = ""
  state.replacement_str = ""
  state.re_obj = nil
  state.re_valid = true

  state.file_list, state.root, state.cwd = build_file_list()

  set_shift_extmark()

  local cols = vim.o.columns
  local pad = 5

  state.in_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.in_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.in_buf, "bufhidden", "wipe")

  state.in_win = vim.api.nvim_open_win(state.in_buf, true, {
    relative = "editor",
    row = 0, col = pad,
    width = math.max(3, cols - pad * 2), height = 1,
    style = "minimal", border = "rounded",
    focusable = true, noautocmd = true,
  })

  state.d_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.d_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.d_buf, "bufhidden", "wipe")

  state.d_win = vim.api.nvim_open_win(state.d_buf, false, {
    relative = "editor",
    row = 3, col = pad,
    width = math.max(3, cols - pad * 2), height = math.max(1, vim.o.lines - 5),
    style = "minimal", border = "rounded",
    focusable = false, noautocmd = true,
  })
  pcall(function()
    vim.wo[state.d_win].winhighlight = "Normal:Pmenu,NormalNC:Pmenu"
  end)

  state.dns = vim.api.nvim_create_namespace("ExecPannelDropdown")
  if ns == nil then ns = vim.api.nvim_create_namespace("ExecPannel") end
  define_hl()

  set_keymaps()

  state.augroup = "ExecPannelAuto"
  vim.api.nvim_create_augroup(state.augroup, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = state.augroup,
    buffer = state.in_buf,
    callback = refresh,
  })

  render_hint()
  vim.api.nvim_set_current_win(state.in_win)
  vim.cmd("startinsert")
end

M.toggle = function()
  if state.open then
    close_panel_self()
  else
    open_panel()
  end
end

M.open = open_panel
M.close = close_panel_self

vim.keymap.set("n", "<leader><leader>", M.toggle, { desc = "Execution pannel" })

return M