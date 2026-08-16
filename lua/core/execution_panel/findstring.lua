-- execution_panel/findstring.lua
-- UI + integration for the /fstr command: cross-file literal-substring search.
-- Discovery (which files/contents are searched, exclusion rules) lives in
-- discovery.lua; this module owns the suggestion list, right-aligned counts,
-- live preview in the underlying window, in-file occurrence cycling and
-- Enter-to-open with the search register handed off for n/N continuation.
--
-- Usage: in the panel, type  /fstr <literal-substring>
--   - <Up>/<Down>   cycle files
--   - <Tab>/<S-Tab> cycle occurrences within the highlighted file
--   - <Enter>       open the highlighted file, hand the pattern to @/ for n/N
--   - <Esc>         restore original file + cursor + original @/, close panel
--
-- Navigation history (core/navhistory) is suppressed while a preview is active so
-- cycling files doesn't pollute the back/forward ring.

local discovery = require("core.execution_panel.discovery")
local navhistory = require("core.navhistory")

local M = {}
local ctx = nil
local DEBOUNCE_MS = 150

function M.init(c) ctx = c end

local function state() return ctx.state end
local function F() return state().fstr end

local function dropdown_inner_width()
  local pad = 5
  local w = math.max(3, vim.o.columns - pad * 2)
  return math.max(6, w - 2)
end

----------------------------------------------------------------- activate / origin

-- capture the underlying editor state once (file/cursor/search) so Esc restores it
local function capture_origin()
  local s = state()
  if state().origin then return end
  s.origin = {
    win = s.prev_win,
    buf = s.target_buf,
    abs = vim.api.nvim_buf_get_name(s.target_buf),
    pos = (s.prev_win and vim.api.nvim_win_is_valid(s.prev_win))
        and vim.api.nvim_win_get_cursor(s.prev_win) or { 1, 0 },
    search = vim.fn.getreg("/"),
    hlsearch = vim.o.hlsearch,
  }
end

