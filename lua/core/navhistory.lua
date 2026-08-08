local M = {}
local back = {}
local forward = {}
local current = nil
local navigating = false
local MAX = 5

local function pos_equal(a, b)
  if a == nil or b == nil then return a == b end
  return a.file == b.file and a.line == b.line and a.col == b.col
end

local function get_pos()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return { file = name, line = cursor[1], col = cursor[2] }
end

local function find_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

M._record = function()
  if navigating then return end
  if vim.bo.buftype ~= "" then return end
  local new = get_pos()
  if new == nil then return end
  if pos_equal(current, new) then return end
  if current ~= nil then
    table.insert(back, current)
    if #back > MAX then table.remove(back, 1) end
    forward = {}
  end
  current = new
end

local function jump_to(pos)
  navigating = true
  local ok = false
  local bufnr = find_buf(pos.file)
  if bufnr > 0 then
    ok = pcall(vim.api.nvim_set_current_buf, bufnr)
  end
  if not ok then
    ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(pos.file))
  end
  if ok then
    pcall(vim.api.nvim_win_set_cursor, 0, { pos.line, pos.col })
    current = pos
  end
  vim.schedule(function() navigating = false end)
  return ok
end

M.back = function()
  if #back == 0 then return end
  local target = table.remove(back)
  local prev = current
  if jump_to(target) then
    if prev then
      table.insert(forward, prev)
      if #forward > MAX then table.remove(forward, 1) end
    end
  else
    table.insert(back, target)
  end
end

M.forward = function()
  if #forward == 0 then return end
  local target = table.remove(forward)
  local prev = current
  if jump_to(target) then
    if prev then
      table.insert(back, prev)
      if #back > MAX then table.remove(back, 1) end
    end
  else
    table.insert(forward, target)
  end
end

M._reset = function()
  back = {}
  forward = {}
  current = nil
  navigating = false
end

M._state = function()
  return { back = back, forward = forward, current = current }
end

vim.api.nvim_create_autocmd("CursorMoved", {
  callback = function() M._record() end,
})

vim.keymap.set('n', '<M-h>',     M.back,    { desc = "Navigate back"    })
vim.keymap.set('n', '<M-Left>',  M.back,    { desc = "Navigate back"    })
vim.keymap.set('n', '<M-l>',     M.forward, { desc = "Navigate forward" })
vim.keymap.set('n', '<M-Right>', M.forward, { desc = "Navigate forward" })

return M