-- execution_panel/replace.lua
-- In-buffer regex replacement with live extmark preview. Owns all replace
-- logic and UI; uses the shared window/dropdown infra injected via ctx.

local discovery = require("core.execution_panel.discovery")

local M = {}
local ctx = nil

function M.init(c) ctx = c end

local function state() return ctx.state end

local function find_token(s, tok) return discovery.find_token(s, tok) end
local function find_matches_on_line(re, line) return discovery.find_matches_on_line(re, line) end

----------------------------------------------------------------- parse

-- returns: "help"|nil, match_str, replacement_str
local function parse_replace(line)
  local rest = line:gsub("^%s*/replace%s*", "")
  local r = rest:match("^%s*$")
  if r ~= nil then return nil, nil, nil end
  if rest:match("^%s*%?%s*$")
     or rest:match("^%s*help%s*$")
     or rest:match("^%s*%-h%s*$")
     or rest:match("^%s*%-help%s*$") then
    return "help", nil, nil
  end
  local m_pos = find_token(rest, "-m")
  if not m_pos then return nil, nil, nil end
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

----------------------------------------------------------------- match math

local function recompute_matches()
  local s = state()
  s.matches = {}
  if not s.re_obj then return end
  local n = vim.api.nvim_buf_line_count(s.target_buf)
  for row = 0, n - 1 do
    local line = vim.api.nvim_buf_get_lines(s.target_buf, row, row + 1, false)[1]
    for _, mm in ipairs(find_matches_on_line(s.re_obj, line)) do
      table.insert(s.matches, { row = row, col = mm.col, end_col = mm.end_col })
    end
  end
end

local function scroll_to_current()
  local s = state()
  if #s.matches == 0 then return end
  local cur = s.matches[s.current_idx]
  if not cur then return end
  if s.prev_win and vim.api.nvim_win_is_valid(s.prev_win) then
    pcall(vim.api.nvim_win_set_cursor, s.prev_win, { cur.row + 1, cur.col })
    pcall(vim.api.nvim_win_call, s.prev_win, function()
      vim.cmd("normal! zz")
    end)
    ctx.reposition_panel()
  end
end

local function draw_replace_preview()
  local s = state()
  ctx.clear_extmarks()
  if not s.re_obj or s.match_str == "" then return end
  recompute_matches()
  if #s.matches == 0 then return end
  if s.current_idx < 1 or s.current_idx > #s.matches then
    s.current_idx = 1
  end
  for _, m in ipairs(s.matches) do
    pcall(vim.api.nvim_buf_set_extmark, s.target_buf, s.ns, m.row, m.col, {
      end_col = m.end_col,
      hl_group = "ExecPanelMatch",
      priority = 101,
    })
    pcall(vim.api.nvim_buf_set_extmark, s.target_buf, s.ns, m.row, m.end_col, {
      virt_text = { { s.replacement_str, "Substitute" } },
      virt_text_pos = "inline",
      priority = 100,
    })
  end
  local cur = s.matches[s.current_idx]
  if cur then
    pcall(vim.api.nvim_buf_set_extmark, s.target_buf, s.ns, cur.row, cur.col, {
      end_col = cur.end_col,
      hl_group = "IncSearch",
      priority = 200,
    })
  end
end

local function update_replace()
  draw_replace_preview()
  scroll_to_current()
  M.render_status()
end

----------------------------------------------------------------- render

