-- execution_panel (entry)
-- A single-line input spanning the top of the viewport. Acts as a quick-action
-- panel: fuzzy file search, in-buffer mass-replacement, cross-file string
-- search, and scope-based folding.
--
-- This entry owns the shared panel state and all window/dropdown infrastructure;
-- behaviour lives in sibling submodules wired below:
--   discovery.lua    - file- and content-search rules/logic (no UI)
--   findfile.lua     - /f fuzzy file search (UI + integration)
--   replace.lua      - /replace in-buffer live replacement (logic + UI)
--   findstring.lua   - /fstr cross-file string search (UI + integration)
--   scopes.lua       - /fold /unfold /foldall /unfoldall scope folding
-- Each submodule receives a `ctx` (shared state + infra callbacks) via init().

local discovery = require("core.execution_panel.discovery")
local findfile   = require("core.execution_panel.findfile")
local replace    = require("core.execution_panel.replace")
local findstring = require("core.execution_panel.findstring")
local scopes     = require("core.execution_panel.scopes")

local M = {}

local state = {
  open = false,
  mode = "file",        -- "file" | "replace" | "fstr" | "scopes"
  help = false,         -- /replace help sub-mode
  info = false,         -- /? info sub-mode
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
  panel_at_bottom = false,
  d_height = 1,
  ns = nil,             -- buffer highlighting namespace
  -- findstring state
  fstr = { active = false, pattern = "", results = {}, selection = 1,
          match_list = {}, match_idx = 1, preview_abs = nil, _timer = nil, _match_id = nil },
  -- scopes state
  scopes = {},
  -- origin captured at panel open (for /fstr Esc restore)
  origin = nil,
}

-- Threshold (in lines from the top of the buffer) below which the panel docks at
-- the BOTTOM of the viewport so the file top stays visible.
local SHIFT_NEAR_TOP = 4

------------------------------------------------------------------ helpers

M._is_open = function() return state.open end
M._state = function() return state end

------------------------------------------------------------------ highlights

local function define_hl()
  if state.ns == nil then state.ns = vim.api.nvim_create_namespace("ExecPanel") end
  local base = vim.api.nvim_get_hl(0, { name = "Search" })
  local merged = vim.tbl_deep_extend("force", base, { strikethrough = true })
  pcall(vim.api.nvim_set_hl, 0, "ExecPanelMatch", merged)
end

------------------------------------------------------------------ dropdown

