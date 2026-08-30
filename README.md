# Neovim Config

A hand-rolled Lua Neovim config with no plugin manager, except LSP install/management via `mason.nvim` + `mason-lspconfig.nvim` + `nvim-lspconfig` (git submodules under `pack/mason/start/*`).


## Keybindings

### LSP

| Mode   | Key          | Action                                          | Source
|--------|--------------|-------------------------------------------------|--------------------------
| Normal | `<C-Space>`  | Diagnostics float at cursor (or popup if none)  | `lsp/init.lua`
| Normal | `<leader>gd` | Go to definition (sets jump mark `m'`)          | `lsp/init.lua`
| Normal | `gr`         | Go to references                                | `lsp/init.lua`
| Normal | `<leader>rn` | Rename symbol                                   | `lsp/init.lua`
| Normal | `<leader>ca` | Code action                                     | `lsp/init.lua`
| Normal | `K`          | Hover documentation (rounded border)             | `lsp/init.lua`
| Normal | `<S-Tab>`    | Hover documentation (same as `K`)                | `lsp/init.lua`

Hover float: first press opens unfocused; second focuses to scroll with
`j`/`k`/`<C-d>`/`<C-f>`; `q`/`<Esc>` closes.

### Autocomplete

| Mode   | Key          | Action                                  | Source
|--------|--------------|-----------------------------------------|--------------------------
| Insert | `<C-Space>`  | Toggle LSP ghost-line autocomplete       | `autocomplete.lua`
| Insert | `<Tab>`      | Cycle candidate forward (while active)   | `autocomplete.lua`
| Insert | `<S-Tab>`    | Cycle candidate backward (while active)  | `autocomplete.lua`
| Insert | `<CR>`       | Accept the shown candidate (while active)| `autocomplete.lua`

Press `<C-Space>` to request `textDocument/completion` from all attached
servers and show **one** ghost suggestion line below the cursor, filtered to
items matching the word before the cursor. Empty prefix is allowed only right
after `.`, `::`, or `->`. `<Tab>`/`<S-Tab>` cycle a lazy 20-wide expanding
window (cycling past the edge loads another 20, up to everything the LSP
returned, with wrap-around). `<CR>` inserts only the part of the
label/`insertText` after the already-typed prefix (snippet placeholders
`${1:..}`/`$1` stripped) and closes. A second `<C-Space>` cancels. While active,
typing refilters live and auto-closes when the prefix matches nothing; it also
closes on line change, `<Esc>`, or leaving the buffer. When inactive, `<Tab>`
and `<CR>` fall through to their defaults. `isIncomplete` is ignored (single
fetch). Normal-mode `<C-Space>` (diagnostics) is unaffected.

### Peek Definition

| Mode   | Key          | Action             | Source
|--------|--------------|--------------------|----------
| Normal | `<leader>pd` | Peek definition    | `peek.lua`

Three-state toggle across presses: **(1)** open - unfocused float showing ±12
lines of context around the definition, defaulting above the cursor and
flipping below when no room above (cursor movement closes it); **(2)** focus -
`Enter` jumps to the file, `q`/`<Esc>` closes; **(3)** close.

### Navigation History

| Mode   | Key           | Action           | Source
|--------|---------------|------------------|--------------------------
| Normal | `<M-Left>`    | Navigate back    | `core/navhistory.lua`
| Normal | `<M-Right>`   | Navigate forward | `core/navhistory.lua`
| Normal | `<M-h>`       | Navigate back    | `core/navhistory.lua`
| Normal | `<M-l>`       | Navigate forward | `core/navhistory.lua`

15-slot ring of cursor positions; records every real file-buffer move (incl.
jump commands), skips floating scratch buffers, and works cross-file - jump
to another file, `<M-Left>` returns you to the previous file/position.

### Sticky Scope Context

No keymap - always on. Source: `ui/context.lua` (+ shared engine `core/
scope_engine.lua`).

While the cursor is inside nested scopes (function/class/method/block) whose
opening lines have scrolled out of view, those opener lines are pinned to the
top of the window as a multi-line floating header - the full ancestor chain,
outermost at the top and innermost at the bottom - so you always know where you
are while scrolling. When a scope's opener scrolls back into view it drops off
the header; when you reach the file top the header disappears.

Scope resolution merges LSP `textDocument/documentSymbol` (functions, classes,
methods, structs, ...) with the same indentation heuristic the execution
panel's `/fold` commands use (block scopes without LSP), via the shared
`core/scope_engine.lua` module. All enclosing scopes are shown, stacked
outermost-first, with each child indented 2 spaces per level to convey nesting.
It is rendered per-window, so splits of the same file each get their own header.

