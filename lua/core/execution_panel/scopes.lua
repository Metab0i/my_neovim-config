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

-- foldable documentSymbol kinds (standard set)
local FOLDABLE = {
  [2] = true,  -- Module
  [3] = true,  -- Namespace
  [5] = true,  -- Class
  [6] = true,  -- Method
  [9] = true,  -- Constructor
  [10] = true, -- Enum
  [11] = true, -- Interface
  [12] = true, -- Function
  [23] = true, -- Struct
}
-- fall back to lsp.protocol if present (same numbers)
local ok, proto = pcall(function() return vim.lsp and vim.lsp.protocol and vim.lsp.protocol.SymbolKind end)
if ok and proto then
  for _, name in ipairs({ "Module", "Namespace", "Class", "Method", "Constructor",
    "Enum", "Interface", "Function", "Struct" }) do
    if proto[name] then FOLDABLE[proto[name]] = true end
  end
  -- merge additional fallback numbers already set above
end
for _, n in ipairs({ 2, 3, 5, 6, 9, 10, 11, 12, 23 }) do FOLDABLE[n] = true end

--------------------------------------------------------- indent scope heuristic

local function line_indent(line, tabstop)
  local ts = tabstop or 8
  if ts < 1 then ts = 8 end
  local lead = (line or ""):match("^[\t ]*") or ""
  local col = 0
  for ch in lead:gmatch("[\t ]") do
    if ch == " " then col = col + 1
    else col = col + (ts - (col % ts)) end
  end
  return col
end

local function is_blank(line) return line:match("^%s*$") ~= nil end

local function looks_like_opener(line)
  local s = line:lower()
  if s == "" then return false end
  if s:match("%{%s*$") then return true end            -- ends with {
  if s:match(":%s*$") then return true end             -- ends with : (python)
  if s:match("%sthen%s*$") then return true end
  if s:match("%sdo%s*$") then return true end
  if s:match("else%s*$") then return true end
  if s:match("begin%s*$") then return true end
  local kw = s:match("^%s*[}%%s]*else[%s{]") or false
  for _, k in ipairs({ "function", "def ", "class", "struct", "interface",
    "enum%s", "namespace", "if ", "for ", "while ", "switch", "try", "catch",
    "finally" }) do
    if s:find(k, 1, true) then return true end
  end
  if s:match("^%s*{+%s*$") then return true end        -- bare block opener
  if s:match("%b{}") and s:match("{%s*$") then return true end
  return false
end

-- true if the line is ONLY a brace (possibly indented), e.g. "{" or "  {".
-- Brace-specific; inert for brace-less languages (python/lua) where this never matches.
local function bare_brace_line(line)
  return line ~= nil and line:match("^%s*{%s*$") ~= nil
end

-- true if the opener line itself already starts its body on the same line
-- (K&R "if (c) {", python "if c:", lua "if c then", "do", "else", "begin").
-- When false, the body may start on the NEXT line (Allman brace or indent block).
local function body_starts_on_opener_line(line)
  local s = line:lower()
  if s:match("{%s*$") then return true end
  if s:match(":%s*$") then return true end             -- python
  if s:match("%sthen%s*$") then return true end        -- lua
  if s:match("%sdo%s*$") then return true end
  if s:match("else%s*$") then return true end
  if s:match("begin%s*$") then return true end
  return false
end

-- next non-blank line index after `from` (nil if none)
local function next_nonblank(bufnr, from, n)
  for j = from + 1, n do
    local l = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1]
    if l and not is_blank(l) then return j end
  end
  return nil
end

-- true if the line is a scope CLOSER that belongs to the scope and should be
-- folded into its body (a bare "}" or a lua-style "end[)];,]*"). For brace-less
-- dedent languages (python) the dedented line is the NEXT statement, not a
-- closer, so it is excluded from the fold (handled by the caller).
local function is_closer_line(line)
  if line == nil then return false end
  if line:match("^%s*}%s*$") then return true end
  if line:match("^%s*end[%s%)%;%,%]]*$") then return true end
  return false
end

