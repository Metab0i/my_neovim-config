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
local DEBOUNCE_MS = 100

-- Per-search staleness token. Bumped in schedule_search on every keystroke and
-- captured by the async rg callback (local `my = token` at dispatch); the
-- callback bails if `my ~= token` -- a newer keystroke superseded this search --
-- or if the panel has closed (`not state().open`). This is the critical guard
-- that lets the cross-file search run async (vim.system, non-blocking) without
-- a slow older rg landing over a newer search and rendering stale results.
local token = 0

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

-- literal pattern escaped as a very-nomagic (\V) vim regex, shared by both the
-- search-register hand-off (set_search_hl) and the window-local preview highlight
-- (highlight_preview) so they match the exact same ranges.
local function esc_literal(pattern)
  return "\\V" .. (pattern:gsub("\\", "\\\\"))
end

-- hand the pattern to @/ + hlsearch for n/N continuation. Called ONLY on open
-- (Enter), never while typing: writing @/ during live preview was clobbering the
-- search register as the user typed and interfering with input capture.
local function set_search_hl(pattern)
  if pattern == "" then vim.fn.setreg("/", ""); return end
  pcall(vim.fn.setreg, "/", esc_literal(pattern))
  pcall(function() vim.o.hlsearch = true end)
end

-- window-local match highlight for the live preview, independent of @/. Tracks
-- its own match id on state().fstr._match_id and clears via matchdelete (NOT
-- clearmatches, which would wipe the user's own window-local matches in their
-- real editing window).
local function clear_preview_highlight(win)
  local f = F()
  if f._match_id then
    pcall(vim.fn.matchdelete, f._match_id, win)
    f._match_id = nil
  end
end

local function highlight_preview(win, pattern)
  clear_preview_highlight(win)
  if pattern and pattern ~= "" then
    local id = vim.fn.matchadd("ExecPanelMatch", esc_literal(pattern), 10, -1, { window = win })
    if id and id > 0 then F()._match_id = id end
  end
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
  highlight_preview(win, pattern)
  if row ~= nil and col ~= nil then
    pcall(vim.api.nvim_win_set_cursor, win, { row + 1, col })
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
  end
  return buf
end

local function preview_highlighted()
  local s = state()
  local f = F()
  local my = token
  local res = f.results[f.selection]
  if not res then return end
  local abs = res.abs
  local buf = load_preview(abs, nil, nil, f.pattern)
  if not buf then return end
  local mlist = discovery.line_matches_in_file(buf, f.pattern)
  f.match_list = mlist
  if #mlist == 0 then
    f.match_idx = 1
    -- the in-memory scan found nothing (e.g. file not yet fully loaded); fall
    -- back to a single-file rg. Async so the main loop isn't blocked; guarded
    -- against a newer search (my ~= token) or a closed panel so a stale position
    -- isn't applied over the current selection.
    discovery.first_match_in_file_async(abs, f.pattern, function(first)
      if my ~= token or not state().open then return end
      if first then
        local pw = state().prev_win
        if pw and vim.api.nvim_win_is_valid(pw) then
          pcall(vim.api.nvim_win_set_cursor, pw, { first.row + 1, first.col })
          pcall(vim.api.nvim_win_call, pw, function() vim.cmd("normal! zz") end)
        end
      end
    end)
    return
  end
  f.match_idx = 1
  local m = mlist[1]
  pcall(vim.api.nvim_win_set_cursor, s.prev_win, { m.row + 1, m.col })
  pcall(vim.api.nvim_win_call, s.prev_win, function() vim.cmd("normal! zz") end)
end

----------------------------------------------------------------- search

local function do_search(my, pattern)
  local bufnr_now
  do local s0 = state(); bufnr_now = s0.target_buf end
  discovery.grep_files_async(pattern, bufnr_now, function(results)
    -- staleness: a newer keystroke superseded this search (token bumped in
    -- schedule_search), or the panel closed before the async rg landed. Without
    -- this guard a slow older rg would render stale results over the newer search.
    if my ~= token or not state().open then
      return
    end
    local s = state()
    local f = F()
    table.sort(results, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return (a.disp or ""):lower() < (b.disp or ""):lower()
    end)
    f.results = results
    if f.selection > #results then f.selection = math.max(1, #results) end
    if f.selection < 1 then f.selection = 1 end
    M.render()
    if #results > 0 then
      if not (s.prev_win and vim.api.nvim_win_is_valid(s.prev_win)) then return end
      local current = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(s.prev_win))
      if results[f.selection].abs ~= current then
        preview_highlighted()
      else
        -- same file still shown; refresh its highlight, match list + cursor
        highlight_preview(s.prev_win, pattern)
        local buf = vim.api.nvim_win_get_buf(s.prev_win)
        f.match_list = discovery.line_matches_in_file(buf, pattern)
        f.match_idx = 1
        local m = f.match_list[1]
        if m then
          pcall(vim.api.nvim_win_set_cursor, s.prev_win, { m.row + 1, m.col })
          pcall(vim.api.nvim_win_call, s.prev_win, function() vim.cmd("normal! zz") end)
        end
      end
    else
      clear_preview_highlight(s.prev_win)
      f.match_list = {}
      f.match_idx = 1
    end
  end)
end

local function schedule_search(pattern)
  local f = F()
  if f._timer then
    pcall(function() f._timer:stop() end)
    pcall(function() f._timer:close() end)
    f._timer = nil
  end
  token = token + 1  -- invalidate any in-flight async search against this new keystroke
  local my = token
  f._timer = vim.defer_fn(function()
    f._timer = nil
    do_search(my, pattern)
  end, DEBOUNCE_MS)
end

----------------------------------------------------------------- public

function M.refresh(line)
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
    clear_preview_highlight(s.prev_win)
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
  clear_preview_highlight(s.prev_win)  -- hlsearch now owns the highlight
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
  clear_preview_highlight(o.win)
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