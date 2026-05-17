
-- Line numbering
vim.o.number = true
vim.o.relativenumber = true
vim.o.numberwidth = 1


-- Cursor configs
vim.o.cursorline = true
vim.o.cursorlineopt = "number"
vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#FFFFFF", bold = true })
vim.opt.guicursor = {
  "n-c-v:block",
  "i-ci-ve:ver25",
  "r-cr:hor20",
  "v:block-blinkon500"
}


-- Spacing
vim.o.shiftwidth = 2
vim.o.softtabstop = 2


-- Indentation
vim.wo.wrap = true
vim.wo.breakindent = true
vim.opt.showbreak = "↪  "


-- Other
vim.o.clipboard = "unnamed"


-- Leader keys
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"


-- Key-bindings
vim.api.nvim_set_keymap('t', '<Esc>', [[<C-\><C-n>]], { noremap = true, silent = true })
vim.keymap.set({'n'}, '<C-space>', vim.diagnostic.open_float, { desc = "Open Diagnostics at cursor" })
vim.keymap.set({'i'}, '<C-z>', '<C-o>u',		      { desc = "Undo functionality in insert mode" })
vim.keymap.set({'i'}, '<C-r>', '<C-o><C-r>',		      { desc = "Redo functionality in insert mode" })


-- Winbar
vim.wo.winbar = "%m %F"


--- Constructs and returns a statusline config
--- @return string
function setStatusLine ()
  -- diagnostics info
  local diagnostics = vim.diagnostic.get(0)
  local count = { ERR = 0, WARN = 0 }

  for _, d in ipairs(diagnostics) do
    if d.severity == vim.diagnostic.severity.ERROR then
      count.ERR = count.ERR + 1
    elseif d.severity == vim.diagnostic.severity.WARN then
      count.WARN = count.WARN + 1
    end
  end

  -- lsp info
  local lsp_client = vim.lsp.get_clients({ bufnr = 0 })[1]
  local lspc_name = "No LSP"

  if lsp_client ~= nil and lsp_client.name ~= nil then
    lspc_name = lsp_client.name
  end

  return "Err:"..count.ERR.." Warn:"..count.WARN.."  %= %y:"..lspc_name.." | %p%%"
end

vim.o.laststatus = 3

vim.api.nvim_create_autocmd({'DiagnosticChanged', 'WinEnter', 'BufEnter'}, {
  callback = function(_ev)
    vim.wo.statusline = setStatusLine()
  end
})


-- LSP
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'c',
  callback = function()
    vim.lsp.start({
      name = 'clangd',
      cmd = { 'clangd', '--background-index', '--clang-tidy' },
      root_dir = vim.fs.dirname(vim.fs.find({ 'compile_commands.json', '.git' }, { upward = true })[1]) or vim.loop.cwd(),
    })
  end,
})

vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { desc = "Go to definition" })
vim.keymap.set('n', 'gr', vim.lsp.buf.references, { desc = "Go to references" })
vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, { desc = "Rename symbol" })
vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, { desc = "Code action" })
vim.keymap.set('n', 'K', vim.lsp.buf.hover, { desc = "Hover docs" })
vim.keymap.set('n', '<S-Tab>', vim.lsp.buf.hover, { desc = "Open Docs at cursor" })


-- Peek Definition (vanilla, no plugins)

local peek_win_id = nil
local peek_buf_id = nil
local peek_augroup = nil

--- Extracts the full function body from a file given the start line
--- @param filepath string
--- @param start_line number (1-indexed, the line of the definition)
--- @return string[]
local function extract_function_body(filepath, start_line)
  local file = io.open(filepath, "r")
  if not file then return {} end

  local lines = {}
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()

  if start_line < 1 or start_line > #lines then return {} end

  -- Scan backwards from start_line to find the opening '{' of the function body
  local body_start = start_line
  for i = start_line, 1, -1 do
    if string.find(lines[i], "{") then
      body_start = i
      break
    end
  end

  -- Count braces from body_start to find matching '}'
  local depth = 0
  local body_end = body_start
  for i = body_start, #lines do
    for c in string.gmatch(lines[i], ".") do
      if c == "{" then depth = depth + 1 end
      if c == "}" then depth = depth - 1 end
    end
    if depth == 0 then
      body_end = i
      break
    end
  end

  -- Extract the function body
  local result = {}
  for i = body_start, body_end do
    table.insert(result, lines[i])
  end
  return result
