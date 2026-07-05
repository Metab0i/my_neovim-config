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

  local body_start = start_line
  for i = start_line, 1, -1 do
    if string.find(lines[i], "{") then
      body_start = i
      break
    end
  end

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

  local result = {}
  for i = body_start, body_end do
    table.insert(result, lines[i])
  end
  return result
end

--- Opens a floating window showing the definition of the symbol under cursor
local function peek_definition()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    vim.notify("No LSP server attached", vim.log.levels.WARN)
    return
  end

  if peek_win_id and vim.api.nvim_win_is_valid(peek_win_id) then
    vim.api.nvim_win_close(peek_win_id, true)
    peek_win_id = nil
  end
  if peek_buf_id and vim.api.nvim_buf_is_valid(peek_buf_id) then
    vim.api.nvim_buf_delete(peek_buf_id, { force = true })
    peek_buf_id = nil
  end

  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(0, "textDocument/definition", params, function(err, result)
    if err then
      vim.notify("LSP error: " .. err.message, vim.log.levels.ERROR)
      return
    end

    if not result or #result == 0 then
      vim.notify("Definition not found", vim.log.levels.INFO)
      return
    end

    local loc = result[1]
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetRange
    local filepath = vim.uri_to_fname(uri)
    local def_line = range.start.line + 1

    local body_lines = extract_function_body(filepath, def_line)
    if #body_lines == 0 then
      vim.notify("Could not read definition", vim.log.levels.WARN)
      return
    end

    peek_buf_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(peek_buf_id, 0, -1, false, body_lines)
    vim.api.nvim_buf_set_option(peek_buf_id, "modifiable", false)
    vim.api.nvim_buf_set_option(peek_buf_id, "buftype", "nofile")
    vim.api.nvim_buf_set_option(peek_buf_id, "filetype", "c")

    local max_width = 80
    local max_height = 20
    local width = max_width
    local height = math.min(#body_lines, max_height)

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
