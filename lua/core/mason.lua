local M = {}

function M.setup()
  vim.lsp.config("clangd", {
    cmd = {
      "clangd",
      "--background-index",
      "--clang-tidy",
      "--query-driver=/run/current-system/sw/bin/*,/nix/store/*/bin/*",
    },
  })

  require("mason").setup()
  require("mason-lspconfig").setup({
    ensure_installed = { "clangd", "ts_ls", "html", "pyright" },
    automatic_enable = true,
  })
end

return M