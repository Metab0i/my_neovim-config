-- execution_panel/scopes.lua
-- Scope-based folding triggered from the panel: /fold /unfold /foldall /unfoldall,
-- executed on Enter (then the panel closes and focus returns to the file).
--
-- Engine: LSP textDocument/documentSymbol provides named scopes (functions,
-- classes, etc.) and an indentation heuristic provides block scopes (if/loop/
-- switch/blocks) that documentSymbol can't expose. Pure-indent fallback when no
-- LSP client is attached. documentSymbol is fetched asynchronously; manual folds
-- for indent scopes are applied synchronously at Enter and LSP scopes are merged
-- in when the response arrives (with a token guard so a stale response that lands
-- after /unfoldall or close is ignored).
--
-- Rendering: foldmethod=manual; each scope's body is folded, the opener line stays
-- visible, foldtext shows "...". Folds persist after the panel closes; /unfoldall
-- (zE) clears them and restores prior fold settings.

local M = {}
local ctx = nil
-- Scope ranges (indent heuristic + FOLDABLE kinds + innermost picker) live in
-- the shared scope_engine so the sticky-scope header (ui/context.lua) uses the
-- exact same machinery.
local scope = require("core.scope_engine")

function M.init(c) ctx = c end

local function state() return ctx.state end

local token = 0

-- Per-buffer fold-session state. These MUST be module-local (not stored in
-- state.scopes): the panel's close() and open_panel() reset state.scopes = {},
-- which would wipe a per-session setup flag and let ensure_setup re-apply
-- foldlevel=0 on the next /fold -- re-closing manual folds the user opened
-- with navkeys/zo. Keyed by bufnr so each buffer keeps independent fold state,
-- and cleared on BufDelete / /unfoldall to avoid leaks.
local setup_by_buf = {}    -- [bufnr] = true once fold_setup has run for this buffer
local saved_by_buf = {}    -- [bufnr] = snapshot from save_fold_opts for restore_fold_opts
local openers_by_buf = {}  -- [bufnr] = { [opener_lnum] = opener_lnum } LSP dedupe set

--------------------------------------------------------- fold set/restore helpers

local function save_fold_opts(win)
  return {
    foldmethod = vim.wo[win].foldmethod,
    foldlevel = vim.wo[win].foldlevel,
    foldtext = vim.o.foldtext,        -- global
    foldlevelstart = vim.o.foldlevelstart, -- global
  }
end
local function pcmd(c)
  pcall(vim.cmd, c)
end

local function fold_setup(win)
  pcall(vim.api.nvim_win_call, win, function()
    pcmd("setlocal foldmethod=manual")
    pcmd("setlocal foldlevel=0")
  end)
  pcmd("set foldtext=repeat('.',3)")
end

local function make_fold(win, start_lnum, end_lnum)
  if start_lnum > end_lnum then return end
  pcall(vim.api.nvim_win_call, win, function()
    pcmd(start_lnum .. "," .. end_lnum .. "fold")
  end)
end

local function restore_fold_opts(win, saved)
  if not saved then return end
  pcall(vim.api.nvim_win_call, win, function()
    pcmd("normal! zE")
    vim.wo[win].foldmethod = saved.foldmethod
    vim.wo[win].foldlevel = saved.foldlevel
  end)
  pcall(function() vim.o.foldtext = saved.foldtext end)
  pcall(function() vim.o.foldlevelstart = saved.foldlevelstart end)
end

--------------------------------------------------------- public commands

-- shared setup state handled here; set into state.scopes
local function ensure_setup(win, bufnr)
  if not bufnr then return end
  if not setup_by_buf[bufnr] then
    saved_by_buf[bufnr] = save_fold_opts(win)
    fold_setup(win)
    setup_by_buf[bufnr] = true
    openers_by_buf[bufnr] = {}  -- opener-line set for dedupe with LSP
  end
end