-- returns list of {start=1based, end_=1based, opener=1based, indent=col-based}
-- where the foldable body is lines [start .. end_] and the opener (line `opener`)
-- stays visible. Allman/own-line braces are collapsed onto the preceding keyword
-- opener (so a brace-less language like python/lua is unaffected). Indent math is
-- tabstop-aware: a TAB advances to the next tabstop column (NOT 1), so a
-- tab-indented body line counts as deep, not shallow. ONLY multi-line bodies
-- (end_ > start) are actually folded; a single-line scope is still RETURNED in
-- the list so /fold's innermost picker can choose it and no-op (rather than fall
-- through to the enclosing function and "fold everything").
local function compute_indent_ranges(bufnr)
  local ranges = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return ranges end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local tabstop = tonumber(vim.bo[bufnr] and vim.bo[bufnr].tabstop) or 8
  if tabstop < 1 then tabstop = 8 end
  local consumed = {}  -- brace lines already absorbed by a preceding keyword opener
  for i = 1, n do
    if not consumed[i] then
      local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
      if line and not is_blank(line) and looks_like_opener(line) then
        local ind = line_indent(line, tabstop)
        local body_start = i + 1
        -- Allman collapse: opener doesn't start its body on this line AND the next
        -- non-blank line is a bare "{" at the same indent -> anchor on the keyword
        -- line `i`, skip the brace line, body begins after it.
        if not body_starts_on_opener_line(line) then
          local nb = next_nonblank(bufnr, i, n)
          if nb and bare_brace_line(vim.api.nvim_buf_get_lines(bufnr, nb - 1, nb, false)[1])
              and line_indent(vim.api.nvim_buf_get_lines(bufnr, nb - 1, nb, false)[1], tabstop) == ind then
            body_start = nb + 1
            consumed[nb] = true
          end
        end
        -- end: first later non-blank line with indent <= ind (closes the scope).
        -- Start scanning at body_start so a same-indent Allman brace (consumed)
        -- is not mistaken for the closer.
        local endline = nil
        for j = body_start, n do
          local l2 = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1]
          if l2 and not is_blank(l2) and line_indent(l2, tabstop) <= ind then
            endline = j
            break
          end
        end
        -- body_end:
        --   * no closer found (EOF)               -> include to end of file (n)
        --   * the endline IS a closer ("}"/"end") -> include it (folded into body,
        --     matching the opener-visible mock; a bare-"}"-terminated single
        --     statement then becomes a 2-line body, which IS foldable)
        --   * the endline is a dedented sibling (python) or a continuation clause
        --     like "} else {" -> exclude it (it's the next statement, not part of
        --     this scope; a single-line then-branch terminated by "} else {" thus
        --     collapses to a 1-line range and is intentionally NOT folded)
        local body_end
        if endline == nil then
          body_end = n
        else
          local endline_text = vim.api.nvim_buf_get_lines(bufnr, endline - 1, endline, false)[1]
          if is_closer_line(endline_text) then
            body_end = endline
          else
            body_end = endline - 1
          end
        end
        if body_end < body_start then body_end = body_start end  -- clamp to >= body_start
        -- keep the range even when single-line (end_ == start): it must stay in the
        -- list so /fold's innermost picker settles on it and no-ops instead of
        -- ascending to the enclosing scope (which would "fold everything").
        if body_start <= body_end then
          table.insert(ranges, { opener = i, start = body_start, end_ = body_end, indent = ind })
        end
      end
    end
  end
  return ranges
end

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
        if range and range.start and range["end"] and FOLDABLE[sym.kind or -1] then
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
  local indent_ranges = compute_indent_ranges(bufnr)
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
      local best = nil
      for _, r in ipairs(indent_ranges) do
        if cur >= r.opener and cur <= r.end_ then
          if not best or r.indent > best.indent
              or (r.indent == best.indent and r.opener > best.opener) then
            best = r
          end
        end
      end
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
    local best = nil
    for _, r in ipairs(indent_ranges) do
      if cur >= r.opener and cur <= r.end_ then
        if not best or r.indent > best.indent
            or (r.indent == best.indent and r.opener > best.opener) then
          best = r
        end
      end
    end
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