end

--- Opens a floating window showing the definition of the symbol under cursor
function peek_definition()
  -- Check if LSP client is attached
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    vim.notify("No LSP server attached", vim.log.levels.WARN)
    return
  end

  -- Close any existing peek window
  if peek_win_id and vim.api.nvim_win_is_valid(peek_win_id) then
    vim.api.nvim_win_close(peek_win_id, true)
    peek_win_id = nil
  end
  if peek_buf_id and vim.api.nvim_buf_is_valid(peek_buf_id) then
    vim.api.nvim_buf_delete(peek_buf_id, { force = true })
    peek_buf_id = nil
  end

  -- Request definition from LSP
  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(0, "textDocument/definition", params, function(err, result, ctx, config)
    if err then
      vim.notify("LSP error: " .. err.message, vim.log.levels.ERROR)
      return
    end

    if not result or #result == 0 then
      vim.notify("Definition not found", vim.log.levels.INFO)
      return
    end

    -- Get the first definition location
    local loc = result[1]
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetRange
    local filepath = vim.uri_to_fname(uri)
    local def_line = range.start.line + 1 -- Convert to 1-indexed

    -- Extract the function body
    local body_lines = extract_function_body(filepath, def_line)
    if #body_lines == 0 then
      vim.notify("Could not read definition", vim.log.levels.WARN)
      return
    end

    -- Create scratch buffer
    peek_buf_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(peek_buf_id, 0, -1, false, body_lines)
    vim.api.nvim_buf_set_option(peek_buf_id, "modifiable", false)
    vim.api.nvim_buf_set_option(peek_buf_id, "buftype", "nofile")
    vim.api.nvim_buf_set_option(peek_buf_id, "filetype", "c")

    -- Calculate window dimensions
    local max_width = 80
    local max_height = 20
    local width = max_width
    local height = math.min(#body_lines, max_height)

    -- Position window near cursor
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
    local win_height = vim.api.nvim_win_get_height(0)
    local row = cursor_row + 1
    if row + height > win_height then
      row = math.max(1, cursor_row - height - 1)
    end

    local col = vim.api.nvim_win_get_cursor(0)[2]
    local win_width = vim.api.nvim_win_get_width(0)
    if col + width > win_width then
      col = math.max(0, win_width - width)
    end

    -- Open floating window
    peek_win_id = vim.api.nvim_open_win(peek_buf_id, false, {
      relative = "win",
      row = row,
      col = col,
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      focusable = false,
      noautocmd = true,
    })

    -- Set up auto-close on cursor move
    if peek_augroup then
      vim.api.nvim_del_augroup_by_name(peek_augroup)
    end
    peek_augroup = "PeekDefinitionAutoClose"
    vim.api.nvim_create_augroup(peek_augroup, { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = peek_augroup,
      callback = function()
        if peek_win_id and vim.api.nvim_win_is_valid(peek_win_id) then
          vim.api.nvim_win_close(peek_win_id, true)
          peek_win_id = nil
        end
        if peek_buf_id and vim.api.nvim_buf_is_valid(peek_buf_id) then
          vim.api.nvim_buf_delete(peek_buf_id, { force = true })
          peek_buf_id = nil
        end
        vim.api.nvim_del_augroup_by_name(peek_augroup)
        peek_augroup = nil
      end,
    })
  end)
end

vim.keymap.set('n', '<leader>pd', peek_definition, { desc = "Peek definition" })
