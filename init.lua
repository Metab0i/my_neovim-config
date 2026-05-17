
-- Line numbering
vim.o.number = true
vim.o.relativenumber = true
vim.o.numberwidth = 1


-- Cursor configs
vim.o.cursorline = true
vim.o.cursorlineopt = "number"
vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#FFFFFF", bold = true })
vim.opt.guicursor = {
  "n-c-v:block",
  "i-ci-ve:ver25",
  "r-cr:hor20",
  "v:block-blinkon500"
}


-- Spacing
vim.o.shiftwidth = 2
vim.o.softtabstop = 2


-- Indentation
vim.wo.wrap = true
vim.wo.breakindent = true
vim.opt.showbreak = "↪  "


-- Other
vim.o.clipboard = "unnamed"


-- Key-bindings
vim.api.nvim_set_keymap('t', '<Esc>', [[<C-\><C-n>]], { noremap = true, silent = true })
vim.keymap.set({'n'}, '<C-space>', vim.diagnostic.open_float, { desc = "Open Diagnostics at cursor" })
vim.keymap.set({'n'}, '<S-Tab>', vim.lsp.buf.hover,	      { desc = "Open Docs at cursor" })
vim.keymap.set({'i'}, '<C-z>', '<C-o>u',		      { desc = "Undo functionality in insert mode" })
vim.keymap.set({'i'}, '<C-r>', '<C-o><C-r>',		      { desc = "Redo functionality in insert mode" })


-- indent-blankline
require("ibl").setup({
  indent = {
    char = "┊",
  }
})






-- Winbar and Status Line configs
if not (vim.bo.filetype == "minimap") then
  vim.wo.winbar = "%m %F"
else
  vim.wo.winbar = ""
end


--- Constructs and returns a statusline config
--- @return string
function setStatusLine ()
  -- diagnostics info
  local diagnostics = vim.diagnostic.get(0)
  local count = { ERR = 0, WARN = 0 }

  for _, d in ipairs(diagnostics) do
    if d.severity == vim.diagnostic.severity.ERROR then
      count.ERR = count.ERR + 1
    elseif d.severity == vim.diagnostic.severity.WARN then
      count.WARN = count.WARN + 1
    end
  end

  -- lsp info
  local lsp_client = vim.lsp.get_clients({ bufnr = 0 })[1]
  local lspc_name = "No LSP"

  if lsp_client ~= nil and lsp_client.name ~= nil then
    lspc_name = lsp_client.name
  end

  -- GIT info
  local git_branch = vim.b.gitsigns_status_dict and vim.b.gitsigns_status_dict.head or "-/-"
  local git_added = vim.b.gitsigns_status_dict and vim.b.gitsigns_status_dict.added or 0
  local git_changed = vim.b.gitsigns_status_dict and vim.b.gitsigns_status_dict.changed or 0
  local git_removed = vim.b.gitsigns_status_dict and vim.b.gitsigns_status_dict.removed or 0

  return "⎇ :"..git_branch.." +:"..git_added.." ~:"..git_changed.." -:"..git_removed.." | Err:"..count.ERR.." Warn:"..count.WARN.."  %= %y:"..lspc_name.." | %p%%"
end

vim.o.laststatus = 3;

vim.api.nvim_create_autocmd({'LspAttach', 'DiagnosticChanged', 'WinEnter', 'BufEnter'}, {
  callback = function(_ev)
    vim.o.statusline = " ";

    -- to make sure that statusline doesn't render for overview minimap
    if vim.bo.filetype == "minimap" then
	vim.wo.statusline = "";
    else
	vim.wo.statusline = setStatusLine();
    end
  end
})











-- Lazy.nvim

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- Make sure to setup `mapleader` and `maplocalleader` before
-- loading lazy.nvim so that mappings are correct.
-- This is also a good place to setup other settings (vim.opt)
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Plugins List & Lazy.nvim Set-up
require("lazy").setup({
  spec = {
    {
      "hrsh7th/nvim-cmp",
      event = "InsertEnter",
      dependencies = {
	"hrsh7th/cmp-nvim-lsp",
	"hrsh7th/cmp-buffer",
	"hrsh7th/vim-vsnip",
	"hrsh7th/cmp-vsnip",
	"hrsh7th/cmp-path",
	"hrsh7th/cmp-cmdline",
	"neovim/nvim-lspconfig",
      }
    },
    {
      "lewis6991/gitsigns.nvim",
      opts = {}
    },
    {
    'nvim-telescope/telescope.nvim',
     branch = "0.1.x",
     dependencies = { 
       'nvim-lua/plenary.nvim'
     }
    },
    {
      "nvim-treesitter/nvim-treesitter",
      branch = 'master',
      lazy = false,
      build = ":TSUpdate"
    },
    {
      "lukas-reineke/indent-blankline.nvim",
      main = "ibl",
      ---@module "ibl"
      ---@type ibl.config
      opts = {},
    },
    {
      "wfxr/minimap.vim",
      init = function ()
	vim.g.minimap_auto_start = 1
	vim.g.minimap_git_colors = 1
	vim.g.minimap_width = 11
      end,
    }
  },


  -- colorscheme that will be used when installing plugins.
  install = { colorscheme = { "habamax" } },
  -- automatically check for plugin updates
  checker = { enabled = true },
})










