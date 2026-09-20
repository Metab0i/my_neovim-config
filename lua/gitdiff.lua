-- gitdiff.lua
-- `:GitDiff` - a live inline diff of the current file against HEAD.
--
-- A global on/off toggle. While ON, the current file is overlaid with
-- extmarks computed from a diff of the LIVE buffer contents against the
-- file's HEAD revision:
--   * added lines    -> a bright-green "+" rendered inline at the start of the
--     line, over a subtle yellow background tint across the full line width
--   * removed lines  -> a bright-red "-" rendered inline at the start of the
--     removed text, shown as red virtual lines over a subtle red background
--     tint at the position the line was removed, so the buffer reads like an
--     inline `git diff`
-- The view follows whatever file is current (BufEnter/WinEnter) and
-- recomputes on a short debounce after every text change, so edits are
-- integrated live. `:GitDiff` again clears everything.
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
--   * The +/- markers are rendered inline (virtual text) instead of in the
--     sign column, so each marker sits on the exact line it describes: the "+"
--     at the start of an added line, the "-" as the first chunk of the removed
--     line's virtual text. This avoids the anchor ambiguity of gutter signs (a
--     removed line has no buffer row to attach to) and sign-column collisions
--     on replacements. Highlight colour is the primary cue, with the marker
--     glyph bold and brightened over the subtle line tint. No 'signcolumn'
--     forcing is needed.

local M = {}

local enabled = false
local ns = vim.api.nvim_create_namespace("gitdiff")
local head_cache = {}   -- [bufnr] = lines (may be {} for untracked)
local repo_failed = {}  -- [bufnr] = true: git lookups for this buffer already failed
local marked = {}       -- [bufnr] = true: this buffer has (or had) the overlay applied
local pending = {}      -- [bufnr] = true while a debounced recompute is queued
local timer = nil       -- single debounce timer (vim.defer_fn handle)

local DEBOUNCE_MS = 40
-- Below the autocomplete ghost line (priority 100) on the same row.
local VLINE_PRIORITY = 40
-- Priority for the inline "+" marker's extmark (full-line tint + glyph): above
-- the ghost line's 100 and above VLINE_PRIORITY, so the tint wins.
local MARK_PRIORITY = 200
-- Padding width for removed-line virtual text: each virt_line is padded with
-- spaces to this display width so the tint spans the full line width. 300
-- comfortably exceeds any real window width; virt_lines default to `trunc`
-- overflow, so the padding is simply clipped at the window edge.
local VIRT_LINE_WIDTH = 300

------------------------------------------------------------- highlight

-- The section tint backgrounds: yellow behind added lines, red behind removed
-- lines. Shared with the accent segments so nothing can drift apart.
local ADD_BG = "#6b5a00"
local DEL_BG = "#6a1a1a"

-- How far to blend the +/- glyph toward white (so it reads brighter than the
-- tint around it), and how much brighter the glyph's own background segment is
-- than the rest of the tinted line.
local ACCENT_BRIGHTEN = 0.45
local ACCENT_BG_BRIGHTEN = 0.25

-- [group] = the fg we last wrote, so a value already in place can be told apart
-- from a genuine user override (avoids re-brightening without a `hi clear`).
local hl_fg_set = {}

-- Blend a colour toward white by `amount` (0..1). Accepts "#rrggbb" or a 24-bit
-- integer; returns a 24-bit integer (or the input unchanged if unparseable).
local function brighten(color, amount)
  local n = color
  if type(color) == "string" then n = tonumber((color:gsub("^#", "")), 16) end
  if type(n) ~= "number" then return color end
  local r = math.floor(n / 0x10000) % 0x100
  local g = math.floor(n / 0x100) % 0x100
  local b = n % 0x100
  local function up(c) return math.floor(c + (255 - c) * amount + 0.5) end
  return up(r) * 0x10000 + up(g) * 0x100 + up(b)
end

