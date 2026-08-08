require("core.lsp_servers").setup()

local preview_original = vim.lsp.util.open_floating_preview
vim.lsp.util.open_floating_preview = function(lines, filetype, opts)
  opts = opts or {}
  if opts.border == nil then opts.border = "rounded" end
  return preview_original(lines, filetype, opts)
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    if vim.bo[args.buf].buftype ~= "nofile" then return end
    vim.keymap.set('n', 'q',     function() pcall(vim.cmd, "close") end, { buffer = args.buf, nowait = true })
    vim.keymap.set('n', '<Esc>', function() pcall(vim.cmd, "close") end, { buffer = args.buf, nowait = true })
  end,
})

vim.keymap.set('n', '<C-space>', function()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local diags = vim.diagnostic.get(0, { lnum = lnum - 1 })
  if #diags == 0 then
    require("core.notice").set("no diagnostics at cursor")
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