-- git and gitsigns
--  :Gitsigns diffthis
vim.opt.fillchars:append({ diff = '░'})
require('gitsigns').setup {
  signs = {
    add          = { text = '+' },
    change       = { text = '~' },
    delete       = { text = '_' },
    topdelete    = { text = '‾' },
    changedelete = { text = '┃' },
    untracked    = { text = '┆' },
  },
  signs_staged = {
    add          = { text = '+' },
    change       = { text = '~' },
    delete       = { text = '_' },
    topdelete    = { text = '‾' },
    changedelete = { text = '┃' },
    untracked    = { text = '┆' },
  },
  signs_staged_enable = true,
  signcolumn = true,  -- Toggle with `:Gitsigns toggle_signs`
  numhl      = false, -- Toggle with `:Gitsigns toggle_numhl`
  linehl     = false, -- Toggle with `:Gitsigns toggle_linehl`
  word_diff  = false, -- Toggle with `:Gitsigns toggle_word_diff`
  watch_gitdir = {
    follow_files = true
  },
  auto_attach = true,
  attach_to_untracked = false,
  current_line_blame = false, -- Toggle with `:Gitsigns toggle_current_line_blame`
  current_line_blame_opts = {
    virt_text = true,
    virt_text_pos = 'eol', -- 'eol' | 'overlay' | 'right_align'
    delay = 1000,
    ignore_whitespace = false,
    virt_text_priority = 100,
    use_focus = true,
  },
  current_line_blame_formatter = '<author>, <author_time:%R> - <summary>',
  sign_priority = 6,
  update_debounce = 100,
  status_formatter = nil, -- Use default
  max_file_length = 40000, -- Disable if file is longer than this (in lines)
  preview_config = {
    -- Options passed to nvim_open_win
    style = 'minimal',
    relative = 'cursor',
    row = 0,
    col = 1
  },
}











-- nvim-cmp
local cmp = require'cmp'

cmp.setup({
  snippet = {
    -- REQUIRED - you must specify a snippet engine
    expand = function(args)
      vim.fn["vsnip#anonymous"](args.body)
    end,
  },

  window = {
    completion = cmp.config.window.bordered(),
    documentation = cmp.config.window.bordered(),
  },

  view = {
    entries = 'custom',
  },


  mapping = {
    ['<C-b>'] = cmp.mapping(function(fallback)
      cmp.scroll_docs(-4)
    end, { "i" }),

    ['<C-f>'] = cmp.mapping(function(fallback)
      cmp.scroll_docs(4)
    end, { "i" }),

    ['<C-Space>'] = cmp.mapping(function(fallback)
      cmp.complete()
    end, { "i" }),

    ['<C-e>'] = cmp.mapping(function(fallback)
      cmp.abort()
    end, { "i" }),

    ['<CR>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
	cmp.confirm({ select = true })
      else
	fallback()
      end
    end, { "i", "s" }),

    ['<Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
	cmp.select_next_item()
      else
	fallback()
      end
    end, { "i" }),

    ['<S-Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
	cmp.select_prev_item()
      else
	fallback()
      end
    end, {"i"}),
  },

  sources = cmp.config.sources(
  {
    { name = 'nvim_lsp', priority = 1000 },
    { name = 'vsnip', priority = 900 },
  },

  {
    { name = 'buffer', priority = 50 },
  })
})

-- Use buffer source for `/` and `?` (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline({ '/', '?' }, {
  mapping = cmp.mapping.preset.cmdline(),
  sources = {
    { name = 'buffer' }
  }
})

-- Use cmdline & path source for ':' (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline(':', {
  mapping = cmp.mapping.preset.cmdline(),

  sources = cmp.config.sources(
  {
    { name = 'path' }
  },
  {
    { name = 'cmdline' }
  }),
})














-- LSP server Set-up
-- https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md#lsp-configs

vim.lsp.enable('clangd') -- sudo apt-get install clangd
vim.lsp.enable('lua_ls') -- https://github.com/LuaLS/lua-language-server/releases 
vim.lsp.enable('ts_ls')  -- https://github.com/typescript-language-server/typescript-language-server
vim.lsp.enable('bashls') -- https://github.com/bash-lsp/bash-language-server

local capabilities = require('cmp_nvim_lsp').default_capabilities()

vim.lsp.config['clangd'] = {
  cmd = {'clangd', '--background-index', '--clang-tidy', '--log=verbose'},
  capabilities = capabilities,
}

vim.lsp.config['ts_ls'] = {
  capabilities = capabilities,
}

vim.lsp.config['lua_ls'] = {
  settings = {
    Lua = {
      completion = {
        callSnippet = "Replace",
      },
      diagnostics = {
        globals = { "vim" },
      },
      workspace = {
        library = vim.api.nvim_get_runtime_file("", true),
        checkThirdParty = false,
      },
      telemetry = { enable = false },
    },
  },
  capabilities = capabilities,
}

vim.lsp.config['bashls'] = {
  capabilities = capabilities,
}









-- Telescope Set-up
local telesccope = require('telescope.builtin')
vim.keymap.set('n', '<C-p>p', telesccope.live_grep, {desc = "Telescope Live Grep"});
vim.keymap.set('n', '<C-p>f', telesccope.find_files, {desc = "Telescope Find Files"});













