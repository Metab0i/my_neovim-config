-- Autocomplete (dumb simple, virtual-line LSP completions)
--
-- Insert-only <C-Space> toggle:
--   * request completions at cursor, show one ghost-line suggestion below it.
--   * Tab / S-Tab cycle candidates (lazy 20-wide expanding window: cycling past
--     the current window loads another 20, up to everything the LSP returned).
--   * Enter -- accept: insert only the part of the label/insertText AFTER the
--     already-typed prefix (placeholders like ${1:..}/$1 stripped).
--   * <C-Space> again -- cancel.
-- Empty prefix is allowed only right after an access operator (./::/->);
-- otherwise a non-empty prefix is required.
-- Refiltered live against the prefix; closes when the prefix stops matching,
-- the cursor crosses a line, insert/buffer is left, or nothing matches.
-- Completion requests are fired once per trigger; isIncomplete is ignored.
-- Normal-mode <C-Space> (diagnostics float, lsp/init.lua) is untouched.

local M = {}

local state = {
  mode = "closed",          -- "closed" | "requesting" | "active"
  buf = nil,
  ns = nil,                 -- namespace (created lazily, reused)
  row = 0, col = 0,          -- 1-based row, 0-based col (cursor coords)
  prefix = "",              -- lowercased identifier run before cursor
  prefix_exact = "",        -- same, original case
  after_dot = false,        -- true when char(s) before cursor are ./::/->
  raw = {},                 -- deduped CompletionItems returned by the LSP
  cands = {},               -- current filtered subset
  sel = 1,                  -- 1-based index into cands
  window_end = 0,           -- max reachable index before the window expands
  mark = nil,               -- ghost-line extmark id
  augroup = nil,
}

local close_internal       -- forward declaration (refresh <-> close_internal)
local refresh

---------------------------------------------------------------- helpers

local function get_ns()
  if state.ns then return state.ns end
  state.ns = vim.api.nvim_create_namespace("Autocomplete")
  pcall(vim.api.nvim_set_hl, 0, "AutocompleteGhost", { default = true, link = "Comment" })
  return state.ns
end

-- Reads the identifier run ending at the cursor plus the anchor text before it
-- (used to detect the . / :: / -> property-access case where an empty prefix
-- should still be allowed).
local function get_prefix_info()
  local cur = vim.api.nvim_win_get_cursor(0)   -- { row 1-based, col 0-based }
  local row, col = cur[1], cur[2]
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  local before = line:sub(1, col)
  local prefix = before:match("([%w_]+)$") or ""
  local anchor = before:sub(1, #before - #prefix)
  local after_dot = false
  if anchor:match("%.$") or anchor:match("::$") or anchor:match("%->$") then
    after_dot = true
  end
  return {
    row = row, col = col, line = line,
    prefix = prefix, after_dot = after_dot, anchor = anchor,
  }
end

local function clear_mark()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) and state.ns then
    pcall(vim.api.nvim_buf_clear_namespace, state.buf, state.ns, 0, -1)
  end
  state.mark = nil
end

local function reset_state()
  state.mode = "closed"
  state.buf = nil
  state.row = 0; state.col = 0
  state.prefix = ""; state.prefix_exact = ""
  state.after_dot = false
  state.raw = {}; state.cands = {}
  state.sel = 1; state.window_end = 0
  state.mark = nil
end

local function del_active_keymaps()
  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  for _, k in ipairs({ "<Tab>", "<S-Tab>", "<CR>" }) do
    pcall(vim.keymap.del, "i", k, { buffer = buf })
  end
end

-- plain-text-ify an LSP snippet: ${n:default}->default, ${n}/$n->""
local function strip_snippet(s)
  if s == nil then return "" end
  local r = s
  r = r:gsub("%$%{(%d+):([^%}]*)%}", "%2")
  r = r:gsub("%$%{(%d+)%}", "")
  r = r:gsub("%$(%d+)", "")
  return r
end

-- The text to insert for a full accept (prefix already typed by the user is
-- excluded separately by compute_remaining).
local function item_text(it)
  local t = it.insertText
  if t == nil or t == "" then
    t = it.textEditText or it.label or ""
  end
  if it.insertTextFormat == 2 then
    t = strip_snippet(t)
  end
  return t or ""
end

-- The field used for client-side prefix matching and accept. clangd returns the
-- full signature as `label` (e.g. `int printf(const char *...)`) but the bare
-- name as `filterText` (e.g. `printf`); some items use a bullet prefix in the
-- label. Per LSP spec the client should match against `filterText` with
-- `label` as fallback, so partial prefixes like `pri` match `printf`.
local function match_field(it)
  return (it.filterText and it.filterText ~= "") and it.filterText or (it.label or "")
