-- ui/context.lua
-- Sticky current-scope header: while the cursor is inside a scope (function,
-- class, method, block...) whose opening line has scrolled out of view, that
-- opener line is pinned to the top of the window as a single-line floating
-- "header". Always on; no keymap.
--
-- Scope resolution lives in core/scope_engine (LSP textDocument/documentSymbol
-- merged with the same indentation heuristic the execution panel's /fold
-- commands use). Rendering is a per-window floating window -- the same
-- mechanism nvim-treesitter-context uses -- because extmarks with virt_lines
-- are buffer-scoped and would ghost into every split showing the same file.
--
-- Tradeoff: the header overlays the topmost visible buffer line. Because the
-- config sets `scrolloff = 1` (core/navigation.lua), the cursor never rests on
-- that line while scrolling -- it stays on w0+1 or lower -- so the header always
-- covers the context line above the cursor and the cursor is never hidden.
-- Degenerate exception: windows too small for scrolloff to apply.

local scope = require("core.scope_engine")

local M = {}

local NS_DEBOUNCE_MS = 40
local ZINDEX = 10

-- per-window float state: [winid] = { float_winid, bufnr }
local window_contexts = {}
-- caches: [bufnr] = entries / ranges
local sym_by_buf = {}      -- LSP documentSymbol entries from scope_engine
local sym_pending = {}     -- [bufnr] = true while a fetch is in flight
local indent_by_buf = {}   -- indent-heuristic ranges

-- debounce: pending[winid] = true, single timer fires the batch
local pending = {}
local timer = nil
local schedule  -- forward-declared; ensure_symbols' async callback uses it

--------------------------------------------------------- highlight defaults

pcall(vim.api.nvim_set_hl, 0, "StickyScope", {
  link = "Comment", default = true,  -- conservative default; user can override
})
pcall(vim.api.nvim_set_hl, 0, "StickyScopeSeparator", {
  link = "Comment", default = true,
})

--------------------------------------------------------- helpers

local function valid_target(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  local bufnr = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  -- only normal file buffers; scratch/float/terminal windows are skipped
  if vim.bo[bufnr].buftype ~= "" then return false end
  -- skip floating windows (execution panel, peek, our own header floats)
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  if not ok or cfg.relative ~= "" then return false end
  return true
end

local function close_float(win)
  local wc = window_contexts[win]
  if not wc then return end
  if wc.float_winid and vim.api.nvim_win_is_valid(wc.float_winid) then
    vim.api.nvim_win_close(wc.float_winid, true)
  end
  if wc.bufnr and vim.api.nvim_buf_is_valid(wc.bufnr) then
    vim.api.nvim_buf_delete(wc.bufnr, { force = true })
  end
  window_contexts[win] = nil
end

local function close_all()
  for win in pairs(window_contexts) do close_float(win) end
end
M._close_all = close_all  -- test/teardown hook

-- trimmed opener line truncated to the window's text width
local function header_text(bufnr, opener, max_width)
  local lines = vim.api.nvim_buf_get_lines(bufnr, opener - 1, opener, false)
  local text = (lines[1] or ""):gsub("^%s+", "")
  if text == "" then return nil end
  if max_width and #text > max_width then
    -- display-cell aware truncation (handles multibyte openers)
    text = vim.fn.strcharpart(text, 0, math.max(0, max_width - 1)) .. "…"
  end
  return text
end

local function ensure_float(win, wc, width)
  if wc.float_winid and vim.api.nvim_win_is_valid(wc.float_winid) then
    -- reposition/resize in place (width tracks the host window)
    pcall(vim.api.nvim_win_set_config, wc.float_winid, {
      win = win, relative = "win", row = 0, col = wc.col, width = width, height = 1,
    })
    return
  end
  wc.float_winid = vim.api.nvim_open_win(wc.bufnr, false, {
    win = win,
    relative = "win",
    row = 0,
    col = wc.col,
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = ZINDEX,
    -- nvim border arrays are clockwise from the top-left corner:
    -- 1=TL 2=top 3=TR 4=right 5=BR 6=bottom 7=BL 8=left -> bottom separator
    border = { "", "", "", "", "─", "─", "─", "" },
  })
  pcall(function()
    vim.wo[wc.float_winid].wrap = false
    vim.wo[wc.float_winid].foldenable = false
    vim.wo[wc.float_winid].winhl =
      "NormalFloat:StickyScope,FloatBorder:StickyScopeSeparator"
  end)
end

local function set_header_text(bufnr, text)
  local changed = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] ~= text
  if not changed then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
  vim.bo[bufnr].modifiable = false
end

-- ensure the LSP symbol cache for bufnr is (being) populated. Tokens are
-- per-buffer (see scope_engine) and only bumped on invalidation, so
-- concurrent fetches for different buffers don't cancel each other.
local function ensure_symbols(bufnr)
  if sym_by_buf[bufnr] or sym_pending[bufnr] then return end
  sym_pending[bufnr] = true
  scope.fetch_document_symbols(bufnr, function(entries)
    sym_pending[bufnr] = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    sym_by_buf[bufnr] = entries or {}
    -- refresh every window showing this buffer, not just the active one
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
        schedule(w)
      end
    end
  end)
