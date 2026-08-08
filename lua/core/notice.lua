local M = {}
local win_id = nil
local buf_id = nil
local timer = nil
local augroup = nil

M.set = function(text, ttl_ms)
  M.clear()

  buf_id = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, { text })
  vim.api.nvim_buf_set_option(buf_id, "modifiable", false)
  vim.api.nvim_buf_set_option(buf_id, "buftype", "nofile")

  local width = math.min(#text, vim.o.columns - 4)

  win_id = vim.api.nvim_open_win(buf_id, false, {
    relative = "editor",
    anchor = "NE",
    row = 0,
    col = vim.o.columns - 1,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
  })

  augroup = "NoticeAutoClose"
  vim.api.nvim_create_augroup(augroup, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    callback = function() M.clear() end,
  })

  timer = vim.defer_fn(function()
    timer = nil
    M.clear()
  end, ttl_ms or 5000)
end

M.get = function() return nil end

M.clear = function()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_name, augroup)
    augroup = nil
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_close(win_id, true)
  end
  win_id = nil
  if buf_id and vim.api.nvim_buf_is_valid(buf_id) then
    vim.api.nvim_buf_delete(buf_id, { force = true })
  end
  buf_id = nil
end

vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  callback = function() M.clear() end,
})

return M