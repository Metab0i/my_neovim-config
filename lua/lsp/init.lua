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

vim.keymap.set({ 'n' }, '<C-space>', vim.diagnostic.open_float, { desc = "Open Diagnostics at cursor" })
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { desc = "Go to definition" })
vim.keymap.set('n', 'gr', vim.lsp.buf.references, { desc = "Go to references" })
vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, { desc = "Rename symbol" })
vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, { desc = "Code action" })
vim.keymap.set('n', 'K', vim.lsp.buf.hover, { desc = "Hover docs" })
vim.keymap.set('n', '<S-Tab>', vim.lsp.buf.hover, { desc = "Open Docs at cursor" })
