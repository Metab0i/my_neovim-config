-- ui/context.lua
-- Sticky current-scope header: while the cursor is inside nested scopes
-- (function, class, method, block...) whose opening lines have scrolled out of
-- view, those opener lines are pinned to the top of the window as a multi-line
-- floating "header" -- the full ancestor chain, outermost at the top,
-- innermost at the bottom. Child lines are indented 2 spaces per shown level
-- to convey nesting. Always on; no keymap.
--
-- Scope resolution lives in core/scope_engine (LSP textDocument/documentSymbol
-- merged with the same indentation heuristic the execution panel's /fold
-- commands use). Rendering is a per-window floating window -- the same
-- mechanism nvim-treesitter-context uses -- because extmarks with virt_lines
-- are buffer-scoped and would ghost into every split showing the same file.
--
-- Tradeoff: the header overlays the topmost visible buffer lines. Two rules
-- keep the cursor visible:
--   * the config sets `scrolloff = 1` (core/navigation.lua), so scrolling
--     normally leaves at least one context line above the cursor;
--   * dynamic trim caps the header height to the cursor's screen row
--     (winline() - 1, wrap/fold aware), so even when scrolloff cannot apply
--     (tiny windows, :normal! scrolls) the header shrinks to fit above the
--     cursor instead of covering it. When trimmed, the innermost (most
--     specific) scopes are kept; at most MAX_LINES lines are shown.

local scope = require("core.scope_engine")

local M = {}

local NS_DEBOUNCE_MS = 40
local ZINDEX = 10
local MAX_LINES = 6  -- cap for pathologically deep chains

-- test/debug hook: number of float (re)configurations applied. A no-op cursor
-- move must not increment this (the flicker guard).
M._debug = { set_config = 0 }

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

-- The borderless header is separated from buffer text by its background, so
-- the default needs a subtle one. Derived from the active colorscheme:
-- Comment's fg over CursorLine's bg (the classic "subtle band" pairing).
-- Recomputed on ColorScheme so it tracks theme switches.
local function apply_sticky_hl_defaults()
  local okc, cmt = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
  local okl, cline = pcall(vim.api.nvim_get_hl, 0, { name = "CursorLine", link = false })
  local attrs = { default = true }
  if okc and type(cmt) == "table" and cmt.fg then attrs.fg = cmt.fg end
  if okl and type(cline) == "table" and cline.bg then attrs.bg = cline.bg end
  if not attrs.fg and not attrs.bg then attrs = { link = "Comment", default = true } end
  pcall(vim.api.nvim_set_hl, 0, "StickyScope", attrs)
  -- kept defined (no longer used by the float itself) so a user can underline
  -- the last header line via winhl if they want a visible rule
  pcall(vim.api.nvim_set_hl, 0, "StickyScopeSeparator", { link = "Comment", default = true })
end
apply_sticky_hl_defaults()

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

local function ensure_float(win, wc, width, height)
  if wc.float_winid and vim.api.nvim_win_is_valid(wc.float_winid) then
    -- reposition/resize in place (width tracks the host window) -- but skip
    -- the call entirely when nothing changed: reconfiguring with identical
    -- values still forces a float redraw, which shows as a flicker on every
    -- plain cursor move
    local l = wc.last
    if l and l.width == width and l.height == height and l.col == wc.col then
      return
    end
    local ok = pcall(vim.api.nvim_win_set_config, wc.float_winid, {
      win = win, relative = "win", row = 0, col = wc.col, width = width, height = height,
    })
    -- record only after a successful apply, so a failed call is retried next time
    if ok then
      wc.last = { width = width, height = height, col = wc.col }
      M._debug.set_config = M._debug.set_config + 1
    end
    return
  end
  wc.float_winid = vim.api.nvim_open_win(wc.bufnr, false, {
    win = win,
    relative = "win",
    row = 0,
    col = wc.col,
    width = width,
    height = height,
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = ZINDEX,
  })
  wc.last = { width = width, height = height, col = wc.col }
  M._debug.set_config = M._debug.set_config + 1
  pcall(function()
    vim.wo[wc.float_winid].wrap = false
    vim.wo[wc.float_winid].foldenable = false
    -- No bottom border: it would occupy an extra screen row and reintroduce a
    -- cursor-cover off-by-one. Separation comes from the StickyScope
    -- background instead. (StickyScopeSeparator stays defined so a user can
    -- underline the last line via winhl if they want a visible rule.)
    vim.wo[wc.float_winid].winhl = "NormalFloat:StickyScope"
  end)
