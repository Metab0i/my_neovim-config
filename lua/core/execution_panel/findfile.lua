-- execution_panel/findfile.lua
-- UI + integration for file discovery. Uses discovery.build_file_list for the
-- universe of files and this module owns the fuzzy filtering, suggestion list,
-- rendering and open logic.

local discovery = require("core.execution_panel.discovery")

local M = {}
local ctx = nil

function M.init(c) ctx = c end

local function state() return ctx.state end

local function display_path(abs)
  return discovery.display_path(abs, state().root, state().cwd)
end

local function refresh_file(query)
  state().query = query
  local q = query:lower()
  local scored = {}
  for _, abs in ipairs(state().file_list) do
    local disp = display_path(abs)
    local base = vim.fs.basename(abs)
    local dl = disp:lower()
    local bl = base:lower()
    local bi = dl:find(q, 1, true)
    local bsi = bl:find(q, 1, true)
    if bi or bsi then
      local rank = 0
      if bsi then rank = rank + 100000 - bsi end
      rank = rank + (1000 - #base)
      if not bsi then rank = rank - 50000 end
      rank = rank + (1000 - #disp)
      table.insert(scored, { disp = disp, abs = abs, rank = rank })
    end
  end
  table.sort(scored, function(a, b) return a.rank > b.rank end)
  state().suggestions = scored
  if state().selection < 1 then state().selection = 1 end
  if state().selection > #scored then state().selection = #scored end
  if state().selection < 1 then state().selection = 1 end
  M.render()
end

function M.refresh(query)
  refresh_file(query)
end

function M.render()
  local s = state()
  ctx.set_dropdown_height(math.min(#s.suggestions, vim.o.lines - 5))
  local lines = {}
  for _, e in ipairs(s.suggestions) do
    table.insert(lines, "  " .. e.disp)
  end
  local sel = (#lines > 0) and (s.selection - 1) or nil
  ctx.set_dropdown(lines, sel)
end

function M.open_selection()
  local s = state()
  if #s.suggestions == 0 then return end
  local e = s.suggestions[s.selection] or s.suggestions[1]
  if not e then return end
  ctx.close()
  vim.cmd("edit " .. vim.fn.fnameescape(e.abs))
end

function M.move_selection(dir)
  local s = state()
  if #s.suggestions == 0 then return end
  local n = #s.suggestions
  s.selection = s.selection + dir
  if s.selection < 1 then s.selection = n end
  if s.selection > n then s.selection = 1 end
  M.render()
end

return M