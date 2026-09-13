-- Line numbering
vim.o.number = true
vim.o.relativenumber = true
vim.o.numberwidth = 1

-- Cursor configs
vim.o.cursorline = true
vim.o.cursorlineopt = "number"
-- Base scrolloff: keep one line of context above/below the cursor while
-- scrolling. The sticky-scope header (ui/context.lua) overrides this per-window
-- with a window-local scrolloff equal to the number of pinned scopes, so the
-- cursor stays below the whole multi-line header; this global value is the
-- fallback for windows without a header.
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
vim.opt.showbreak = "↪ "

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
