# nvim config

Personal Neovim configuration. Modular, lazy.nvim-based, kickstart-derived.

## Structure

```
├── init.lua                  Entry point
└── lua/
    ├── core/                 Editor settings, keymaps, autocommands
    ├── plugins/
    │   ├── index.lua         Plugin specs + lazy.nvim bootstrap
    │   ├── config/           Per-plugin configuration
    │   └── lsp/              LSP setup + per-server configs
    └── snippets/             LuaSnip snippets
```

## Plugins

### Plugin Manager
| Plugin | Purpose |
|--------|---------|
| `folke/lazy.nvim` | Plugin manager |

### LSP & Completion
| Plugin | Purpose |
|--------|---------|
| `neovim/nvim-lspconfig` | LSP configuration framework |
| `williamboman/mason.nvim` | LSP/tool installer UI |
| `williamboman/mason-lspconfig.nvim` | Mason ↔ lspconfig bridge |
| `WhoIsSethDaniel/mason-tool-installer.nvim` | Auto-install tools on startup |
| `saghen/blink.cmp` | Fast completion engine |
| `hrsh7th/nvim-cmp` | Completion framework |
| `L3MON4D3/LuaSnip` | Snippet engine |
| `folke/lazydev.nvim` | Lua LSP for nvim config files |

### Formatting & Linting
| Plugin | Purpose |
|--------|---------|
| `stevearc/conform.nvim` | Formatter runner (format on save) |
| `nvimtools/none-ls.nvim` | null-ls successor (ESLint diagnostics) |
| `nvimtools/none-ls-extras.nvim` | Extra none-ls sources |

### Git
| Plugin | Purpose |
|--------|---------|
| `lewis6991/gitsigns.nvim` | Git diff signs in sign column |
| `fatih/gomodifytags` | Go struct tag manipulation |

### Navigation & Fuzzy Finding
| Plugin | Purpose |
|--------|---------|
| `nvim-telescope/telescope.nvim` | Fuzzy finder |
| `nvim-telescope/telescope-fzf-native.nvim` | FZF sorter for Telescope |
| `nvim-telescope/telescope-ui-select.nvim` | Telescope UI for code actions |
| `christoomey/vim-tmux-navigator` | Seamless Neovim ↔ Tmux navigation |
| `tpope/vim-sleuth` | Auto-detect indentation |

### File Browser
| Plugin | Purpose |
|--------|---------|
| `stevearc/oil.nvim` | Directory-editing file browser |
| `nvim-tree/nvim-web-devicons` | File type icons |

### Text Editing
| Plugin | Purpose |
|--------|---------|
| `numToStr/Comment.nvim` | `gc`/`gbc` commenting |
| `windwp/nvim-autopairs` | Auto-close brackets and quotes |
| `gaoDean/autolist.nvim` | Auto-continue lists in markdown/text |

### Debugging
| Plugin | Purpose |
|--------|---------|
| `mfussenegger/nvim-dap` | Debug Adapter Protocol client |
| `rcarriga/nvim-dap-ui` | Debug panels (scopes, stacks, watches, console) |
| `nvim-neotest/nvim-nio` | Async library (dap-ui dependency) |
| `leoluz/nvim-dap-go` | Go/delve adapter, debug-nearest-test, attach |
| `theHamsta/nvim-dap-virtual-text` | Inline variable values while stepping |
| `Weissle/persistent-breakpoints.nvim` | Breakpoints survive nvim restarts |

### Markdown
| Plugin | Purpose |
|--------|---------|
| `MeanderingProgrammer/render-markdown.nvim` | Rendered markdown in buffer |
| `irrationalistic/volt` | Markdown link navigation |
| `TadeasKrivak/markdown.nvim` | Markdown link handling (volt dependency) |

### Syntax & Parsing
| Plugin | Purpose |
|--------|---------|
| `nvim-treesitter/nvim-treesitter` | Syntax highlighting + folding |
| `folke/todo-comments.nvim` | Highlight TODO/FIXME/HACK/etc |

### UI & Theming
| Plugin | Purpose |
|--------|---------|
| `folke/tokyonight.nvim` | Colorscheme (night variant) |
| `echasnovski/mini.nvim` | mini.ai, mini.surround, mini.statusline |
| `echasnovski/mini.icons` | Icon support |
| `folke/which-key.nvim` | Keybinding popup help |
| `j-hui/fidget.nvim` | LSP progress spinner |
| `brenoprata10/nvim-highlight-colors` | Inline color swatches |
| `guimonden/minty` | Color picker |

### Utilities
| Plugin | Purpose |
|--------|---------|
| `nvim-lua/plenary.nvim` | Lua utilities (telescope/todo-comments dependency) |

---

## Commands

### Custom
| Command | Description |
|---------|-------------|
| `:GoAddTags <format>` | Add Go struct tags — e.g. `:GoAddTags json` |

### Plugin-provided
| Command | Plugin |
|---------|--------|
| `:Mason` | Open Mason installer UI |
| `:ConformInfo` | Show active formatters for current buffer |
| `:Lazy` | Open lazy.nvim plugin manager UI |
| `:Telescope <picker>` | Open a Telescope picker |
| `:Oil` | Open oil file browser |
| `:TSUpdate` | Update treesitter parsers |
| `:TodoTelescope` | Search TODOs across project |

---

