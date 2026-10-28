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
	-- "+" goes through clipboard.sh (xclip on XWayland with a live XAUTHORITY):
	-- wl-copy blocks nvim on GNOME until a "wl-clipboard is ready" popup is
	-- clicked. The script's header has the details.
	local clip = vim.fn.expand("~/.config/scripts/tmux/clipboard.sh")
	if vim.fn.executable(clip) == 1 then
		vim.g.clipboard = {
			name = "tmux_and_system",
			copy = {
				["*"] = { "tmux", "load-buffer", "-" },
				["+"] = { clip, "copy" },
			},
			paste = {
				["*"] = { "tmux", "save-buffer", "-" },
				["+"] = { clip, "paste" },
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

-- Scroll through a long wrapped line row by row instead of jumping past it.
vim.opt.smoothscroll = true

-- if performing an operation that would fail due to unsaved changes in the buffer (like `:q`),
-- instead raise a dialog asking if you wish to save the current file(s)
-- See `:help 'confirm'`
vim.opt.confirm = true