Styling: highlight group `StickyScope` (by default a subtle band: `Comment`
foreground over the `CursorLine` background, re-derived when the colorscheme
changes; override it in your config to restyle - the header is separated from
the buffer by its background, with no border line). `StickyScopeSeparator`
remains defined in case you want to underline the last header line yourself.
The winbar (`ui/winbar.lua`) is unchanged - this header lives inside the
viewport.

The header overlays the topmost visible lines and never covers the cursor: its
height is dynamically capped to the number of screen rows above the cursor
(wrap/fold aware), capped at 6 lines, and when it must shrink the innermost
(most specific) scopes are kept. The config's `scrolloff = 1` normally keeps a
context line above the cursor anyway, so the cursor is never hidden behind the
header.

### Execution Panel

| Mode   | Key              | Action                          | Source
|--------|------------------|---------------------------------|--------------------------
| Normal | `<leader><leader>` | Toggle execution panel       | `core/execution_panel/init.lua`
| Insert | `/?`             | Show info panel                 | `core/execution_panel/init.lua`
| Insert | `/fstr <substr>` | Cross-file substring search     | `core/execution_panel/findstring.lua`
| Insert | `/replace -m … -r …` | Live in-buffer replace      | `core/execution_panel/replace.lua`
| Insert | `/replace -help` | Show replace usage             | `core/execution_panel/replace.lua`
| Insert | `/fold` / `/unfold` / `/foldall` / `/unfoldall` + `<Enter>` | Fold/unfold scopes | `core/execution_panel/scopes.lua`
| Insert | `<Enter>`        | Run scopes cmd (scopes mode) / replace one (replace) / open file (file/fstr) | `…/init.lua`
| Insert | `<M-Enter>`      | Replace ALL matches             | `core/execution_panel/replace.lua`
| Insert | `J` / `K`        | Cycle current match (replace)   | `core/execution_panel/replace.lua`
| Insert | `<Shift-Up/Down>`| Cycle current match (replace) / cycle file (fstr) | `…/init.lua`
| Insert | `<Tab>`/`<S-Tab>`| Cycle file suggestion (file) / cycle occurrence (fstr) | `…/init.lua`
| Insert | `<Up>`/`<Down>`  | Cycle file suggestion (file) / cycle file (fstr) | `…/init.lua`
| Insert | `<Esc>`         | Close panel (restore original file+cursor on `/fstr`) | `…/init.lua`

A single-line input (inset 5 cells left/right) opened with `<Space><Space>`, split
into sibling submodules under `lua/core/execution_panel/`(`init.lua` is the entry:
shared panel state, window/dropdown infra, mode router, keymap dispatcher):

- **File search** (`findfile.lua`, discovery via `discovery.lua`): typing fuzzy-
  searches files in the current file's directory (+ its git root) and the CWD
  `nvim` launched in (deduped; basename-priority ranking); `.git` and
  `node_modules` are excluded, and ripgrep's default `.gitignore` respect applies.
  `<Enter>` opens the highlighted suggestion via `:edit`.
- **`/fstr <literal-substring>`** (`findstring.lua`): case-sensitive cross-file
  substring search over the same discovery dirs (`.git`/`node_modules` excluded).
  Shows matching files with the total occurrence count right-aligned on each row,
  ranked by count desc then path asc. The highlighted file is **previewed live** in
  the underlying window at its first match, debounced ~100 ms while typing and
  instant on arrow nav. `<Up>`/`<Down>` cycle files; `<Tab>`/`<S-Tab>` cycle
  occurrences within the previewed file; `<Enter>` opens the highlighted file and
  hands the pattern to `@/` (literal, `\V…`) with `hlsearch` so `n`/`N` continue;
  `<Esc>` restores the original file, cursor and `@/`. Navigation history (`core/
  navhistory.lua`) is paused during the preview so cycling files doesn't pollute
  the back/forward ring, then resumed after `<Esc>`/`<Enter>`.
- **`/replace -m <vimregex> -r <replacement>`** (`replace.lua`): live in-buffer
  replacement with extmark preview (match = Search + strikethrough, replacement =
  Substitute inline virt text, current = IncSearch); `-r` may be omitted to delete
  matches. `/replace -help` shows usage; `/?` shows a brief info panel. `J`/`K` and
  `<Shift-Up/Down>` cycle the current match; `<Enter>` replaces one, `<M-Enter>`
  replaces all.
