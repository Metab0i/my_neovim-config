local M = {}

function M.setup()
  -- clangd: --query-driver allowlists the NixOS compiler driver paths so clangd
  -- can invoke cc/gcc (resolved through /run/current-system/sw/bin -> /nix/store)
  -- to discover system include dirs. Without it clangd refuses to query unknown
  -- drivers and can't resolve libc/stdlib headers, breaking go-to-def/peek into
  -- the standard library. NixOS-specific; not needed on conventional distros.
  vim.lsp.config("clangd", {
    cmd = {
      "clangd",
      "--background-index",
      "--clang-tidy",
      "--query-driver=/run/current-system/sw/bin/*,/nix/store/*/bin/*",
    },
  })

  -- lua_ls: mark `vim` as a known global so it doesn't flag every vim.* usage
  -- as an undefined-global diagnostic across this Neovim config.
  vim.lsp.config("lua_ls", {
    settings = {
      Lua = {
        diagnostics = { globals = { "vim" } },
      },
    },
  })

  require("mason").setup()
  require("mason-lspconfig").setup({
    ensure_installed = { "clangd", "ts_ls", "html", "pyright", "lua_ls" },
    automatic_enable = true,
  })
end

return M