-- GitDiffAdd / GitDiffDelete are the bold inline "+" / "-" marker accents. Each
-- is a brightened copy of the theme's DiffAdd/DiffDelete colour (falling back
-- to a readable green/red), so the marker stays in the theme's diff palette but
-- stands out brighter than the tint behind it. Re-derived on ColorScheme;
-- `default = true` keeps any user `:highlight` definition in charge.
local function apply_hl_defaults()
  local function theme_fg(name, fallback)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and type(hl) == "table" then return hl.fg or hl.bg or fallback end
    return fallback
  end
  -- A user's own definition of the public GitDiff* groups wins over the theme.
  -- A value we wrote ourselves is ignored, so re-running without `hi clear`
  -- (a bare `:doautocmd ColorScheme`, rather than `:colorscheme`) cannot
  -- brighten the accent repeatedly.
  local function user_fg(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and type(hl) == "table" then
      local fg = hl.fg or hl.bg
      if fg ~= nil and fg ~= hl_fg_set[name] then return fg end
    end
  end

  -- Each accent gets its own slightly-brighter background segment behind the
  -- glyph: the "+" overrides its line tint for that one cell, and the "-" is
  -- the first chunk of a virtual line (which has no `line_hl_group`). The
  -- removed body text keeps the raw red, so only the accent segment is brighter.
  local add_fg = user_fg("GitDiffAdd") or theme_fg("DiffAdd", "#50FA7B")
  local add_accent = brighten(add_fg, ACCENT_BRIGHTEN)
  pcall(vim.api.nvim_set_hl, 0, "GitDiffAdd",
    { default = true, fg = add_accent, bold = true, bg = brighten(ADD_BG, ACCENT_BG_BRIGHTEN) })
  hl_fg_set["GitDiffAdd"] = add_accent

  local del_fg = user_fg("GitDiffDelete") or theme_fg("DiffDelete", "#FF5555")
  local del_accent = brighten(del_fg, ACCENT_BRIGHTEN)
  pcall(vim.api.nvim_set_hl, 0, "GitDiffDelete",
    { default = true, fg = del_accent, bold = true, bg = brighten(DEL_BG, ACCENT_BG_BRIGHTEN) })
  hl_fg_set["GitDiffDelete"] = del_accent

  -- Subtle-but-visible background tints for the changed sections: yellow
  -- behind added lines, red behind removed virtual lines. Fixed colors tuned
  -- for a dark background; bright enough to be clearly perceptible on their
  -- own (additions have no foreground change, so the yellow tint must carry
  -- the visual cue - the earlier #4a4a1a was too dark to notice).
  pcall(vim.api.nvim_set_hl, 0, "GitDiffAddBg", { default = true, bg = ADD_BG })
  -- The removed body text keeps the raw red fg on the tint bg, so the
  -- brightened "-" accent reads brighter than the text it introduces.
  pcall(vim.api.nvim_set_hl, 0, "GitDiffDeleteBg", { default = true, fg = del_fg, bg = DEL_BG })
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
-- buffer lines against the cached HEAD lines, and place inline `+` markers on
-- added lines / `-` virtual lines for removed lines, per hunk.
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
      -- The removed lines as red virtual lines above/below the anchor row.
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, run.row, 0, {
        virt_lines = run.chunks,
        virt_lines_above = run.above,
        priority = VLINE_PRIORITY,
      })
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
        -- One extmark carrying both the inline "+" marker and the full-line
        -- background tint. `virt_text_pos = "inline"` inserts the glyph at
        -- column 0 like real text (shifting the line content right), so it
        -- reads as part of the line rather than the sign column.
        -- `line_hl_group` fills the whole line - text and the empty space to
        -- its right - so the yellow tint spans the full line width. (A range
        -- with `end_col = -1` + `hl_eol = true` cannot do this: `hl_eol` only
        -- applies to multiline ranges, so it is silently ignored on a
        -- single-line extmark.) A side effect: empty added lines are tinted
        -- too (line_hl_group fills the whole line, empty or not).
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          virt_text = { { "+", "GitDiffAdd" } },
          virt_text_pos = "inline",
          line_hl_group = "GitDiffAddBg",
          priority = MARK_PRIORITY,
        })
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
      local vtext = line:sub(2)
      run.chunks[#run.chunks + 1] = {
        -- Bold red "-" accent, carrying the tint bg so it flows into the body.
        { "-", "GitDiffDelete" },
        { vtext, "GitDiffDeleteBg" },
        -- Pad with spaces (same hl group) so the red tint spans the full line
        -- width. virt_lines have no built-in full-width option; the trailing
        -- whitespace chunk carries the tint to the window edge (clipped by
        -- `trunc` overflow). `strdisplaywidth` so multibyte lines pad right;
        -- "-" is one cell, hence the extra column in the width.
        { string.rep(" ", math.max(VIRT_LINE_WIDTH - vim.fn.strdisplaywidth("-" .. vtext), 0)), "GitDiffDeleteBg" },
      }
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
end

function M.toggle()
  if enabled then
    disable()
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
  apply(bufnr)
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