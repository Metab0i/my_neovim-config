local M = {}

M.servers = {
  c = {
    name = "clangd",
    cmd = { "clangd", "--background-index", "--clang-tidy" },
    root_markers = { "compile_commands.json", ".git" },
  },
}

M.add = function(ft, config)
  M.servers[ft] = config
end

M.setup = function()
  for ft, cfg in pairs(M.servers) do
    vim.api.nvim_create_autocmd("FileType", {
      pattern = ft,
      callback = function()
        local root = vim.fs.dirname(
          vim.fs.find(cfg.root_markers, { upward = true })[1]
        ) or vim.loop.cwd()
        vim.lsp.start({
          name = cfg.name,
          cmd = cfg.cmd,
          root_dir = root,
        })
      end,
    })
  end
end

return M