end

-- Return only the portion of the completion that comes AFTER the typed prefix.
-- Prefer the bare-name `filterText` for accept so completing `pri` -> `printf`
-- (not the snippet placeholders / signature); fall back to stripped
-- insertText, then label suffix.
local function compute_remaining(it, prefix_lower)
  local plen = #prefix_lower
  if plen == 0 then return match_field(it) end
  local ft = match_field(it)
  if ft:lower():sub(1, plen) == prefix_lower then
    return ft:sub(plen + 1)
  end
  local full = item_text(it)
  if full ~= "" and full:lower():sub(1, plen) == prefix_lower then
    return full:sub(plen + 1)
  end
  return ft:sub(plen + 1)
end

local function filter_cands()
  local out = {}
  local p = state.prefix
  for _, it in ipairs(state.raw) do
    -- require filterText or label so we have something to match/display
    if it.filterText or it.label then
      local f = match_field(it)
      if p == "" then
        table.insert(out, it)
      elseif f:lower():sub(1, #p) == p then
        table.insert(out, it)
      end
    end
  end
  return out
end

---------------------------------------------------------------- render

local function render()
  clear_mark()
  if state.mode ~= "active" then return end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local it = state.cands[state.sel]
  if not it then return end
  -- Display the rich label (clangd ships the full signature) so the ghost line
  -- is informative, but truncate to window width so it stays a single line
  -- (alongside the " sel/total" counter chunk).
  local counter = ""
  if #state.cands > 1 then
    counter = "  " .. state.sel .. "/" .. #state.cands
  end
  local max_label_width = vim.api.nvim_win_get_width(0) - 2 - #counter
  local label = it.label or match_field(it) or ""
  if #label > max_label_width and max_label_width > 4 then
    label = label:sub(1, max_label_width - 1) .. "…"
  end
  local chunks = { { label, "AutocompleteGhost" } }
  if counter ~= "" then
    table.insert(chunks, { counter, "Comment" })
  end
  get_ns()
  state.mark = vim.api.nvim_buf_set_extmark(state.buf, state.ns, state.row - 1, 0, {
    virt_lines = { chunks },
    virt_lines_above = false,
    priority = 100,
  })
end

local function cycle(dir)
  if state.mode ~= "active" then return end
  local n = #state.cands
  if n == 0 then return end
  local new = state.sel + dir
  if dir > 0 then
    if new > state.window_end and state.window_end < n then
      state.window_end = math.min(state.window_end + 20, n)
    end
    if new > n then new = 1 end
  else
    if new < 1 then new = n end
  end
  state.sel = new
  render()
end

---------------------------------------------------------------- accept

local function accept()
  if state.mode ~= "active" then return end
  local it = state.cands[state.sel]
  local remaining = it and compute_remaining(it, state.prefix) or ""
  local buf = state.buf
  local row0 = state.row - 1     -- 0-based for buf_set_text
  local col = state.col
  local row1 = state.row

  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_name, state.augroup); state.augroup = nil
  end
  del_active_keymaps()
  clear_mark()
  reset_state()

  if remaining ~= "" and buf and vim.api.nvim_buf_is_valid(buf) then
    local ok = pcall(vim.api.nvim_buf_set_text, buf, row0, col, row0, col, { remaining })
    if ok then
      pcall(vim.api.nvim_win_set_cursor, 0, { row1, col + #remaining })
    end
  end
end

-- Bind cycle/accept keymaps to the user code buffer, local to active state.
local function set_active_keymaps()
  local buf = state.buf
  if not buf then return end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("i", "<Tab>",   function() cycle(1) end, opts)
  vim.keymap.set("i", "<S-Tab>", function() cycle(-1) end, opts)
  vim.keymap.set("i", "<CR>",    accept, opts)
end

---------------------------------------------------------------- lifecycle

close_internal = function()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_name, state.augroup); state.augroup = nil
  end
  del_active_keymaps()
  clear_mark()
  reset_state()
end

refresh = function()
  if state.mode ~= "active" then return end
  local info = get_prefix_info()
  if info.row ~= state.row then close_internal(); return end
  state.col = info.col
  state.prefix = info.prefix:lower()
  state.prefix_exact = info.prefix
  state.after_dot = info.after_dot
  if state.prefix == "" and not state.after_dot then close_internal(); return end
  local f = filter_cands()
  if #f == 0 then close_internal(); return end
  state.cands = f
  if state.sel > #f then state.sel = 1 end
  if state.window_end > #f then state.window_end = math.min(20, #f) end
  render()
end

local function set_autocmds()
  state.augroup = vim.api.nvim_create_augroup("Autocomplete", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI" }, {
    group = state.augroup, buffer = state.buf, callback = refresh,
  })
  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = state.augroup, buffer = state.buf, callback = refresh,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = state.augroup, buffer = state.buf, callback = close_internal,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = state.augroup, buffer = state.buf, callback = close_internal,
  })