local function fire_lsp_merge(win, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if not clients or #clients == 0 then return end
  local my = token
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  pcall(vim.lsp.buf_request_all, bufnr, "textDocument/documentSymbol", params, function(results)
    if my ~= token then return end
    if not setup_by_buf[bufnr] then return end
    local st = state()
    if not st.prev_win or not vim.api.nvim_win_is_valid(st.prev_win) then return end
    local seen_opener_dir = {}
    for _, fop in pairs(openers_by_buf[bufnr] or {}) do seen_opener_dir[fop] = true end
    local function handle_symbols(syms)
      if not syms then return end
      for _, sym in ipairs(syms) do
        local range = sym.range or (sym.selectionRange and sym.selectionRange) or nil
        if range and range.start and range["end"] and scope.FOLDABLE[sym.kind or -1] then
          local s_line = range.start.line + 1
          local e_line = range["end"].line + 1
          if e_line - 1 >= s_line + 2 and not seen_opener_dir[s_line] then
            seen_opener_dir[s_line] = true
            make_fold(st.prev_win, s_line + 1, e_line - 1)
          end
        end
        if sym.children then handle_symbols(sym.children) end
      end
    end
    for cid, res in pairs(results or {}) do
      if res and res.result and not res.err then
        handle_symbols(res.result)
      end
    end
  end)
end

-- dispatch a fold command; called from the Enter handler with the parsed cmd
function M.dispatch(cmd, win, bufnr)
  token = token + 1  -- invalidate any in-flight async merge
  if cmd == "unfoldall" then
    local saved = saved_by_buf[bufnr]
    if saved then
      restore_fold_opts(win, saved)
    else
      pcall(vim.api.nvim_win_call, win, function() pcmd("normal! zE") end)
    end
    setup_by_buf[bufnr] = nil
    saved_by_buf[bufnr] = nil
    openers_by_buf[bufnr] = nil
    return
  end
  ensure_setup(win, bufnr)
  local st = state()
  local indent_ranges = scope.compute_indent_ranges(bufnr)
  if cmd == "foldall" then
    for _, r in ipairs(indent_ranges) do
      if r.end_ > r.start then  -- only multi-line bodies are foldable
        make_fold(win, r.start, r.end_)
        openers_by_buf[bufnr][r.opener] = r.opener
      end
    end
    fire_lsp_merge(win, bufnr)
    return
  end
  if cmd == "fold" then
    -- innermost indent scope enclosing the (saved) cursor. The deepest enclosing
    -- range is chosen; it is folded ONLY if its body spans >1 line. A single-line
    -- scope yields a no-op fold in nvim, so we intentionally do NOT ascend to the
    -- enclosing scope in that case -- ascending would "fold everything" (the
    -- user's earlier complaint). A true single-statement scope thus produces no
    -- fold at the cursor, by design.
    local cur = (st.origin and st.origin.pos) and st.origin.pos[1] or nil
    if cur then
      local best = scope.find_innermost(indent_ranges, cur)
      if best and best.end_ > best.start then
        make_fold(win, best.start, best.end_)
        openers_by_buf[bufnr][best.opener] = best.opener
      end
    end
    return
  end
  if cmd == "unfold" then
    -- open the innermost closed fold enclosing the cursor. Symmetric with /fold:
    -- pick the deepest enclosing indent scope, then zo at its body start (the
    -- folded line). This fixes the case where the cursor sits on the opener line,
    -- which stays visible by design -- a blind zo at the opener no-ops because no
    -- fold lives there. When the cursor is above every scope (outside all
    -- enclosing ranges) there is no enclosing scope, so we no-op (consistent with
    -- /fold, which also no-ops there).
    local cur = (st.origin and st.origin.pos) and st.origin.pos[1] or nil
    if not (cur and win and vim.api.nvim_win_is_valid(win)) then return end
    local best = scope.find_innermost(indent_ranges, cur)
    if best then
      pcall(vim.api.nvim_win_set_cursor, win, { best.start, 0 })
      pcall(vim.api.nvim_win_call, win, function()
        pcmd("normal! zo")
      end)
    end
    return
  end
end

-- panel hint while typing /fold… etc. (execution is on Enter)
function M.hint()
  ctx.set_dropdown_height(1)
  ctx.set_dropdown({ "  /fold  /unfold  /foldall  /unfoldall  + Enter" }, nil)
end

-- parse the current input line into a scopes command, or nil
function M.parse(line)
  local s = line and line:gsub("^%s+", "") or ""
  if s == "/foldall" or s:find("^/foldall%s") then return "foldall" end
  if s == "/unfoldall" or s:find("^/unfoldall%s") then return "unfoldall" end
  if s == "/fold" or s:find("^/fold%s") then return "fold" end
  if s == "/unfold" or s:find("^/unfold%s") then return "unfold" end
  return nil
end

function M.on_close()
  -- folds persist; nothing to do here
end

-- Clean per-buffer fold-session state when a buffer is deleted so the maps
-- above don't leak across the session. (One-shot group; safe to re-load.)
pcall(vim.api.nvim_create_augroup, "ExecPanelScopeCleanup", { clear = true })
vim.api.nvim_create_autocmd("BufDelete", {
  group = "ExecPanelScopeCleanup",
  callback = function(ev)
    local b = ev.buf
    setup_by_buf[b] = nil
    saved_by_buf[b] = nil
    openers_by_buf[b] = nil
  end,
})

return M