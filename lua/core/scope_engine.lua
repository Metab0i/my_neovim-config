-- core/scope_engine.lua
-- Shared scope-range machinery, extracted verbatim from
-- execution_panel/scopes.lua so that both the /fold commands and the sticky
-- scope header (ui/context.lua) use one implementation.
--
-- Two scope sources are provided:
--   * an indentation heuristic (compute_indent_ranges) that finds block scopes
--     (if/loop/switch/functions/classes) with tabstop-aware indent math and
--     Allman/K&R/brace-less handling, and
--   * fetch_document_symbols, a token-guarded async LSP textDocument/
--     documentSymbol fetch that flattens all FOLDABLE symbols.
-- Both produce entries of the shape { opener = 1-based line, end_ = 1-based
-- line, indent = column } (LSP entries also carry kind); display text is
-- always read from the buffer by the caller, never stored here.
--
-- find_innermost picks the deepest range enclosing a cursor line (max indent,
-- then latest opener) and works uniformly across both sources because LSP
-- entries get their indent from the opener line.

local M = {}

-- per-buffer fetch tokens: [bufnr] = n. Bumped by callers (e.g. cache
-- invalidation) so a stale in-flight response for THAT buffer is ignored
-- without cancelling other buffers' fetches.
M._sym_token = {}

--------------------------------------------------------- foldable symbol kinds

-- foldable documentSymbol kinds (standard set)
M.FOLDABLE = {
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
    if proto[name] then M.FOLDABLE[proto[name]] = true end
  end
  -- merge additional fallback numbers already set above
end
for _, n in ipairs({ 2, 3, 5, 6, 9, 10, 11, 12, 23 }) do M.FOLDABLE[n] = true end

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
function M.compute_indent_ranges(bufnr)
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

--------------------------------------------------------- enclosing-scope lookup

-- deepest range enclosing `cursor_line`: max indent, then latest opener.
-- Works for indent ranges and LSP-derived ranges alike (LSP entries carry the
-- opener line's indent). Returns the range or nil.
function M.find_innermost(ranges, cursor_line)
  local best = nil
  for _, r in ipairs(ranges or {}) do
    if cursor_line >= r.opener and cursor_line <= r.end_ then
      if not best or r.indent > best.indent
          or (r.indent == best.indent and r.opener > best.opener) then
        best = r
      end
    end
  end
  return best
end

-- full chain of ranges enclosing `cursor_line`, outermost-first (ascending
-- indent, then ascending opener), deduped by opener line. A scope commonly
-- appears twice -- once from the LSP symbol list and once from the indent
-- heuristic -- and both entries share the opener line, so opener-dedup merges
-- them. NOTE the sort invariant is approximate when an LSP symbol's opener
-- indent differs from its true nesting depth (e.g. python decorators): a
-- mis-ranked entry just degrades to fewer header lines for callers that take a
-- contiguous prefix, never to wrong lines.
function M.enclosing_chain(ranges, cursor_line)
  local seen = {}
  local chain = {}
  for _, r in ipairs(ranges or {}) do
    if cursor_line >= r.opener and cursor_line <= r.end_
        and seen[r.opener] == nil then
      seen[r.opener] = true
      chain[#chain + 1] = r
    end
  end
  table.sort(chain, function(a, b)
    if a.indent ~= b.indent then return a.indent < b.indent end
    return a.opener < b.opener
  end)
  return chain
end

--------------------------------------------------------- LSP document symbols

-- token-guarded async documentSymbol fetch. Flattens ALL FOLDABLE symbols
-- (recursively, not just leaves) into entries
--   { opener = 1-based start line, end_ = 1-based end line, kind, indent }.
-- `callback(entries)` fires once per token with the flattened list (or nil on
-- error/no client). The indent of each entry is derived from its opener line
-- so find_innermost can rank LSP scopes against indent-heuristic scopes.
function M.fetch_document_symbols(bufnr, callback)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    if callback then callback(nil) end
    return
  end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if not clients or #clients == 0 then
    if callback then callback(nil) end
    return
  end
  local my = M._sym_token[bufnr] or 0
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  local ok = pcall(vim.lsp.buf_request_all, bufnr, "textDocument/documentSymbol", params, function(results)
    if my ~= (M._sym_token[bufnr] or 0) then return end  -- stale response
    local entries = nil
    for _, res in pairs(results or {}) do
      if res and res.result and not res.err then
        entries = entries or {}
        local function handle(syms)
          if not syms then return end
          for _, sym in ipairs(syms) do
            local range = sym.range or (sym.selectionRange and sym.selectionRange) or nil
            if range and range.start and range["end"] and M.FOLDABLE[sym.kind or -1] then
              local opener = range.start.line + 1
              local opener_text = vim.api.nvim_buf_get_lines(bufnr, opener - 1, opener, false)[1] or ""
              table.insert(entries, {
                opener = opener,
                end_ = range["end"].line + 1,
                kind = sym.kind,
                indent = line_indent(opener_text,
                  tonumber(vim.bo[bufnr] and vim.bo[bufnr].tabstop) or 8),
              })
            end
            if sym.children then handle(sym.children) end
          end
        end
        handle(res.result)
      end
    end
    if callback then callback(entries) end
  end)
  -- on a request failure the response callback never fires; signal the caller
  -- so it can clear its "pending" state instead of waiting forever
  if not ok and callback then callback(nil) end
end

return M
