--- Constructs and returns a statusline config
--- @return string
local function setStatusLine()
  local diagnostics = vim.diagnostic.get(0)
  local count = { ERR = 0, WARN = 0 }

  for _, d in ipairs(diagnostics) do
    if d.severity == vim.diagnostic.severity.ERROR then
      count.ERR = count.ERR + 1
    elseif d.severity == vim.diagnostic.severity.WARN then
      count.WARN = count.WARN + 1
    end
  end

  local lsp_client = vim.lsp.get_clients({ bufnr = 0 })[1]
  local lspc_name = "No LSP"

  if lsp_client ~= nil and lsp_client.name ~= nil then
    lspc_name = lsp_client.name
  end

  return "Err:" .. count.ERR .. "  Warn:" .. count.WARN .. "  %= %y:" .. lspc_name .. " | %p%%"
end

_G.StatusLine = setStatusLine

vim.o.laststatus = 3
vim.o.statusline = "%!v:lua.StatusLine()"

vim.api.nvim_create_autocmd({ 'DiagnosticChanged' }, {
  callback = function()
    pcall(vim.cmd, "redrawstatus")
  end,
})