- **Scope folding** (`scopes.lua`): `/fold`, `/unfold`, `/foldall`, `/unfoldall`
  fire on `<Enter>` (then the panel closes and focus returns to the file). Scopes
  come from LSP `textDocument/documentSymbol` (functions, methods, classes,
  structs, enums, interfaces, namespaces, modules) merged with an indentation
  heuristic for `if`/`loop`/`switch`/block scopes (pure-indent fallback when no
  LSP client). Folds use `foldmethod=manual` with `foldtext = "..."`: each scope's
  **body** is folded while the opener line stays visible, so a folded scope renders
  as the opener followed by a `...` line. `/fold` folds the innermost scope
  enclosing the cursor; `/unfold` opens the innermost enclosing fold; `/foldall`
  collapses every scope; `/unfoldall` clears all folds and restores the prior fold
  settings. Folds persist after the panel closes.

The panel slides to the **bottom** of the viewport (dropdown above it) when the top
of the file is within a few lines of the viewport top (otherwise it docks at the
top), so the opening lines stay visible. Position is re-evaluated on open, scroll
(`WinScrolled`), and after each match cycle.

| Mode   | Key     | Action                              | Source
|--------|---------|-------------------------------------|--------------------------
| Normal | `<CR>`  | Clear search highlights or next line | `core/navigation.lua`

Forgets the `/` or `?` search pattern (`@/`) when search highlights are active,
otherwise performs the default `<CR>` (next line).

### Notifications

Transient popups in the top-right, rounded border, auto-dismiss after 5 s or on
cursor movement. Used by `<C-Space>` when no diagnostics at cursor, and by
Peek when no LSP server is attached / definition not found / file unreadable.

### General

| Mode     | Key     | Action              | Source
|----------|---------|---------------------|--------------------------
| Insert   | `<C-z>` | Undo                | `core/navigation.lua`
| Insert   | `<C-r>` | Redo                | `core/navigation.lua`
| Terminal | `<Esc>` | Exit terminal mode  | `core/navigation.lua`

## Editor Settings

| Setting      | Value                               | Source
|--------------|-------------------------------------|--------------------------
| Line numbers | Absolute + relative                 | `core/navigation.lua`
| Cursorline   | Number-only highlight               | `core/navigation.lua`
| Scrolloff    | 1 (keeps the cursor off the row the sticky-scope header overlays) | `core/navigation.lua`
| Shift width  | 2 spaces                            | `core/navigation.lua`
| Clipboard    | Sync with system (`unnamed`)        | `core/navigation.lua`
| Leader       | `<Space>`                           | `core/navigation.lua`
| Winbar       | `%m %F` (modified flag + full path) | `ui/winbar.lua`
| Statusline   | Err/Warn counts, LSP name, `%p%%`   | `ui/statusline.lua`

All LSP floating windows (hover, diagnostics, signature help) use rounded
borders via a wrapper around `vim.lsp.util.open_floating_preview`.

## Programming Languages

Per-language notes for getting full LSP support. General server install/enable
lives in ## LSP below; this covers what each language needs *beyond* the
default `vim.lsp.enable()`.

### C/C++

**clangd** (in `ensure_installed`, auto-enabled) handles C, C++,
Objective-C, and CUDA.

**System headers (glibc: `<stdio.h>` etc.).** clangd queries the compiler
driver named in the compile command to discover these. With a
`compile_commands.json` the database names the driver and the `--query-driver`
glob in `lua/core/mason.lua` allowlists it, so stdlib resolves. Without a
database clangd falls back to a hardcoded `clang` driver absent on NixOS, so
stdlib silently breaks for scratch files. 

Three fixes, strongest first:

| Option | Scope | What |
|--------|------|------|
| `compile_commands.json` | per real project | clangd uses your actual compiler + flags. Most accurate; always fixes stdlib because it names the driver. |
| Global clangd config (`~/.config/clangd/config.yaml`) | all scratch files | `CompileFlags: { Compiler: gcc }` makes clangd query NixOS gcc -> resolves glibc wherever no database covers. One-time setup, auto-tracks nixpkgs updates. |
| Install `clang` (NixOS package) | all scratch files | Gives clangd its native default `clang` driver. Adds LLVM (~hundreds of MB). Alternative to the global config. |

A database wins for files it covers; the global config fills the gaps.

**Generating `compile_commands.json`:**
- CMake: `set(CMAKE_EXPORT_COMPILE_COMMANDS ON)` (or
  `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`), then symlink/copy
  `build/compile_commands.json` to the project root.
- Make/generic: `bear -- make` (install `bear`).
- Trivial single-file: `compile_flags.txt`, one flag per line
  (e.g. `-I./include -DDEBUG`).

**`~/.config/clangd/config.yaml`** (for the global-fallback option):

```yaml
# clangd's default fallback driver (clang) is absent on NixOS - make it
# query the system gcc instead, which Nix patches to expose glibc's store
# path. Relies on the --query-driver glob in lua/core/mason.lua.
CompileFlags:
  Compiler: gcc
```

## LSP

