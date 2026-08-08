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
vim.opt.showbreak = "  "

-- Other
vim.o.clipboard = "unnamed"

-- Leader key
vim.g.mapleader = " "

-- Key-bindings
vim.api.nvim_set_keymap('t', '<Esc>', [[<C-\><C-n>]], { noremap = true, silent = true })
vim.keymap.set({'i'}, '<C-z>', '<C-o>u', { desc = "Undo functionality in insert mode" })
vim.keymap.set({'i'}, '<C-r>', '<C-o><C-r>', { desc = "Redo functionality in insert mode" })