local function rjustify(left, count)
  local inner = dropdown_inner_width()
  local cnt = tostring(count)
  if #left >= inner - #cnt then
    left = left:sub(1, math.max(1, inner - #cnt - 2)) .. "…"
  end
  local gap = math.max(1, inner - #left - #cnt)
  return left .. string.rep(" ", gap) .. cnt
end

----------------------------------------------------------------- preview / highlighting

local function set_search_hl(pattern)
  if pattern == "" then vim.fn.setreg("/", ""); return end
  local p = "\\V" .. (pattern:gsub("\\", "\\\\"))
  pcall(vim.fn.setreg, "/", p)
  pcall(function() vim.o.hlsearch = true end)
end

local function load_preview(abs, row, col, pattern)
  local s = state()
  local win = s.prev_win
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local buf
  pcall(vim.api.nvim_win_call, win, function()
    local cur = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if cur ~= abs then
      pcall(vim.cmd, "edit " .. vim.fn.fnameescape(abs))
    end
  end)
  buf = vim.api.nvim_win_get_buf(win)
  F().preview_abs = abs
  set_search_hl(pattern)
  if row ~= nil and col ~= nil then
    pcall(vim.api.nvim_win_set_cursor, win, { row + 1, col })
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
  end
  return buf
end

local function preview_highlighted()
  local s = state()
  local f = F()
  local res = f.results[f.selection]
  if not res then return end
  local abs = res.abs
  local buf = load_preview(abs, nil, nil, f.pattern)
  if not buf then return end
  local mlist = discovery.line_matches_in_file(buf, f.pattern)
  f.match_list = mlist
  if #mlist == 0 then
    f.match_idx = 1
    local first = discovery.first_match_in_file(abs, f.pattern)
    if first then
      pcall(vim.api.nvim_win_set_cursor, s.prev_win, { first.row + 1, first.col })
      pcall(vim.api.nvim_win_call, s.prev_win, function() vim.cmd("normal! zz") end)
    end
    return
  end
  f.match_idx = 1
  local m = mlist[1]
  pcall(vim.api.nvim_win_set_cursor, s.prev_win, { m.row + 1, m.col })
  pcall(vim.api.nvim_win_call, s.prev_win, function() vim.cmd("normal! zz") end)
end

----------------------------------------------------------------- search

local function do_search(pattern)
  local s = state()
  local f = F()
  local results = discovery.grep_files(pattern, s.target_buf)
  table.sort(results, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return (a.disp or ""):lower() < (b.disp or ""):lower()
  end)
  f.results = results
  if f.selection > #results then f.selection = math.max(1, #results) end
  if f.selection < 1 then f.selection = 1 end
  M.render()
  if #results > 0 then
    local current = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(s.prev_win))
    if results[f.selection].abs ~= current then
      preview_highlighted()
    else
      -- same file still shown; refresh its match list + cursor
      local buf = vim.api.nvim_win_get_buf(s.prev_win)
      f.match_list = discovery.line_matches_in_file(buf, f.pattern)
      f.match_idx = 1
      local m = f.match_list[1]
      if m then
        pcall(vim.api.nvim_win_set_cursor, s.prev_win, { m.row + 1, m.col })
        pcall(vim.api.nvim_win_call, s.prev_win, function() vim.cmd("normal! zz") end)
      end
    end
  else
    f.match_list = {}
    f.match_idx = 1
  end
end

local function schedule_search(pattern)
  local f = F()
  if f._timer then
    pcall(function() f._timer:stop() end)
    pcall(function() f._timer:close() end)
    f._timer = nil
  end
  f._timer = vim.defer_fn(function()
    f._timer = nil
    do_search(pattern)
  end, DEBOUNCE_MS)
end

----------------------------------------------------------------- public

function M.refresh(line)
  local s = state()
  local f = F()
  f.active = true
  capture_origin()
  if navhistory and navhistory.pause then navhistory.pause() end
  local pat = line:match("^%s*/fstr%s+(.*)$") or ""
  f.pattern = pat
  if pat == "" then
    f.results = {}
    f.match_list = {}
    f.match_idx = 1
    f.preview_abs = nil
    -- restore original so no half-baked preview lingers
    M.restore_origin(false)
    ctx.render_hint_fstr()
    return
  end
  schedule_search(pat)
end

function M.render()
  local s = state()
  local f = F()
  if #f.results == 0 then
    ctx.render_status(f.pattern == "" and "  /fstr <literal-substring>" or " No files matched ")
    return
  end
  local lines = {}
  for _, r in ipairs(f.results) do
    table.insert(lines, rjustify("  " .. r.disp, r.count))
  end
  ctx.set_dropdown_height(math.min(#lines, vim.o.lines - 5))
  ctx.set_dropdown(lines, f.selection - 1)
end

function M.move_file(dir)
  local s = state()
  local f = F()
  if #f.results == 0 then return end
  local n = #f.results
  f.selection = f.selection + dir
  if f.selection < 1 then f.selection = n end
  if f.selection > n then f.selection = 1 end
  M.render()
  preview_highlighted()
end

function M.cycle_match(dir)
  local s = state()
  local f = F()
  if #f.match_list == 0 then return end
  local n = #f.match_list
  f.match_idx = f.match_idx + dir
  if f.match_idx < 1 then f.match_idx = n end
  if f.match_idx > n then f.match_idx = 1 end
  local m = f.match_list[f.match_idx]
  if m and s.prev_win and vim.api.nvim_win_is_valid(s.prev_win) then
    pcall(vim.api.nvim_win_set_cursor, s.prev_win, { m.row + 1, m.col })
    pcall(vim.api.nvim_win_call, s.prev_win, function() vim.cmd("normal! zz") end)
  end
end

function M.open()
  local s = state()
  local f = F()
  local res = f.results[f.selection]
  if not res then
    f.active = false
    f.preview_abs = nil
    ctx.close()
    if navhistory and navhistory.resume then navhistory.resume() end
    return
  end
  local abs = res.abs
  local pattern = f.pattern
  local first = discovery.first_match_in_file(abs, pattern) or { row = 0, col = 0 }
  -- preview/open the chosen file at its first match, set @/ for n/N continuation
  load_preview(abs, first.row, first.col, pattern)
  set_search_hl(pattern)
  -- mark inactive so close()'s on_close does not restore origin over the chosen file
  f.active = false
  f.preview_abs = nil
  ctx.close()
  if navhistory and navhistory.resume then navhistory.resume() end
end

-- restore original file + cursor + original @/. keep_paused_after keeps navhistory
-- suppressed across the restore so the restore edits/jumps don't record.
function M.restore_origin(keep_paused_after)
  local s = state()
  local f = F()
  if not state().origin then return end
  local o = state().origin
  if not o.win or not vim.api.nvim_win_is_valid(o.win) then return end
  if o.abs and o.abs ~= "" then
    pcall(vim.api.nvim_win_call, o.win, function()
      local cur = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(o.win))
      if cur ~= o.abs then
        pcall(vim.cmd, "edit " .. vim.fn.fnameescape(o.abs))
      end
    end)
  end
  pcall(vim.api.nvim_win_set_cursor, o.win, o.pos)
  pcall(vim.fn.setreg, "/", o.search or "")
  pcall(function() vim.o.hlsearch = o.hlsearch end)
  if not keep_paused_after then
    if navhistory and navhistory.resume then navhistory.resume() end
  end
  f.preview_abs = nil
end

-- called from the panel's Esc/close handler: restore origin if a preview was left loaded
function M.on_close()
  local s = state()
  if not F().active then return end
  M.restore_origin(false)
end

return M