local function set_dropdown(lines, selected_row)
  if not state.d_buf or not vim.api.nvim_buf_is_valid(state.d_buf) then return end
  if #lines == 0 then lines = { "" } end
  vim.api.nvim_buf_set_option(state.d_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.d_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.d_buf, "modifiable", false)
  if state.dns then vim.api.nvim_buf_clear_namespace(state.d_buf, state.dns, 0, -1) end
  if selected_row then
    local idx = selected_row
    local l = lines[idx + 1] or ""
    local len = math.max(#l, 1)
    pcall(vim.api.nvim_buf_set_extmark, state.d_buf, state.dns, idx, 0, {
      end_col = len,
      hl_group = "PmenuSel",
      priority = 200,
    })
  end
end

-- (re)anchor the input + dropdown windows for the current orientation and
-- dropdown height. In bottom mode the dropdown sits flush ABOVE the input, so
-- re-calling on every height change keeps it from overlapping the input on
-- grow (e.g. /? -> 5 lines clips the last help line) or leaving a gap on
-- shrink. Extracted from reposition_panel so set_dropdown_height can re-anchor
-- without waiting for a panel_at_bottom flip; reposition_panel still owns the
-- flip and then calls this.
local function place_dropdown()
  if not state.open then return end
  if not state.in_win or not vim.api.nvim_win_is_valid(state.in_win) then return end
  if not state.d_win or not vim.api.nvim_win_is_valid(state.d_win) then return end
  local cols = vim.o.columns
  local pad = 5
  local width = math.max(3, cols - pad * 2)
  local in_row, d_row
  if state.panel_at_bottom then
    in_row = vim.o.lines - 3
    d_row = in_row - (state.d_height + 2) - 1
    if d_row < 0 then d_row = 0 end
  else
    in_row = 0
    d_row = 3
  end
  pcall(vim.api.nvim_win_set_config, state.in_win, {
    relative = "editor", row = in_row, col = pad,
    width = width, height = 1, style = "minimal", border = "rounded",
    focusable = true,
  })
  pcall(vim.api.nvim_win_set_config, state.d_win, {
    relative = "editor", row = d_row, col = pad,
    width = width, height = state.d_height, style = "minimal", border = "rounded",
    focusable = false,
  })
end

-- test-only hook (mirrors M._is_open/_state): lets a test force a re-anchor
-- after flipping state.panel_at_bottom, to exercise the shrink-snap-back gap
-- scenario after a top->bottom flip. Noop-guarded internally.
M._place_dropdown_for_test = place_dropdown

local function set_dropdown_height(h)
  if not state.d_win or not vim.api.nvim_win_is_valid(state.d_win) then return end
  h = math.max(1, math.min(h, math.max(1, vim.o.lines - 5)))
  state.d_height = h
  vim.api.nvim_win_set_height(state.d_win, h)
  place_dropdown()  -- re-anchor (bottom mode: flush above input on grow/shrink)
end

local function reposition_panel()
  if not state.open then return end
  if not state.prev_win or not vim.api.nvim_win_is_valid(state.prev_win) then return end
  local wi = vim.fn.getwininfo(state.prev_win)
  local topline = (wi and wi[1] and wi[1].topline) or 1
  local at_bottom = (topline <= SHIFT_NEAR_TOP)
  if at_bottom == state.panel_at_bottom then return end
  state.panel_at_bottom = at_bottom
  place_dropdown()
end

------------------------------------------------------------------ renderers

local function render_hint()
  set_dropdown({ "  /? for more info" }, nil)
  set_dropdown_height(1)
end

local function render_info()
  local lines = {
    "  Type to fuzzy-search files",
    "  /fstr <substr>      find substring across files  (Tab cycle match)",
    "  /replace -m <vimregex> -r <replacement>   replace text in open file",
    "  /replace -help        replace usage",
    "  /fold /unfold /foldall /unfoldall + Enter  (cursor scope / innermost fold / all / clear+restore)",
  }
  set_dropdown_height(#lines)
  set_dropdown(lines, nil)
end

local function render_status(line)
  set_dropdown_height(1)
  set_dropdown({ line }, nil)
end

local function render_hint_fstr()
  set_dropdown({ "  /fstr <literal-substring>" }, nil)
  set_dropdown_height(1)
end

local function clear_extmarks()
  if state.ns and state.target_buf and vim.api.nvim_buf_is_valid(state.target_buf) then
    vim.api.nvim_buf_clear_namespace(state.target_buf, state.ns, 0, -1)
  end
end

------------------------------------------------------------------ close

local function close()
  if not state.open then return end  -- re-entrancy guard; WinLeave may re-fire during close's window teardown
  state.open = false
  -- restore /fstr preview first (while prev_win still holds it) so focus
  -- returns to the original file at the original cursor. No-op if not active.
  findstring.on_close()
  scopes.on_close()

  clear_extmarks()
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
  state.panel_at_bottom = false
  state.origin = nil
  -- clear findstring debounce timer
  if state.fstr._timer then
    pcall(function() state.fstr._timer:stop() end)
    pcall(function() state.fstr._timer:close() end)
    state.fstr._timer = nil
  end
  state.fstr = { active = false, pattern = "", results = {}, selection = 1,
                 match_list = {}, match_idx = 1, preview_abs = nil, _timer = nil, _match_id = nil }
  state.scopes = {}
  if state.prev_win and vim.api.nvim_win_is_valid(state.prev_win) then
    pcall(vim.api.nvim_set_current_win, state.prev_win)
  end
  state.prev_win = nil
  state.target_buf = nil
  pcall(vim.cmd, "stopinsert")
end

------------------------------------------------------------------ ctx + submodule wiring

local ctx = nil
local function build_ctx()
  return {
    state = state,
    set_dropdown = set_dropdown,
    set_dropdown_height = set_dropdown_height,
    reposition_panel = reposition_panel,
    render_hint = render_hint,
    render_info = render_info,
    render_status = render_status,
    render_hint_fstr = render_hint_fstr,
    clear_extmarks = clear_extmarks,
    close = close,
    define_hl = define_hl,
  }
end
ctx = build_ctx()
findfile.init(ctx)
replace.init(ctx)
findstring.init(ctx)
scopes.init(ctx)

------------------------------------------------------------------ refresh router

local function refresh()
  if not state.open then return end
  if state._in_refresh then return end
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
    replace.refresh(line)
  elseif line:match("^%s*/fstr%s") then
    state.mode = "fstr"
    state.info = false
    clear_extmarks()
    state.matches = {}
    findstring.refresh(line)
  elseif line:match("^%s*/fold") or line:match("^%s*/unfold") then
    state.mode = "scopes"
    state.info = false
    state.help = false
    clear_extmarks()
    state.matches = {}
    scopes.hint()
  else
    state.mode = "file"
    state.help = false
    state.info = false
    clear_extmarks()
    state.matches = {}
    findfile.refresh(line)
  end
  state._in_refresh = false
end

------------------------------------------------------------------ keymaps

local function set_keymaps()
  local opts = { buffer = state.in_buf, nowait = true, silent = true }

  vim.keymap.set({ "i", "n" }, "<Esc>", close, opts)

  vim.keymap.set("i", "<CR>", function()
    if state.mode == "replace" then
      if not state.help then replace.replace_one() end
    elseif state.mode == "fstr" then
      findstring.open()
    elseif state.mode == "scopes" then
      local l = vim.api.nvim_buf_get_lines(state.in_buf, 0, 1, false)[1] or ""
      local cmd = scopes.parse(l)
      if cmd then scopes.dispatch(cmd, state.prev_win, state.target_buf) end
      close()
    elseif not state.info then
      findfile.open_selection()
    end
  end, opts)

  vim.keymap.set("i", "<M-CR>", function()
    if state.mode == "replace" and not state.help then replace.replace_all() end
  end, opts)

  vim.keymap.set("i", "<Tab>", function()
    if state.mode == "fstr" then
      findstring.cycle_match(1)
    elseif state.mode == "file" and not state.info then
      findfile.move_selection(1)
    else
      vim.api.nvim_feedkeys("\t", "n", false)
    end
  end, opts)
  vim.keymap.set("i", "<S-Tab>", function()
    if state.mode == "fstr" then
      findstring.cycle_match(-1)
    elseif state.mode == "file" and not state.info then
      findfile.move_selection(-1)
    else
      vim.api.nvim_feedkeys("\t", "n", false)
    end
  end, opts)

  vim.keymap.set("i", "<Down>", function()
    if state.mode == "fstr" then
      findstring.move_file(1)
    elseif state.mode == "file" and not state.info then
      findfile.move_selection(1)
    else
      vim.api.nvim_feedkeys("\25", "n", false) -- <Down>
    end
  end, opts)
  vim.keymap.set("i", "<Up>", function()
    if state.mode == "fstr" then
      findstring.move_file(-1)
    elseif state.mode == "file" and not state.info then
      findfile.move_selection(-1)
    else
      vim.api.nvim_feedkeys("\30", "n", false) -- <Up>
    end
  end, opts)

  vim.keymap.set("i", "<S-Down>", function()
    if state.mode == "replace" and not state.help then replace.cycle_match(1)
    elseif state.mode == "fstr" then findstring.move_file(1)
    elseif not state.info then findfile.move_selection(1) end
  end, opts)
  vim.keymap.set("i", "<S-Up>", function()
    if state.mode == "replace" and not state.help then replace.cycle_match(-1)
    elseif state.mode == "fstr" then findstring.move_file(-1)
    elseif not state.info then findfile.move_selection(-1) end
  end, opts)

  -- J / K : cycle matches in replace mode; type the letter otherwise.
  -- Non-expr so cycle_match can modify buffers/windows (expr maps run under
  -- textlock, which forbids buffer/window changes -> E565).
  vim.keymap.set("i", "J", function()
    if state.mode == "replace" and not state.help then
      replace.cycle_match(1)
    else
      vim.api.nvim_feedkeys("J", "n", false)
    end
  end, { buffer = state.in_buf, silent = true, nowait = true })
  vim.keymap.set("i", "K", function()
    if state.mode == "replace" and not state.help then
      replace.cycle_match(-1)
    else
      vim.api.nvim_feedkeys("K", "n", false)
    end
  end, { buffer = state.in_buf, silent = true, nowait = true })
end

------------------------------------------------------------------ open

local function open_panel()
  if state.open then return end
  state.prev_win = vim.api.nvim_get_current_win()
  state.target_buf = vim.api.nvim_get_current_buf()
  state.open = true
  state.mode = "file"
  state.help = false
  state.info = false
  state.panel_at_bottom = false
  state.query = ""
  state.selection = 1
  state.matches = {}
  state.current_idx = 1
  state.match_str = ""
  state.replacement_str = ""
  state.re_obj = nil
  state.re_valid = true
  state.fstr = { active = false, pattern = "", results = {}, selection = 1,
                 match_list = {}, match_idx = 1, preview_abs = nil, _timer = nil, _match_id = nil }
  state.scopes = {}
  state.origin = {
    win = state.prev_win,
    buf = state.target_buf,
    abs = vim.api.nvim_buf_get_name(state.target_buf),
    pos = vim.api.nvim_win_get_cursor(state.prev_win),
    search = vim.fn.getreg("/"),
    hlsearch = vim.o.hlsearch,
  }

  state.file_list, state.root, state.cwd = discovery.build_file_list(state.target_buf)

  local cols = vim.o.columns
  local pad = 5

  state.in_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.in_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.in_buf, "bufhidden", "wipe")

  state.in_win = vim.api.nvim_open_win(state.in_buf, true, {
    relative = "editor", row = 0, col = pad,
    width = math.max(3, cols - pad * 2), height = 1,
    style = "minimal", border = "rounded", focusable = true, noautocmd = true,
  })

  state.d_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.d_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.d_buf, "bufhidden", "wipe")

  state.d_win = vim.api.nvim_open_win(state.d_buf, false, {
    relative = "editor", row = 3, col = pad,
    width = math.max(3, cols - pad * 2), height = math.max(1, vim.o.lines - 5),
    style = "minimal", border = "rounded", focusable = false, noautocmd = true,
  })
  pcall(function() vim.wo[state.d_win].winhighlight = "Normal:Pmenu,NormalNC:Pmenu" end)

  state.dns = vim.api.nvim_create_namespace("ExecPanelDropdown")
  if state.ns == nil then state.ns = vim.api.nvim_create_namespace("ExecPanel") end
  define_hl()

  set_keymaps()

  state.augroup = "ExecPanelAuto"
  vim.api.nvim_create_augroup(state.augroup, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = state.augroup, buffer = state.in_buf, callback = refresh,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = state.augroup,
    callback = function(ev)
      if state.open and state.prev_win and tonumber(ev.match) == state.prev_win then
        reposition_panel()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = state.augroup,
    callback = function() if state.open then reposition_panel() end end,
  })
  -- Closing the panel when focus leaves its input window for any reason (mouse
  -- click into the file, <C-w> split, :wincmd, ...), matching the <Esc> mental
  -- model. d_win is focusable=false so it can't steal focus; nvim_win_call
  -- (used by /fstr preview and /replace scroll) does NOT fire WinLeave, so
  -- previews are safe. Close()'s own window teardown may re-fire WinLeave but
  -- state.open is already false then (guard at top of close).
  vim.api.nvim_create_autocmd("WinLeave", {
    group = state.augroup,
    callback = function()
      if not state.open then return end
      if state.in_win and vim.api.nvim_win_is_valid(state.in_win)
          and vim.api.nvim_get_current_win() == state.in_win then
        -- defer out of the WinLeave window-switch transition so close()'s own
        -- window teardown doesn't recurse into the switch mid-flight.
        vim.schedule(close)
      end
    end,
  })

  render_hint()
  reposition_panel()
  vim.api.nvim_set_current_win(state.in_win)
  vim.cmd("startinsert")
end

M.toggle = function()
  if state.open then close() else open_panel() end
end
M.open = open_panel
M.close = close

vim.keymap.set("n", "<leader><leader>", M.toggle, { desc = "Execution panel" })

return M