## Keymaps

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>f` | n | Format buffer |
| `<leader>q` | n | Diagnostic quickfix list |
| `<space>e` | n | Diagnostic float |
| `K` | n | Hover documentation |
| `gd` | n | Goto definition (Telescope) |
| `grd` | n | Goto definition (LSP) |
| `grD` | n | Goto declaration |
| `grr` | n | References |
| `gri` | n | Implementations |
| `grt` | n | Type definitions |
| `gO` | n | Document symbols |
| `gW` | n | Workspace symbols |
| `gra` | n,x | Code action |
| `grn` | n | Rename symbol |
| `<leader>rs` | n | Rename symbol (alt) |
| `<leader>th` | n | Toggle inlay hints |
| `<leader>sh` | n | Search help tags |
| `<leader>sf` | n | Search files |
| `<leader>sF` | n | Search files (incl. ignored) |
| `<leader>sg` | n | Live grep |
| `<leader>sw` | n | Search word under cursor |
| `<leader>sd` | n | Search diagnostics |
| `<leader>sb` | n | Buffers |
| `<leader>s.` | n | Recent files |
| `<leader>sr` | n | Resume last search |
| `<leader>/` | n | Fuzzy search current buffer |
| `<leader>s/` | n | Grep open files |
| `-` | n | Open oil (parent directory) |
| `<leader>cp` | n | Color shades picker |
| `<leader>ch` | n | Color hue picker |
| `<leader>gsj` | n | Go: add JSON struct tags |
| `gc` | n,v | Toggle comment |
| `<C-h/j/k/l>` | n | Window / tmux pane navigation |
| `<Esc>` | n | Clear search highlight |
| `<Esc><Esc>` | t | Exit terminal mode |
| `p` / `P` | n (markdown) | Paste — a bare URL becomes `[](url)` with cursor in the brackets, ready to name (`lua/core/markdown-link-paste.lua`). Terminal pastes in insert mode get the same treatment. Pasting a URL over visually selected text gives `[selection](url)` (markdown.nvim) |

### Debugging (Go, GoLand-style)

| Key | GoLand equivalent | Description |
|-----|-------------------|-------------|
| `F9` / `<leader>dc` | Resume (F9) | Continue / start session (picks config, incl. `.vscode/launch.json`) |
| `F8` / `<leader>dn` | Step over (F8) | Step over |
| `F7` / `<leader>di` | Step into (F7) | Step into |
| `<S-F8>` / `<leader>do` | Step out (⇧F8) | Step out |
| `<C-F8>` / `<leader>db` | Toggle breakpoint (⌘F8) | Toggle breakpoint (persisted across restarts) |
| `<leader>dB` | Conditional breakpoint | Breakpoint with a condition |
| `<leader>dx` | Remove all breakpoints | Clear all breakpoints |
| `<A-F9>` / `<leader>dg` | Run to cursor (⌥F9) | Run to cursor |
| `<leader>dt` | Debug test (⌃⇧D) | Debug nearest Go test |
| `<leader>dT` | Rerun (⌃F5) | Re-run last debugged test |
| `<leader>de` | Evaluate (⌥F8) | Evaluate expression under cursor / selection (n, v) |
| `<leader>du` | Debug tool window | Toggle dap-ui panels |
| `<leader>dr` | Debug console | Toggle REPL |
| `<leader>dq` | Stop (⌘F2) | Terminate session |

Modified F-keys (`<S-F8>`, `<C-F8>`, `<A-F9>`) depend on the terminal forwarding
them; the `<leader>d` maps always work. Full parity test:
[`improvements/go-parity/CHECKLIST.md`](improvements/go-parity/CHECKLIST.md).

---

## LSP Servers

Managed by Mason. Configured in `lua/plugins/lsp/config/`.

| Server | Language |
|--------|----------|
| `ts_ls` | TypeScript / JavaScript |
| `eslint` | JS/TS linting |
| `gopls` | Go |
| `lua_ls` | Lua |
| `clangd` | C / C++ |
| `html` | HTML |
| `htmx` | HTMX |
| `emmet_language_server` | Emmet |
| `templ` | Go templates |
| `bashls` | Bash |
| `prettier` | Formatting (JS/TS/CSS/HTML/JSON/YAML/MD) |
| `delve` | Go debugger (nvim-dap) |

---

## Improvements

Ideas worth evaluating, with the blockers found so far. Fleshed-out plans live in
[`improvements/`](improvements/).

### Go debugging (GoLand parity) — implemented, pending manual test

Navigation already matched GoLand (`gd`, `gri` works interface↔implementation in
both directions, `grr`, `grt`). Debugging is now configured per
[`improvements/go-debugging.md`](improvements/go-debugging.md): nvim-dap + dap-ui +
dap-go (delve), inline variable values, persistent breakpoints, launch.json support,
GoLand F-keys + `<leader>d` group (see Keymaps → Debugging).
Parity test case: [`improvements/go-parity/CHECKLIST.md`](improvements/go-parity/CHECKLIST.md) —
a tiny Go playground + row-per-GoLand-action checklist. Part A (navigation) passes
today (machine-verified against gopls); Part B is the debug plan's acceptance test.

### Image & PDF previews — requires a terminal emulator change

The good nvim preview plugins (e.g. snacks.nvim's `image` module, which renders
both images *and* PDF pages inline) need the **kitty graphics protocol**.
Current setup can't support it:

- **gnome-terminal (VTE 0.76) doesn't speak the kitty graphics protocol** — that's
  the hard blocker. Supported terminals: kitty (`apt install kitty`), ghostty, wezterm.
- The usual VTE workaround (ueberzugpp overlay windows) is effectively **broken on
  GNOME Wayland**, which is what this machine runs.
- Everything else is already in place: tmux has `allow-passthrough on`, and
  ghostscript + poppler-utils (for PDF page rendering) are installed.

So the path, if previews turn out to be worth it: switch to kitty/ghostty, then add
snacks.nvim with the `image` module enabled — no other system changes needed.
Fallback without switching: low-fidelity block-character previews via `chafa` in
telescope (images only, no PDFs).
