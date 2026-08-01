local M = {}
local msg = nil
local timer = nil

M.set = function(text, ttl_ms)
  msg = text
  if timer then timer:stop(); timer:close() end
  timer = vim.defer_fn(function() M.clear() end, ttl_ms or 3000)
  pcall(vim.cmd, "redrawstatus")
end

M.get = function() return msg end

M.clear = function()
  msg = nil
  if timer then timer:close(); timer = nil end
  pcall(vim.cmd, "redrawstatus")
end

vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  callback = function() M.clear() end,
})

return M