require("core.lsp_servers").setup()

vim.keymap.set('n', '<C-space>', function()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local diags = vim.diagnostic.get(0, { lnum = lnum - 1 })
  if #diags == 0 then
    require("core.notice").set("no diagnostics at cursor", 3000)
  else
    vim.diagnostic.open_float()
  end
end, { desc = "Open Diagnostics at cursor" })
vim.keymap.set('n', '<leader>gd', function()
  vim.cmd("normal! m'")
  vim.lsp.buf.definition()
end, { desc = "Go to definition" })

vim.keymap.set('n', 'gr', vim.lsp.buf.references, { desc = "Go to references" })
vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, { desc = "Rename symbol" })
vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, { desc = "Code action" })
vim.keymap.set('n', 'K', vim.lsp.buf.hover, { desc = "Hover docs" })
vim.keymap.set('n', '<S-Tab>', vim.lsp.buf.hover, { desc = "Open Docs at cursor" })