end

local function set_header_lines(bufnr, lines)
  local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- compare the FULL table: a shrink (3 -> 1 lines) must not leave stale
  -- trailing lines behind
  local changed = #cur ~= #lines
  if not changed then
    for i, l in ipairs(lines) do
      if cur[i] ~= l then changed = true break end
    end
  end
  if not changed then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
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
  -- indent heuristic, then take the enclosing chain, outermost-first
  ensure_symbols(bufnr)
  local ranges = {}
  for _, r in ipairs(sym_by_buf[bufnr] or {}) do ranges[#ranges + 1] = r end
  if indent_by_buf[bufnr] == nil then
    indent_by_buf[bufnr] = scope.compute_indent_ranges(bufnr)
  end
  for _, r in ipairs(indent_by_buf[bufnr]) do ranges[#ranges + 1] = r end

  -- walk outermost->innermost and keep the contiguous prefix whose opener has
  -- scrolled out of view (openers increase with depth, so the prefix is
  -- contiguous; a mis-ranked entry just shortens it)
  local chain = scope.enclosing_chain(ranges, cur)
  local out = {}
  for _, r in ipairs(chain) do
    if r.opener < topline then out[#out + 1] = r else break end
  end

  local info = vim.fn.getwininfo(win)[1] or {}
  local col = info.textoff or 0
  local width = math.max(1, (info.width or vim.api.nvim_win_get_width(win)) - col)

  -- dynamic trim: the cursor's 0-based screen row is the number of rows above
  -- it. winline() takes no args, so call it in the target window's context; it
  -- returns the cursor's 1-based screen line accounting for 'wrap' and folds
  -- (unlike a plain cur - topline).
  local avail = vim.api.nvim_win_call(win, function() return vim.fn.winline() end) - 1
  local n = math.min(#out, math.max(0, avail), MAX_LINES)
  if n == 0 then close_float(win) return end

  -- keep the INNERMOST n scopes when trimmed (most specific / immediately
  -- relevant), still rendered outermost-first within the kept subset, each
  -- child indented 2 spaces per shown level (0, 2, 4, ...) to convey nesting
  local INDENT_PER_LEVEL = 2
  local first = #out - n + 1
  local lines = {}
  for i = first, #out do
    local level = i - first  -- 0-based depth among the shown lines
    local indent = string.rep(" ", INDENT_PER_LEVEL * level)
    local text = header_text(bufnr, out[i].opener, math.max(1, width - #indent)) or ""
    lines[#lines + 1] = indent .. text
  end

  local wc = window_contexts[win]
  if wc == nil then
    wc = { bufnr = vim.api.nvim_create_buf(false, true), col = col }
    window_contexts[win] = wc
    vim.bo[wc.bufnr].buftype = "nofile"
    vim.bo[wc.bufnr].modifiable = false
  end
  wc.col = col
  set_header_lines(wc.bufnr, lines)
  ensure_float(win, wc, width, n)
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

vim.api.nvim_create_autocmd("ColorScheme", {
  group = aug,
  callback = apply_sticky_hl_defaults,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = aug,
  callback = function() schedule(vim.api.nvim_get_current_win()) end,
})

-- WinScrolled payload is vim.v.event: a dict keyed by winid (plus "all"),
-- NOT event.win. "all" (mass scroll, e.g. from :normal! commands or resize)
-- carries no per-window info, so just refresh everything -- recompute closes
-- or updates each float in place, so an explicit close_all() here would only
-- add a teardown/rebuild flash.
vim.api.nvim_create_autocmd("WinScrolled", {
  group = aug,
  callback = function()
    local ev = vim.v.event
    if ev.all ~= nil then
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
