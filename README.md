# Neovim Config

A plugin-free, hand-rolled Lua Neovim configuration. No plugin manager, no
external dependencies — everything is built from Neovim's built-in API.

## Editor Settings

| Setting            | Value                              | Source
|--------------------|------------------------------------|--------------------------
| Line numbers       | Absolute + relative                | `core/navigation.lua`
| Cursorline         | Number-only highlight              | `core/navigation.lua`
| Shift width        | 2 spaces                           | `core/navigation.lua`
| Clipboard          | Sync with system (`unnamed`)       | `core/navigation.lua`
| Leader             | `<Space>`                          | `core/navigation.lua`
| Winbar             | `%m %F` (modified flag + full path)| `ui/winbar.lua`
| Statusline         | Err/Warn counts, LSP name, `%p%%`  | `ui/statusline.lua`

## LSP

Config-driven server setup via `core/lsp_servers.lua`. Servers are defined in a
table and started automatically on `FileType` based on root markers.

Currently configured: **clangd** for C (with `--background-index --clang-tidy`),
root-detected via `compile_commands.json` or `.git`.

To add a server for a new filetype:

```lua
require("core.lsp_servers").add("rust", {
  name = "rust-analyzer",
  cmd = { "rust-analyzer" },
  root_markers = { "Cargo.toml" },
})
```

All LSP floating windows (hover, diagnostics, signature help) use rounded
borders via a wrapper around `vim.lsp.util.open_floating_preview`.

## Keybindings

### LSP

| Mode   | Key          | Action                                          | Source
|--------|--------------|-------------------------------------------------|--------------------------
| Normal | `<C-Space>`  | Open diagnostics float at cursor (or popup if none) | `lsp/init.lua`
| Normal | `<leader>gd` | Go to definition (sets jump mark `m'`)         | `lsp/init.lua`
| Normal | `gr`         | Go to references                                | `lsp/init.lua`
| Normal | `<leader>rn` | Rename symbol                                   | `lsp/init.lua`
| Normal | `<leader>ca` | Code action                                     | `lsp/init.lua`
| Normal | `K`          | Hover documentation (rounded border, focusable)  | `lsp/init.lua`
| Normal | `<S-Tab>`    | Hover documentation (same as `K`)               | `lsp/init.lua`

Hover float behavior: first press opens unfocused; second press focuses the
float so you can scroll long doc comments with `j`/`k`/`<C-d>`/`<C-f>`;
`q` or `<Esc>` closes it and returns focus.

### Peek Definition

| Mode   | Key          | Action                                     | Source
|--------|--------------|--------------------------------------------|----------
| Normal | `<leader>pd` | Peek definition (toggle)                   | `peek.lua`

Peek is a hover-style toggle with three states:

1. **Closed → Preview:** Opens an unfocused floating window showing ±12 lines
   of context around the definition. `...` in the title/footer border
   indicates more source above/below the context window. Moving the cursor in
   the main buffer closes the preview.
2. **Preview → Focus:** Second `<leader>pd` focuses the peek float.
   - `Enter` — jump to the definition file at that line.
   - `q` / `<Esc>` — close and return to main buffer.
3. **Focused → Close:** Third `<leader>pd` closes the peek.

Placement is overflow-based: defaults above the cursor; flips below when
there isn't enough room above the viewport top.

### Navigation History

| Mode   | Key           | Action             | Source
|--------|---------------|--------------------|--------------------------
| Normal | `<M-Left>`    | Navigate back      | `core/navhistory.lua`
| Normal | `<M-Right>`   | Navigate forward   | `core/navhistory.lua`
| Normal | `<M-h>`       | Navigate back      | `core/navhistory.lua`
| Normal | `<M-l>`       | Navigate forward   | `core/navhistory.lua`

Keeps a 5-slot ring of cursor positions. Records every real file-buffer cursor
move (including jump commands like `<leader>gd`); skips floating scratch buffers
and its own back/forward jumps. Cross-file: jumping to another file and
pressing `<M-Left>` returns you to the previous file and position.

### Notifications

Transient popup notifications appear in the top-right corner with a rounded
border. They auto-dismiss after 5 seconds or on cursor movement, whichever
comes first. Used by:

- `<C-Space>` when there are no diagnostics at the cursor.
- Peek when no LSP server is attached, the definition isn't found, or the
  file can't be read.

### General

| Mode     | Key      | Action                | Source
|----------|----------|-----------------------|--------------------------
| Insert   | `<C-z>`  | Undo                  | `core/navigation.lua`
| Insert   | `<C-r>`  | Redo                  | `core/navigation.lua`
| Terminal | `<Esc>`  | Exit terminal mode    | `core/navigation.lua`

## Module Structure

```
init.lua                   — entry point, requires all modules
lua/core/navigation.lua    — editor settings, leader key, general keymaps
lua/core/navhistory.lua    — back/forward cursor position history
lua/core/notice.lua        — transient popup notifications
lua/core/lsp_servers.lua   — config-driven LSP server setup
lua/lsp/init.lua           — LSP keymaps, hover border, diagnostics
lua/peek.lua               — peek definition toggle
lua/ui/winbar.lua          — winbar (modified flag + full path)
lua/ui/statusline.lua      — statusline (diagnostics + LSP + percentage)
```