end

--------------------------------------------------------- recompute

local function recompute(win)
  if not valid_target(win) then close_float(win); return end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local cur = vim.fn.line(".", win)
  local topline = vim.fn.line("w0", win)

  -- combine LSP symbols (may still be empty until the fetch lands) with the
  -- indent heuristic, then take the innermost enclosing scope
  ensure_symbols(bufnr)
  local ranges = {}
  for _, r in ipairs(sym_by_buf[bufnr] or {}) do ranges[#ranges + 1] = r end
  if indent_by_buf[bufnr] == nil then
    indent_by_buf[bufnr] = scope.compute_indent_ranges(bufnr)
  end
  for _, r in ipairs(indent_by_buf[bufnr]) do ranges[#ranges + 1] = r end

  local best = scope.find_innermost(ranges, cur)

  if best == nil or best.opener >= topline then
    close_float(win)  -- outside any scope, or opener already in view
    return
  end

  local info = vim.fn.getwininfo(win)[1] or {}
  local col = info.textoff or 0
  local width = math.max(1, (info.width or vim.api.nvim_win_get_width(win)) - col)

  local text = header_text(bufnr, best.opener, width)
  if text == nil then close_float(win); return end

  local wc = window_contexts[win]
  if wc == nil then
    wc = { bufnr = vim.api.nvim_create_buf(false, true), col = col }
    window_contexts[win] = wc
    vim.bo[wc.bufnr].buftype = "nofile"
    vim.bo[wc.bufnr].modifiable = false
  end
  wc.col = col
  set_header_text(wc.bufnr, text)
  ensure_float(win, wc, width)
end

--------------------------------------------------------- debounce scheduler

-- (forward-declared; ensure_symbols' async callback calls back into this)
-- (assigns to the forward-declared local above so earlier closures see it)
function schedule(win)
  if win and vim.api.nvim_win_is_valid(win) then pending[win] = true end
  if timer ~= nil then return end  -- a flush is already queued
  timer = vim.defer_fn(function()
    timer = nil
    local wins = vim.tbl_keys(pending)
    pending = {}
    for _, w in ipairs(wins) do
      pcall(recompute, w)
    end
  end, NS_DEBOUNCE_MS)
end

M._schedule = schedule  -- test hook
M._recompute = recompute  -- test hook (raw, no pcall)

--------------------------------------------------------- cache invalidation

local function invalidate_buf(bufnr)
  -- early-out for buffers we never cached (e.g. our own scratch header
  -- buffers, which fire BufDelete on every header show/hide cycle)
  if sym_by_buf[bufnr] == nil and sym_pending[bufnr] == nil
      and indent_by_buf[bufnr] == nil then return end
  sym_by_buf[bufnr] = nil
  sym_pending[bufnr] = nil
  indent_by_buf[bufnr] = nil
  scope._sym_token[bufnr] = (scope._sym_token[bufnr] or 0) + 1  -- cancel in-flight documentSymbol
end

--------------------------------------------------------- autocommands

local aug = vim.api.nvim_create_augroup("StickyScope", { clear = true })

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = aug,
  callback = function() schedule(vim.api.nvim_get_current_win()) end,
})

-- WinScrolled payload is vim.v.event: a dict keyed by winid (plus "all"),
-- NOT event.win. "all" (mass scroll, e.g. from :normal! commands or resize)
-- carries no per-window info, so fall back to refreshing everything.
vim.api.nvim_create_autocmd("WinScrolled", {
  group = aug,
  callback = function()
    local ev = vim.v.event
    if ev.all ~= nil then
      close_all()
      for _, w in ipairs(vim.api.nvim_list_wins()) do schedule(w) end
      return
    end
    for w in pairs(ev) do
      if tonumber(w) then schedule(tonumber(w)) end
    end
  end,
})

vim.api.nvim_create_autocmd("WinResized", {
  group = aug,
  callback = function()
    for _, w in ipairs(vim.v.event and vim.v.event.windows or {}) do
      schedule(w)
    end
  end,
})

vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  group = aug,
  callback = function()
    -- drop floats for windows that no longer exist, then refresh this one
    for w in pairs(window_contexts) do
      if not vim.api.nvim_win_is_valid(w) then close_float(w) end
    end
    schedule(vim.api.nvim_get_current_win())
  end,
})

vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  group = aug,
  callback = function(ev)
    invalidate_buf(ev.buf)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == ev.buf then
        schedule(w)
      end
    end
  end,
})

vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
  group = aug,
  callback = function(ev)
    invalidate_buf(ev.buf)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == ev.buf then
        schedule(w)
      end
    end
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = aug,
  callback = function(ev)
    local w = tonumber(ev.match)
    if w == nil then return end
    -- the closing window may be one of our own header floats (whose host is
    -- still alive): never read vim.w on it (the window is already invalid at
    -- this point and that raises) -- identify our floats via their host entry
    for _, wc in pairs(window_contexts) do
      if wc.float_winid == w then return end
    end
    close_float(w)
  end,
})

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = aug,
  callback = function(ev) invalidate_buf(ev.buf) end,
})

return M
