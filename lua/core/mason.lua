local M = {}

function M.setup()
  vim.lsp.config("clangd", {
    cmd = { "clangd", "--background-index", "--clang-tidy" },
  })

  require("mason").setup()
  require("mason-lspconfig").setup({
    ensure_installed = { "clangd", "ts_ls", "html", "pyright" },
    automatic_enable = true,
  })
end

return M