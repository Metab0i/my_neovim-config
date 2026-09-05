-- gitdiff.lua
-- `:GitDiff` - a live inline diff of the current file against HEAD.
--
-- A global on/off toggle. While ON, the current file is overlaid with
-- extmarks computed from a diff of the LIVE buffer contents against the
-- file's HEAD revision:
--   * added lines    -> green "+" in the sign column, over a subtle yellow
--     background tint on the added text
--   * removed lines  -> red "-" virtual lines over a subtle red background
--     tint, rendered at the position the line was removed, so the buffer
--     reads like an inline `git diff`
-- The view follows whatever file is current (BufEnter/WinEnter) and
-- recomputes on a short debounce after every text change, so edits are
-- integrated live. `:GitDiff` again clears everything and restores
-- 'signcolumn'.
--
-- Design notes:
--   * The diff runs in pure Lua (vim.diff, buffer content vs cached HEAD
--     content), NOT `git diff` against the working tree - `git diff` reads
--     the file from disk and would miss unsaved edits, which are the whole
--     point of a live view.
--   * HEAD content is fetched with `git rev-parse` / `git ls-files` /
--     `git show HEAD:<path>` (argv-list form, never shell-interpolated) and
--     cached per buffer; FocusGained drops the cache so external commits or
--     branch switches are picked up. Fetches happen only on enable or after
--     a focus change - never on the text-change hot path. BufWritePost is
--     deliberately NOT a trigger: writing does not move HEAD.
--   * Removals cannot be signs (the line no longer exists), so they must be
--     virt_lines; additions have no such problem (the line exists), so a
--     sign "+" is the least intrusive marker - it never shifts the text.
--     'signcolumn' is forced to "yes" while ON so signs appearing and
--     disappearing mid-typing never reflow the window.

local M = {}

local enabled = false
local ns = vim.api.nvim_create_namespace("gitdiff")
local head_cache = {}   -- [bufnr] = lines (may be {} for untracked)
local repo_failed = {}  -- [bufnr] = true: git lookups for this buffer already failed
local marked = {}       -- [bufnr] = true: this buffer has (or had) the overlay applied
local pending = {}      -- [bufnr] = true while a debounced recompute is queued
local timer = nil       -- single debounce timer (vim.defer_fn handle)
local saved_signcolumn = nil

local DEBOUNCE_MS = 40
-- Below the autocomplete ghost line (priority 100) on the same row.
local VLINE_PRIORITY = 40

-- Temporary diagnostic logging: appends timestamped lines to a per-user log
-- under /tmp (user-specific so the owner can always write it). Lets the
-- add-tint rendering be confirmed against ground truth from a real
-- environment. Remove once confirmed.
local LOG_PATH = ("/tmp/gitdiff-%s.log"):format(os.getenv("USER") or os.getenv("LOGNAME") or "unknown")
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  local f = io.open(LOG_PATH, "a")
  if f then
    f:write(os.date("%H:%M:%S ") .. table.concat(parts, " ") .. "\n")
    f:close()
  end
end

------------------------------------------------------------- highlight

