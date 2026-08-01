local M = {}
M.bindings = {}

local function get_notice() return require("core.notice") end

M.add = function(combo, desc, fn)
  M.bindings[combo] = { desc = desc, fn = fn }
end

M.start = function()
  local raw = vim.fn.input({ prompt = " \\ ", default = "", cancelreturn = "\27" })
  if raw == "" or raw == "\27" then return end
  local b = M.bindings[raw]
  if b then
    b.fn()
  else
    get_notice().set("no such binding: \\" .. raw, 2000)
  end
end

vim.keymap.set('n', '<LocalLeader>', M.start, { desc = "LocalLeader menu" })
return M