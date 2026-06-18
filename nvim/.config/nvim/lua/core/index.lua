vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("core.remaps")
require("core.autocommands")
require("core.markdown-link-paste")
require("claude-tmux").setup({})

vim.lsp.set_log_level("warn")

vim.opt.encoding = "utf-8"
vim.opt.clipboard = "unnamedplus"

if vim.env.TMUX then
	-- Pick the first system-clipboard tool that actually exists on this machine.
	-- Order: wl-clipboard (only on Wayland), then xclip, then xsel. Prefer Wayland
	-- native when in a Wayland session, but fall back to X11 tools via XWayland.
	local copy_cmd, paste_cmd
	if vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-copy") == 1 then
		copy_cmd = { "wl-copy" }
		paste_cmd = { "wl-paste", "--no-newline" }
	elseif vim.fn.executable("xclip") == 1 then
		copy_cmd = { "xclip", "-selection", "clipboard" }
		paste_cmd = { "xclip", "-selection", "clipboard", "-o" }
	elseif vim.fn.executable("xsel") == 1 then
		copy_cmd = { "xsel", "--clipboard", "--input" }
		paste_cmd = { "xsel", "--clipboard", "--output" }
	end

	if copy_cmd then
		vim.g.clipboard = {
			name = "tmux_and_system",
			copy = {
				["*"] = { "tmux", "load-buffer", "-" },
				["+"] = copy_cmd,
			},
			paste = {
				["*"] = { "tmux", "save-buffer", "-" },
				["+"] = paste_cmd,
			},
			cache_enabled = false,
		}
	end
end

vim.g.have_nerd_font = true

vim.opt.foldmethod = "expr"
vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"

vim.opt.fillchars = { fold = " ", foldopen = "▼", foldclose = "▶" }

vim.opt.foldenable = false
vim.opt.foldcolumn = "2"
vim.opt.foldlevelstart = 99
vim.opt.foldtext = ""

vim.api.nvim_create_autocmd("ColorScheme", {
	pattern = "*",
	callback = function()
		vim.api.nvim_set_hl(0, "Folded", { link = "Normal" })
	end,
})

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true

-- Make line numbers default
vim.opt.number = true
-- You can also add relative line numbers, to help with jumping.
--  Experiment for yourself to see if you like it!
vim.opt.relativenumber = true

-- Enable mouse mode, can be useful for resizing splits for example!
vim.opt.mouse = "a"

-- Don't show the mode, since it's already in the status line
vim.opt.showmode = false

-- Enable break indent
vim.opt.breakindent = true

-- Save undo history
vim.opt.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Keep signcolumn on by default
vim.opt.signcolumn = "yes"

-- Decrease update time
vim.opt.updatetime = 250

-- Decrease mapped sequence wait time
vim.opt.timeoutlen = 300

-- Configure how new splits should be opened
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
vim.opt.list = false
-- vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.opt.inccommand = "split"

-- Show which line your cursor is on
vim.opt.cursorline = true

-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 10

-- if performing an operation that would fail due to unsaved changes in the buffer (like `:q`),
-- instead raise a dialog asking if you wish to save the current file(s)
-- See `:help 'confirm'`
vim.opt.confirm = true
