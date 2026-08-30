-- Line numbering
vim.o.number = true
vim.o.relativenumber = true
vim.o.numberwidth = 1

-- Cursor configs
vim.o.cursorline = true
vim.o.cursorlineopt = "number"
-- Keep one line of context above/below the cursor while scrolling. This also
-- keeps the cursor off the top visible line so the sticky-scope header
-- (ui/context.lua, a floating overlay at row 0) never covers the cursor.
vim.o.scrolloff = 1
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

-- Clear search highlights (and forget the pattern) once a / or ? search
-- has landed on a match via Enter.
vim.keymap.set('n', '<CR>', function()
  if vim.v.hlsearch == 1 then
    vim.fn.setreg('/', '')
    if vim.o.hlsearch then vim.cmd('nohlsearch') end
  else
    vim.cmd('normal! +')
  end
end, { desc = "Clear search highlights or go to next line" })
