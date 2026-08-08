local M = {}

local peek_win = nil
local peek_buf = nil
local peek_filepath = nil
local peek_def_line = nil
local peek_augroup = nil
local peek_state = "closed"
local peek_prev_win = nil

local CONTEXT_LINES = 12
local MAX_HEIGHT = 25

M.peek_row = function(cursor_line, w0, w_last, height)
  local space_above = cursor_line - w0
  local space_below = w_last - cursor_line
  if space_above >= height + 1 then
    return cursor_line - height - 1
  elseif space_below >= height + 1 then
    return cursor_line + 1
  else
    return math.max(w0, cursor_line - height - 1)
  end
end

local close = function()
  if peek_augroup then
    pcall(vim.api.nvim_del_augroup_by_name, peek_augroup)
    peek_augroup = nil
  end
  if peek_win and vim.api.nvim_win_is_valid(peek_win) then
    vim.api.nvim_win_close(peek_win, true)
  end
  peek_win = nil
  if peek_buf and vim.api.nvim_buf_is_valid(peek_buf) then
    vim.api.nvim_buf_delete(peek_buf, { force = true })
  end
  peek_buf = nil
  peek_filepath = nil
  peek_def_line = nil
  peek_state = "closed"
end

local close_and_return = function()
  close()
  if peek_prev_win and vim.api.nvim_win_is_valid(peek_prev_win) then
    pcall(vim.api.nvim_set_current_win, peek_prev_win)
  end
  peek_prev_win = nil
end

local jump_to_def = function()
  local fp = peek_filepath
  local line = peek_def_line
  close_and_return()
  if fp then
    vim.cmd("edit " .. vim.fn.fnameescape(fp))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    vim.cmd("normal! zz")
  end
end

local focus = function()
  if peek_win and vim.api.nvim_win_is_valid(peek_win) then
    peek_prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(peek_win)
    vim.keymap.set('n', '<CR>',  jump_to_def,      { buffer = peek_buf, nowait = true })
    vim.keymap.set('n', 'q',     close_and_return, { buffer = peek_buf, nowait = true })
    vim.keymap.set('n', '<Esc>', close_and_return, { buffer = peek_buf, nowait = true })
    peek_state = "focused"
  end
end

local open_preview = function()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    require("core.notice").set("No LSP server attached")
    return
  end

  vim.cmd("normal! m'")

  local client = clients[1]
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding or client.position_encoding or "utf-16")
  vim.lsp.buf_request(0, "textDocument/definition", params, function(err, result)
    if err then
      require("core.notice").set("LSP error: " .. err.message)
      return
    end
    if not result or #result == 0 then
      require("core.notice").set("Definition not found")
      return
    end

    local loc = result[1]
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetRange
    local filepath = vim.uri_to_fname(uri)
    local def_line = range.start.line + 1

    local file = io.open(filepath, "r")
    if not file then
      require("core.notice").set("Could not read definition file")
      return
    end
    local lines = {}
    for line in file:lines() do
      table.insert(lines, line)
    end
    file:close()

    local start_line = math.max(1, def_line - CONTEXT_LINES)
    local end_line = math.min(#lines, def_line + CONTEXT_LINES)
    local body = {}
    for i = start_line, end_line do
      table.insert(body, lines[i])
    end

    local height = math.min(#body, MAX_HEIGHT)

    local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
    local w0 = vim.fn.line("w0")
    local w_last = vim.fn.line("w$")
    local abs_row = M.peek_row(cursor_row, w0, w_last, height)
    local win_row = math.max(0, abs_row - w0)

    local win_width = vim.api.nvim_win_get_width(0)
    local width = math.min(80, win_width - 2)
    local col = vim.api.nvim_win_get_cursor(0)[2]
    if col + width > win_width then
      col = math.max(0, win_width - width)
    end

    peek_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(peek_buf, 0, -1, false, body)
    vim.api.nvim_buf_set_option(peek_buf, "modifiable", false)
    vim.api.nvim_buf_set_option(peek_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(peek_buf, "filetype", "c")

    local win_config = {
      relative = "win",
      row = win_row,
      col = col,
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      focusable = true,
      noautocmd = true,
    }
    if start_line > 1 then
      win_config.title = "..."
      win_config.title_pos = "center"
    end
    if end_line < #lines then
      win_config.footer = "..."
      win_config.footer_pos = "center"
    end

    peek_win = vim.api.nvim_open_win(peek_buf, false, win_config)
    peek_filepath = filepath
    peek_def_line = def_line
    peek_state = "preview"

    peek_augroup = "PeekDefinitionAutoClose"
    vim.api.nvim_create_augroup(peek_augroup, { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = peek_augroup,
      callback = function()
        if peek_state == "preview"
          and vim.api.nvim_get_current_win() ~= peek_win then
          close()
        end
      end,
    })
  end)
end

M.peek_definition = function()
  if peek_state == "closed" then
    open_preview()
  elseif peek_state == "preview" then
    focus()
  elseif peek_state == "focused" then
    close_and_return()
  end
end

M._close = close
M._state = function() return peek_state end

vim.keymap.set('n', '<leader>pd', M.peek_definition, { desc = "Peek definition" })

return M