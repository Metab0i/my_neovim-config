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

local function line_indent(line)
  local m = line:match("^%s*") or ""
  return #m
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

-- A compound closer: the line's first non-blank char is "}" (so it closes a
-- brace scope) but the line continues a sibling scope or terminates a callable
-- (e.g. "} else {", "} catch (e) {", "} finally {", "})"). Unlike a pure "}"
-- closer it is NOT a standalone closer, so a single-line body terminated by one
-- would otherwise collapse to a 1-line range (not foldable in nvim) and
-- silently no-op. Surgical rescue caller-side is brace-only, so this is inert
-- for brace-less languages (python/lua) whose lines never start with "}".
local function is_compound_closer(line)
  if line == nil then return false end
  local first = line:match("^%s*(%S)")
  if first ~= "}" then return false end
  if line:match("^%s*}%s*$") then return false end
  return true
end

-- returns list of {start=1based, end_=1based, opener=1based, indent=0based}
-- where the foldable body is lines [start .. end_] and the opener (line `opener`)
-- stays visible. Allman/own-line braces are collapsed onto the preceding keyword
-- opener (so a brace-less language like python/lua is unaffected). Bodies of a
-- single line are foldable too.
local function compute_indent_ranges(bufnr)
  local ranges = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return ranges end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local consumed = {}  -- brace lines already absorbed by a preceding keyword opener
  for i = 1, n do
    if not consumed[i] then
      local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
      if line and not is_blank(line) and looks_like_opener(line) then
        local ind = line_indent(line)
        local body_start = i + 1
        -- Allman collapse: opener doesn't start its body on this line AND the next
        -- non-blank line is a bare "{" at the same indent -> anchor on the keyword
        -- line `i`, skip the brace line, body begins after it.
        if not body_starts_on_opener_line(line) then
          local nb = next_nonblank(bufnr, i, n)
          if nb and bare_brace_line(vim.api.nvim_buf_get_lines(bufnr, nb - 1, nb, false)[1])
              and line_indent(vim.api.nvim_buf_get_lines(bufnr, nb - 1, nb, false)[1]) == ind then
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
          if l2 and not is_blank(l2) and line_indent(l2) <= ind then
            endline = j
            break
          end
        end
        -- body_end:
        --   * no closer found (EOF)               -> include to end of file (n)
        --   * the endline IS a closer ("}"/"end") -> include it (folded into body,
        --     matches the opener-visible mock; also makes 1-line bodies foldable:
        --     body + closer = 2 lines)
        --   * the endline is a dedented sibling (python) -> exclude it (it's the
        --     next statement, not part of this scope)
        local body_end
        if endline == nil then
          body_end = n
        else
          local endline_text = vim.api.nvim_buf_get_lines(bufnr, endline - 1, endline, false)[1]
          if is_closer_line(endline_text) then
            body_end = endline
          else
            body_end = endline - 1
            -- Surgical rescue: a single-line body (body_end < body_start + 1)
            -- terminated by a COMPOUND closer "} else {" etc. would otherwise
            -- be a 1-line range (not foldable in nvim -> /fold no-ops and falls
            -- through to the enclosing function, "folding everything" from the
            -- user's perspective). Extend it to the closer so body+terminator
            -- is 2 lines (foldable). Only fires for a <=1-line body whose
            -- terminator leads with "}" and is not a pure closer; multi-line
            -- bodies and brace-less languages are left untouched.
            if body_end < body_start + 1 and is_compound_closer(endline_text) then
              body_end = endline
            end
          end
        end
        if body_end < body_start then body_end = body_start end  -- single-line body
        -- allow >= 1 body line (opener i visible; body [body_start .. body_end])
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
local function ensure_setup(win)
  local st = state()
  if not st.scopes then st.scopes = {} end
  if not st.scopes.setup then
    st.scopes.saved = save_fold_opts(win)
    fold_setup(win)
    st.scopes.setup = true
    st.scopes.openers = {}  -- opener-line set for dedupe with LSP
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
    local st = state()
    if not st.open and not st.scopes then return end
    if not st.scopes or not st.scopes.setup then return end
    if not st.prev_win or not vim.api.nvim_win_is_valid(st.prev_win) then return end
    local seen_opener_dir = {}
    for _, fop in pairs(st.scopes.openers or {}) do seen_opener_dir[fop] = true end
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
    if state().scopes and state().scopes.saved then
      restore_fold_opts(win, state().scopes.saved)
    else
      pcall(vim.api.nvim_win_call, win, function() pcmd("normal! zE") end)
    end
    if state().scopes then
      state().scopes.setup = false
      state().scopes.saved = nil
      state().scopes.openers = nil
    end
    return
  end
  ensure_setup(win)
  local st = state()
  local indent_ranges = compute_indent_ranges(bufnr)
  if cmd == "foldall" then
    for _, r in ipairs(indent_ranges) do
      make_fold(win, r.start, r.end_)
      st.scopes.openers[r.opener] = r.opener
    end
    fire_lsp_merge(win, bufnr)
    return
  end
  if cmd == "fold" then
    -- innermost indent scope enclosing the (saved) cursor
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
      if best then
        make_fold(win, best.start, best.end_)
        st.scopes.openers[best.opener] = best.opener
      end
    end
    return
  end
  if cmd == "unfold" then
    -- open the innermost closed fold enclosing the cursor
    local cur = (st.origin and st.origin.pos) and st.origin.pos[1] or nil
    if cur and win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { cur, 0 })
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

return M