end

---------------------------------------------------------------- request

local function request_completions(buf, cb)
  local clients = vim.lsp.get_clients({ bufnr = buf })
  if #clients == 0 then cb(buf, nil, "no_lsp"); return end
  local pending = #clients
  local collected = {}
  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or client.position_encoding or "utf-16"
    local params = vim.lsp.util.make_position_params(0, enc)
    vim.lsp.buf_request(buf, "textDocument/completion", params, function(err, result)
      if not err and result then
        local items
        if type(result) == "table" and result.items then
          items = result.items
        elseif type(result) == "table" then
          items = result
        else
          items = {}
        end
        for _, it in ipairs(items) do table.insert(collected, it) end
      end
      pending = pending - 1
      if pending == 0 then cb(buf, collected, nil) end
    end)
  end
end

local function on_response(buf, items, err)
  if state.mode ~= "requesting" or state.buf ~= buf then return end
  if err == "no_lsp" then
    clear_mark(); reset_state()
    require("core.notice").set("No LSP server attached")
    return
  end

  local seen, raw = {}, {}
  for _, it in ipairs(items or {}) do
    if it.label and not seen[it.label] then
      seen[it.label] = true
      table.insert(raw, it)
    end
  end
  if #raw == 0 then
    clear_mark(); reset_state()
    require("core.notice").set("no completions")
    return
  end

  state.raw = raw
  -- Use the prefix captured at trigger time (open_completion). Do NOT re-read
  -- the cursor here: the async LSP round-trip means the cursor may no longer
  -- reflect the original typing position, yielding an empty prefix and a bogus
  -- "no completions for \"\"" report. Live prefix updates happen only via the
  -- TextChangedI/CursorMovedI refresh path once active.
  local cur_row = vim.api.nvim_win_get_cursor(0)[1]
  if cur_row ~= state.row then
    -- the user moved across lines during the round-trip; silently abort
    clear_mark(); reset_state(); return
  end

  local f = filter_cands()
  if #f == 0 then
    -- Capture the prefix BEFORE reset_state(), which zeroes state.prefix.
    -- (The original code read state.prefix_exact *after* reset and so always
    -- saw "" -- this is what produced the misleading `no completions for ""`
    -- notice the user hit, independent of the async stale-read.)
    local prefix = state.prefix
    clear_mark(); reset_state()
    if prefix == "" then
      require("core.notice").set("no completions")
    else
      require("core.notice").set("no completions for \"" .. prefix .. "\"")
    end
    return
  end
  state.cands = f
  state.sel = 1
  state.window_end = math.min(20, #f)
  state.mode = "active"
  set_active_keymaps()
  set_autocmds()
  render()
end

local function open_completion()
  if state.mode ~= "closed" then return end
  if vim.api.nvim_get_mode().mode ~= "i" then return end

  local buf = vim.api.nvim_get_current_buf()
  local info = get_prefix_info()
  if info.prefix == "" and not info.after_dot then
    require("core.notice").set("type a prefix first (or after . / :: / ->)")
    return
  end

  get_ns()
  state.buf = buf
  state.row = info.row
  state.col = info.col
  state.prefix = info.prefix:lower()
  state.prefix_exact = info.prefix
  state.after_dot = info.after_dot
  state.raw = {}
  state.cands = {}
  state.sel = 1
  state.window_end = 0
  state.mark = nil
  state.mode = "requesting"

  request_completions(buf, on_response)
end

---------------------------------------------------------------- public

M.toggle = function()
  if state.mode == "closed" then
    open_completion()
  elseif state.mode == "requesting" then
    clear_mark()
    reset_state()
    require("core.notice").set("autocomplete cancelled")
  else
    close_internal()
  end
end

M._is_active = function() return state.mode == "active" end
M._state = function() return state end

vim.keymap.set("i", "<C-space>", M.toggle, { desc = "Toggle autocomplete" })

return M