-- Green "+" / red "-". Derived from the theme's DiffAdd/DiffDelete colors
-- when the theme defines them (falling back to a readable green/red), so
-- the markers sit in the theme's diff palette. Re-derived on ColorScheme;
-- `default = true` keeps any user `:highlight` definition in charge.
local function apply_hl_defaults()
  local function derive(name, fallback)
    local attrs = { default = true }
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and type(hl) == "table" then
      attrs.fg = hl.fg or hl.bg or fallback
    else
      attrs.fg = fallback
    end
    return attrs
  end
  pcall(vim.api.nvim_set_hl, 0, "GitDiffAdd", derive("DiffAdd", "#50FA7B"))
  pcall(vim.api.nvim_set_hl, 0, "GitDiffDelete", derive("DiffDelete", "#FF5555"))
  -- Subtle-but-visible background tints for the changed sections: yellow
  -- behind added lines, red behind removed virtual lines. Fixed colors tuned
  -- for a dark background; bright enough to be clearly perceptible on their
  -- own (additions have no foreground change, so the yellow tint must carry
  -- the visual cue - the earlier #4a4a1a was too dark to notice).
  pcall(vim.api.nvim_set_hl, 0, "GitDiffAddBg", { default = true, bg = "#6b5a00" })
  -- The red `-` text keeps the marker fg (derived from the resolved
  -- GitDiffDelete, so a user override survives) while gaining the tint bg.
  local del = { default = true, fg = "#FF5555", bg = "#6a1a1a" }
  local okd, dhl = pcall(vim.api.nvim_get_hl, 0, { name = "GitDiffDelete", link = false })
  if okd and type(dhl) == "table" and dhl.fg then del.fg = dhl.fg end
  pcall(vim.api.nvim_set_hl, 0, "GitDiffDeleteBg", del)

  local addbg = vim.api.nvim_get_hl(0, { name = "GitDiffAddBg", link = false })
  log("apply_hl_defaults GitDiffAddBg.bg =",
    (addbg.bg and string.format("#%06x", addbg.bg)) or tostring(addbg.bg))
end
apply_hl_defaults()

------------------------------------------------------------- git

-- Sync git helper. List-form argv only (no shell string interpolation), so
-- filenames with spaces or metacharacters can neither break the call nor
-- inject arguments. Returns stdout + exit code (code = -1 on spawn failure).
local function git(cwd, args, timeout_ms)
  local argv = { "git", "-C", cwd }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  if vim.system then
    local ok, res = pcall(function()
      return vim.system(argv, { text = true }):wait(timeout_ms or 2000)
    end)
    if ok and res then return res.stdout or "", res.code end
    return "", -1
  end
  -- Fallback for nvim < 0.10: list-form system() also bypasses the shell.
  local out = vim.fn.system(argv)
  return out, vim.v.shell_error
end

-- HEAD version of the buffer's file as a line list (no trailing empty
-- entry). Untracked files - and files staged but not yet committed - have
-- no HEAD version, so they yield {} (every buffer line is an addition).
-- Cached per buffer; failures cached too (hot path: TextChanged -> apply ->
-- this must never spawn git repeatedly).
function M._get_head_lines(bufnr)
  if head_cache[bufnr] then return head_cache[bufnr] end
  if repo_failed[bufnr] then return nil, "not a git repo" end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil, "no file" end
  local path = vim.fn.fnamemodify(name, ":p")
  local dir = vim.fn.fnamemodify(path, ":h")
  local base = vim.fn.fnamemodify(path, ":t")

  -- A brand-new file can sit in a brand-new directory: git needs an existing
  -- -C directory, so walk up to the nearest ancestor that exists (the file
  -- itself is untracked either way -> all additions).
  while dir ~= "/" and vim.fn.isdirectory(dir) ~= 1 do
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  local _, code = git(dir, { "rev-parse", "--is-inside-work-tree" })
  if code ~= 0 then
    repo_failed[bufnr] = true
    return nil, "not a git repo"
  end

  -- Repo-relative path of the file (empty output => not tracked). The
  -- :(literal) pathspec magic keeps glob characters in the filename from
  -- being pattern-matched.
  local out = git(dir, { "ls-files", "--full-name", "--", ":(literal)" .. base })
  local rel = vim.trim(out)
  if rel == "" then
    head_cache[bufnr] = {}
    return head_cache[bufnr]
  end

  local show, show_code = git(dir, { "show", "HEAD:" .. rel })
  if show_code ~= 0 then
    -- Tracked (in the index) but absent from HEAD: a new file, all additions.
    head_cache[bufnr] = {}
    return head_cache[bufnr]
  end

  local lines = {}
  if show ~= "" then
    lines = vim.split(show, "\n", { plain = true })
    -- git emits content with a trailing newline for newline-terminated files
    if lines[#lines] == "" then table.remove(lines) end
  end
  head_cache[bufnr] = lines
  return lines
end

------------------------------------------------------------- diff -> extmarks

-- xdiff treats the trailing newline as part of the line: comparing "a\nb"
-- against "a" reports BOTH lines changed ("-a -b +a") because the second
-- side's "a" lacks the newline the first side's "a" carries. Terminating
-- every line (and mapping "no lines" / "one empty line" to the same empty
-- string) makes last-line edits compare cleanly.
local function to_diff_text(lines)
  if #lines == 0 then return "" end
  if #lines == 1 and lines[1] == "" then return "" end
  return table.concat(lines, "\n") .. "\n"
end

-- Recompute the overlay for one buffer: clear our namespace, diff the live
-- buffer lines against the cached HEAD lines, and place `+` signs / `-`
-- virtual lines per hunk.
local function apply(bufnr)
  if not enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].buftype ~= "" then return end          -- scratch/terminal/preview
  if vim.api.nvim_buf_get_name(bufnr) == "" then return end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local head = M._get_head_lines(bufnr)
  if head == nil then return end                           -- non-git: no overlay
  marked[bufnr] = true

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line_count = math.max(1, #buf_lines)
  local a = to_diff_text(head)
  local b = to_diff_text(buf_lines)
  if a == b then return end

  -- ctxlen defaults to 0: the unified output carries only changed lines, no
  -- context blocks (the ' ' branch below is defensive only).
  local diff = vim.diff(a, b, { result_type = "unified" })
  if diff == nil or diff == "" then return end

  -- buf_ln is the 1-based buffer line the next +/- entry maps to (from the
  -- hunk's +start). + and context entries consume a buffer line; - entries
  -- do not (the line is gone from the buffer).
  local buf_ln = 0
  local pure_deletion = false
  local run = nil -- aggregated removal run: { row, above, chunks }

  local function flush()
    if not run then return end
    if #run.chunks > 0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, run.row, 0, {
        virt_lines = run.chunks,
        virt_lines_above = run.above,
        priority = VLINE_PRIORITY,
      })
      log("removal virt_lines row=" .. run.row, "chunks=" .. #run.chunks, "hl_group=GitDiffDeleteBg")
    end
    run = nil
  end

  for line in (diff .. "\n"):gmatch("([^\n]*)\n") do
    local tag = line:sub(1, 1)

    if tag == "@" then
      -- "@@ -a[,ac] +b[,bc] @@" (a count of 1 is written bare; cb is "" then).
      -- Three captures -- start_a is skipped: the b-side numbers are the ones
      -- that map onto buffer lines.
      flush()
      local _, sb, cb = line:match("@@ %-(%d+),?%d* %+(%d+),?(%d*)")
      buf_ln = tonumber(sb) or 0
      pure_deletion = (cb == "0")

    elseif tag == "+" then
      flush()
      local row = math.max(buf_ln - 1, 0)
      if row <= line_count - 1 then
        -- Sign marker and text background tint as two extmarks (sign column
        -- vs text bg). The tint uses an explicit end_col range (NOT hl_eol -
        -- that is a no-op on a zero-width single-line extmark, so it never
        -- painted) and tints the added text only; full-line width isn't
        -- possible in nvim 0.11.7 (end_col = -1 is rejected).
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          sign_text = "+",
          sign_hl_group = "GitDiffAdd",
        })
        local bline = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
        local end_col = #bline
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          hl_group = "GitDiffAddBg",
          end_col = end_col,
          priority = 200,
        })
        log("add tint row=" .. row, "end_col=" .. end_col, "hl_group=GitDiffAddBg", "priority=200")
      end
      buf_ln = buf_ln + 1

    elseif tag == " " then
      flush()
      buf_ln = buf_ln + 1

    elseif tag == "-" then
      -- Where does the removed line go?
      --   Mixed hunk (count_b > 0): directly above buffer line buf_ln (the
      --     line that followed the removal); if buf_ln is past the last
      --     buffer line the removal ran to EOF -> below the last line.
      --   Pure-deletion hunk (count_b == 0): the empty +side sits AFTER
      --     buffer line start_b (git convention) -> below it; start_b == 0
      --     means BOF -> above line 1.
      local row, above
      if pure_deletion then
        if buf_ln == 0 then
          row, above = 0, true
        else
          row, above = math.min(buf_ln, line_count) - 1, false
        end
      else
        row = buf_ln - 1
        if row <= line_count - 1 then
          above = true
        else
          row = line_count - 1
          above = false
        end
      end
      row = math.max(row, 0)
      if not run or run.row ~= row or run.above ~= above then
        flush()
        run = { row = row, above = above, chunks = {} }
      end
      run.chunks[#run.chunks + 1] = { { "-" .. line:sub(2), "GitDiffDeleteBg" } }
    end
    -- "\" ("\ No newline at end of file") and empty lines: nothing to place
  end
  flush()
end

local function clear_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
  end
end

------------------------------------------------------------- toggle

local function disable()
  enabled = false
  clear_all()
  head_cache = {}
  repo_failed = {}
  marked = {}
  pending = {}
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if saved_signcolumn ~= nil then
    vim.go.signcolumn = saved_signcolumn
    saved_signcolumn = nil
  end
end

function M.toggle()
  if enabled then
    disable()
    log("GitDiff disabled")
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  -- Retry drops this buffer's cached negative lookup so a repo created since
  -- the last attempt is recognized (otherwise :GitDiff sticks at "not a git
  -- repo" until the buffer is closed).
  repo_failed[bufnr] = nil
  local _, err = M._get_head_lines(bufnr)
  if err == "not a git repo" then
    require("core.notice").set("GitDiff: not a git repository")
    return
  end
  -- "no file" (e.g. [No Name]) still enables: the view follows the next
  -- real file that is entered.
  enabled = true
  saved_signcolumn = vim.go.signcolumn
  vim.go.signcolumn = "yes"
  apply(bufnr)
  log("GitDiff enabled bufnr=" .. bufnr)
end

------------------------------------------------------------- debounce

local function schedule(bufnr)
  pending[bufnr] = true
  if timer ~= nil then return end -- a flush is already queued
  timer = vim.defer_fn(function()
    timer = nil
    local bufs = vim.tbl_keys(pending)
    pending = {}
    for _, b in ipairs(bufs) do
      pcall(apply, b)
    end
  end, DEBOUNCE_MS)
end

------------------------------------------------------------- autocommands

local aug = vim.api.nvim_create_augroup("GitDiff", { clear = true })

vim.api.nvim_create_autocmd("ColorScheme", {
  group = aug,
  callback = apply_hl_defaults,
})

-- The toggle is global: the overlay follows whatever file becomes current.
-- No BufLeave teardown - apply() clears and replaces on entry, so marks on
-- hidden buffers cost nothing and returning to them doesn't flicker.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
  group = aug,
  callback = function()
    if enabled then apply(vim.api.nvim_get_current_buf()) end
  end,
})

vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  group = aug,
  callback = function(ev)
    if enabled then schedule(ev.buf) end
  end,
})

-- HEAD can move underneath us (commit / branch switch / stash elsewhere and
-- nvim sees no signal for it), so refocusing refreshes the base. Writing the
-- buffer is NOT such a refresh trigger - the diff is buffer-vs-HEAD either
-- way, and a write doesn't move HEAD.
vim.api.nvim_create_autocmd("FocusGained", {
  group = aug,
  callback = function()
    if not enabled then return end
    head_cache = {}
    repo_failed = {}
    local current = vim.api.nvim_get_current_buf()
    for bufnr in pairs(marked) do
      pcall(apply, bufnr)
    end
    pcall(apply, current)
  end,
})

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = aug,
  callback = function(ev)
    head_cache[ev.buf] = nil
    repo_failed[ev.buf] = nil
    marked[ev.buf] = nil
    pending[ev.buf] = nil
  end,
})

------------------------------------------------------------- command

vim.api.nvim_create_user_command("GitDiff", function()
  M.toggle()
end, { desc = "Toggle inline diff of the current file against HEAD" })

------------------------------------------------------------- test hooks

M._state = function() return enabled end
M._apply = apply
M._schedule = schedule
M._disable = disable

return M