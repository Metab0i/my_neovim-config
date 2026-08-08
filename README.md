# Neovim Config

A hand-rolled Lua Neovim configuration with no plugin manager. Everything is
built from Neovim's built-in API, with one narrow exception: LSP server
installation and management is delegated to mason.nvim + mason-lspconfig.nvim
+ nvim-lspconfig (added as git submodules under `pack/mason/start/`).

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

LSP servers are installed and managed by
[mason.nvim](https://github.com/mason-org/mason.nvim) +
[mason-lspconfig.nvim](https://github.com/mason-org/mason-lspconfig.nvim),
backed by [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) server
configs. Setup lives in `lua/core/mason.lua`. The three plugins are git
submodules under `pack/mason/start/` and auto-load via Neovim's native
[`:help packages`](https://neovim.io/doc/user/repeat.html#packages) (no plugin
manager).

`automatic_enable = true` (the mason-lspconfig default): any server installed
through Mason is auto-enabled via `vim.lsp.enable()`. This only applies to
Mason-installed servers — servers present only on the system PATH (e.g. from
NixOS) are not recognized and won't be enabled, so install every server you
want via Mason.

### Installing / managing servers

| Command             | Action                                        |
|---------------------|-----------------------------------------------|
| `:LspInstall <srv>` | Install server `<srv>` (nvim-lspconfig name)  |
| `:LspInstall`       | Prompt with servers for the current filetype  |
| `:LspUninstall <s>` | Uninstall a server                            |
| `:Mason`            | Graphical package status / management UI      |
| `:MasonUpdate`      | Update managed registries                     |

### Per-server config overrides

nvim-lspconfig ships sensible defaults (filetypes, root markers, capabilities,
offset encoding). To override for a specific server, call `vim.lsp.config` in
`lua/core/mason.lua` before the `setup()` calls:

```lua
vim.lsp.config("lua_ls", {
  settings = { Lua = { diagnostics = { globals = { "vim" } } } },
})
```

### Updating the plugins themselves

```bash
git submodule update --remote pack/mason/start/*
git add pack/mason/start && git commit  # pin the new SHAs
```

### NixOS-specific setup

Two NixOS nuances affect this config's LSP setup. Both are handled, but
documented here so the setup is reproducible and so anyone porting the config
knows what's NixOS-specific vs. portable.

**1. Precompiled server binaries need `nix-ld`.**

Mason downloads some servers as precompiled generic-Linux binaries (clangd,
lua_ls, and others like rust-analyzer/gopls if added later). NixOS has no
`/lib64/ld-linux-x86-64.so.2` dynamic loader and no `/usr/lib` — it ships a
stub at that path that refuses to run such binaries. Servers run via a Nix
interpreter (ts_ls, html, pyright → Nix `node`) are unaffected.

The fix is [nix-ld](https://github.com/Mic92/nix-ld), which installs a real
loader at that path and surfaces Nix store libraries via `NIX_LD_LIBRARY_PATH`.
Add to `/etc/nixos/configuration.nix` and rebuild (`sudo nixos-rebuild switch`):

```nix
programs.nix-ld.enable = true;
programs.nix-ld.libraries = with pkgs; [
  stdenv.cc.cc.lib   # libstdc++/libgcc_s — clangd/LLVM is C++
  zlib
  zstd
];
```

If a server later reports a missing `libfoo.so`, add the Nix package providing
it to `libraries` and rebuild. `:checkhealth mason` lists remaining gaps.

**2. clangd can't find system headers without `--query-driver`.**

clangd discovers system include dirs (glibc's `<stdio.h>`, etc.) by invoking
the compiler driver named in `compile_commands.json`. Since clangd 12 it
refuses to run unknown driver paths for security, and its default allowlist is
`/usr/bin/*` — which doesn't exist on NixOS (compilers live under
`/run/current-system/sw/bin` → `/nix/store/*/bin`). Without an allowlist,
clangd falls back to its bundled resource dir, can't resolve libc headers, and
go-to-definition/peek into the standard library break.

The fix is the `--query-driver` glob in `lua/core/mason.lua` (commented
in-code). It allowlists the NixOS driver paths so clangd can query the gcc
wrapper and resolve system headers.

### Running this config on non-NixOS

The config works as-is on conventional Linux/macOS. Nothing *needs* deletion —
both NixOS-specific items are harmless no-ops elsewhere:

- `--query-driver` — clangd ignores allowlist entries matching no driver; the
  paths `/run/current-system/sw/bin/*` and `/nix/store/*/bin/*` simply never
  match on a normal distro. Can be left in, or removed from the clangd `cmd`
  in `lua/core/mason.lua` for tidiness (also drop the comment above it).
- `nix-ld` — not a config-repo concern; it's a NixOS system setting. On a
  normal distro the dynamic loader and `/usr/lib` already exist, so mason's
  precompiled binaries run without it. No action.

`ensure_installed`, `automatic_enable`, and all server overrides are fully
portable.

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
lua/core/mason.lua         — mason + lspconfig LSP server management
lua/lsp/init.lua           — LSP keymaps, hover border, diagnostics
lua/peek.lua               — peek definition toggle
lua/ui/winbar.lua          — winbar (modified flag + full path)
lua/ui/statusline.lua      — statusline (diagnostics + LSP + percentage)
pack/mason/start/*         — mason.nvim, mason-lspconfig.nvim, nvim-lspconfig (git submodules)
```