function M.render_help()
  local lines = {
    " /replace -m <match_substr_or_regex> -r <replacement>",
    " Enter        - replaces the first match at the top of the doc or currently focused match",
    " Alt + Enter  - replaces all matches in the doc",
    " Shift + Up/Down - Cycle through matches",
  }
  ctx.set_dropdown_height(#lines)
  ctx.set_dropdown(lines, nil)
end

function M.render_status()
  local s = state()
  if not s.re_valid then
    ctx.render_status(" Invalid regex ")
    return
  end
  local n = #s.matches
  if n == 0 then
    ctx.render_status(" No matches ")
    return
  end
  local cur = s.current_idx
  if cur < 1 or cur > n then cur = 1 end
  ctx.render_status(" "
    .. n .. " match" .. (n == 1 and "" or "es")
    .. "  -  current " .. cur .. "/" .. n
    .. "  -  Enter:replace one  Alt+Enter:all  J/K or S-Up/Down:cycle  Esc:close ")
end

----------------------------------------------------------------- refresh/cycle/apply

function M.refresh(line)
  local s = state()
  ctx.clear_extmarks()
  local prev_match_str = s.match_str
  s.matches = {}
  local kind, m, r = parse_replace(line)
  if kind == "help" then
    s.help = true
    s.current_idx = 1
    M.render_help()
    return
  end
  s.help = false
  local new_match_str = m or ""
  if new_match_str ~= prev_match_str then
    s.current_idx = 1
  end
  s.match_str = new_match_str
  s.replacement_str = r or ""
  if m == nil then
    ctx.render_hint()
    return
  end
  if s.match_str == "" then
    s.re_obj = nil
    s.re_valid = true
    s.current_idx = 1
    update_replace()
    return
  end
  local ok, re = pcall(vim.regex, s.match_str)
  if not ok then
    s.re_obj = nil
    s.re_valid = false
    s.current_idx = 1
    ctx.render_status(" Invalid regex: " .. tostring(re):sub(1, 40))
    return
  end
  s.re_obj = re
  s.re_valid = true
  if #s.matches > 0 and (s.current_idx < 1 or s.current_idx > #s.matches) then
    s.current_idx = 1
  end
  update_replace()
end

function M.cycle_match(dir)
  local s = state()
  if #s.matches == 0 then return end
  local n = #s.matches
  s.current_idx = s.current_idx + dir
  if s.current_idx < 1 then s.current_idx = n end
  if s.current_idx > n then s.current_idx = 1 end
  ctx.clear_extmarks()
  recompute_matches()
  if #s.matches == 0 then M.render_status(); return end
  if s.current_idx < 1 or s.current_idx > #s.matches then
    s.current_idx = 1
  end
  for _, m in ipairs(s.matches) do
    pcall(vim.api.nvim_buf_set_extmark, s.target_buf, s.ns, m.row, m.col, {
      end_col = m.end_col,
      hl_group = "ExecPanelMatch",
      priority = 101,
    })
    pcall(vim.api.nvim_buf_set_extmark, s.target_buf, s.ns, m.row, m.end_col, {
      virt_text = { { s.replacement_str, "Substitute" } },
      virt_text_pos = "inline",
      priority = 100,
    })
  end
  local cur = s.matches[s.current_idx]
  if cur then
    pcall(vim.api.nvim_buf_set_extmark, s.target_buf, s.ns, cur.row, cur.col, {
      end_col = cur.end_col,
      hl_group = "IncSearch",
      priority = 200,
    })
  end
  scroll_to_current()
  M.render_status()
end

function M.replace_one()
  local s = state()
  if #s.matches == 0 then return end
  if not s.re_valid or not s.re_obj then return end
  if s.current_idx < 1 or s.current_idx > #s.matches then
    s.current_idx = 1
  end
  local m = s.matches[s.current_idx]
  local line = vim.api.nvim_buf_get_lines(s.target_buf, m.row, m.row + 1, false)[1]
  local match_text = line:sub(m.col + 1, m.end_col)
  local resolved = vim.fn.substitute(match_text, s.match_str, s.replacement_str, "")
  local newline = line:sub(1, m.col) .. resolved .. line:sub(m.end_col + 1)
  local row = m.row
  vim.api.nvim_buf_set_lines(s.target_buf, m.row, m.row + 1, false, { newline })
  recompute_matches()
  if #s.matches == 0 then
    s.current_idx = 1
  else
    local placed = false
    for i, mm in ipairs(s.matches) do
      if mm.row > row or (mm.row == row and mm.col >= m.col) then
        s.current_idx = i
        placed = true
        break
      end
    end
    if not placed then s.current_idx = 1 end
  end
  draw_replace_preview()
  scroll_to_current()
  M.render_status()
end

function M.replace_all()
  local s = state()
  if #s.matches == 0 then return end
  if not s.re_valid or not s.re_obj then return end
  local rows = {}
  for _, m in ipairs(s.matches) do rows[m.row] = true end
  for row, _ in pairs(rows) do
    local line = vim.api.nvim_buf_get_lines(s.target_buf, row, row + 1, false)[1]
    if line then
      local newline = vim.fn.substitute(line, s.match_str, s.replacement_str, "g")
      vim.api.nvim_buf_set_lines(s.target_buf, row, row + 1, false, { newline })
    end
  end
  ctx.clear_extmarks()
  recompute_matches()
  s.current_idx = 1
  if #s.matches > 0 then
    draw_replace_preview()
    scroll_to_current()
  end
  M.render_status()
end

return M