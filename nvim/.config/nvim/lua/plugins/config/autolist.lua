return {
	"gaoDean/autolist.nvim",
	-- lazy-load when opening or creating text-like files
	-- event = { "BufReadPre", "BufNewFile" },
	ft = { "markdown", "text", "tex", "plaintex", "norg" },
	config = function()
		-- use all the defaults, plus sensible keymaps:
		require("autolist").setup()

		-- Bind per-buffer keymaps on every list-type buffer (not just the first
		-- one open at plugin-load time — `buffer = true` only scopes correctly
		-- inside a FileType callback).
		vim.api.nvim_create_autocmd("FileType", {
			pattern = { "markdown", "text", "tex", "plaintex", "norg" },
			callback = function(event)
				local map = function(mode, lhs, rhs)
					vim.keymap.set(mode, lhs, rhs, { buffer = event.buf })
				end
				-- Tab to indent, Shift-Tab to dedent
				map("i", "<Tab>", "<cmd>AutolistTab<CR>")
				map("i", "<S-Tab>", "<cmd>AutolistShiftTab<CR>")
				-- <CR> in insert: continue list, or remove empty bullet
				map("i", "<CR>", "<CR><cmd>AutolistNewBullet<CR>")
				-- Normal mode: o/O continue lists, <CR> toggles checkbox then newline
				map("n", "o", "o<cmd>AutolistNewBullet<CR>")
				map("n", "O", "O<cmd>AutolistNewBulletBefore<CR>")
				map("n", "<CR>", "<cmd>AutolistToggleCheckbox<CR><CR>")
			end,
		})
	end,
}