Servers are installed and managed by
[mason.nvim](https://github.com/mason-org/mason.nvim) +
[mason-lspconfig.nvim](https://github.com/mason-org/mason-lspconfig.nvim),
backed by [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) server
configs. Setup lives in `lua/core/mason.lua`; the three plugins are git
submodules under `pack/mason/start/` that auto-load via Neovim's native
[`:help packages`](https://neovim.io/doc/user/repeat.html#packages) (no plugin
manager). With `automatic_enable = true` (default), Mason-installed servers are
auto-enabled via `vim.lsp.enable()`. Install every server you want via Mason
(system-installed ones, e.g. from NixOS, are **not** recognized).

### Managing servers

| Command             | Action                                       |
|---------------------|----------------------------------------------|
| `:LspInstall <srv>` | Install server `<srv>` (nvim-lspconfig name) |
| `:LspInstall`       | Prompt with servers for the current filetype  |
| `:LspUninstall <s>` | Uninstall a server                           |
| `:Mason`            | Package status / management UI               |
| `:MasonUpdate`      | Update managed registries                    |

### Per-server config overrides

nvim-lspconfig ships sensible defaults (filetypes, root markers, capabilities).
To override, call `vim.lsp.config` in `lua/core/mason.lua` before `setup()`:

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

## NixOS

### nix-ld (precompiled server binaries)

Mason downloads some servers as precompiled generic-Linux binaries (clangd,
lua_ls, and others like rust-analyzer/gopls if added later). NixOS has no
`/lib64/ld-linux-x86-64.so.2` dynamic loader - it ships a stub that refuses
such binaries (servers run via a Nix interpreter like ts_ls/html/pyright are
unaffected). The fix is [nix-ld](https://github.com/Mic92/nix-ld), which
installs a real loader at that path and surfaces Nix store libraries via
`NIX_LD_LIBRARY_PATH`. Add to `/etc/nixos/configuration.nix` and rebuild:

```nix
programs.nix-ld.enable = true;
programs.nix-ld.libraries = with pkgs; [
  stdenv.cc.cc.lib   # libstdc++/libgcc_s - clangd/LLVM is C++
  zlib
  zstd
];
```

If a server reports a missing `libfoo.so`, add the Nix package providing it to
`libraries` and rebuild. `:checkhealth mason` lists remaining gaps.

### clangd `--query-driver`

clangd queries the compiler driver to discover system include dirs, but
since clangd 12 refuses to run unknown driver paths for security (default
allowlist is `/usr/bin/*`, absent on NixOS). The `--query-driver` glob in
`lua/core/mason.lua` (commented in-code) allowlists
`/run/current-system/sw/bin/*` and `/nix/store/*/bin/*` so clangd can query
the gcc wrapper and resolve system headers.

### Running this config on non-NixOS

The config works as-is on conventional Linux/macOS - both NixOS-specific items
are harmless no-ops elsewhere:
- `--query-driver` - allowlisted paths don't match on a normal distro; can be
  left in or removed for tidiness (also drop the comment above it). `nix-ld`
  is a NixOS system setting - on a normal distro the dynamic loader and
  `/usr/lib` already exist.
- `ensure_installed`, `automatic_enable`, and all server overrides are
  fully portable.

## Module Structure

```
init.lua                   - entry point, requires all modules
lua/core/navigation.lua    - editor settings, leader key, general keymaps
lua/core/navhistory.lua    - back/forward cursor position history (pause/resume for /fstr preview)
lua/core/scope_engine.lua  - shared scope ranges (indent heuristic + LSP documentSymbol + innermost picker)
lua/core/notice.lua        - transient popup notifications
lua/core/mason.lua         - mason + lspconfig LSP server management
lua/core/execution_panel/  - quick-action panel (`<leader><leader>`)
  init.lua                 - shared panel state, window/dropdown infra, mode router, keymaps
  discovery.lua            - rules/logic for file + content (substring) search (no UI)
  findfile.lua             - fuzzy file-find UI + integration (uses discovery)
  replace.lua              - in-buffer regex live-replace (logic + UI)
  findstring.lua           - /fstr cross-file substring search (UI + integration)
  scopes.lua               - /fold /unfold /foldall /unfoldall scope folding (LSP + indent)
lua/lsp/init.lua           - LSP keymaps, hover border, diagnostics
lua/autocomplete.lua       - virtual-line LSP autocomplete (C-Space toggle)
lua/peek.lua               - peek definition toggle
lua/ui/winbar.lua          - winbar (modified flag + full path)
lua/ui/context.lua         - sticky current-scope header (pinned scope line while scrolling)
lua/ui/statusline.lua      - statusline (diagnostics + LSP + percentage)
pack/mason/start/*         - mason.nvim, mason-lspconfig.nvim, nvim-lspconfig (git submodules)
```
