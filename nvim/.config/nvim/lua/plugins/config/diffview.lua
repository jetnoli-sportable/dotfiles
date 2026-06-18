-- diffview.nvim — a single tabpage view for git diffs and file history.
-- Complements gitsigns (per-hunk staging) with a full side-by-side diff and a
-- history browser, which pairs well with reviewing changes an agent has made.

local config = {
	"sindrets/diffview.nvim",
	dependencies = { "nvim-lua/plenary.nvim" },
	cmd = {
		"DiffviewOpen",
		"DiffviewClose",
		"DiffviewToggleFiles",
		"DiffviewFocusFiles",
		"DiffviewFileHistory",
		"DiffviewRefresh",
	},
	keys = {
		{ "<leader>vo", "<cmd>DiffviewOpen<cr>", desc = "Diff: [O]pen (working tree vs HEAD)" },
		{ "<leader>vc", "<cmd>DiffviewClose<cr>", desc = "Diff: [C]lose" },
		{ "<leader>vh", "<cmd>DiffviewFileHistory<cr>", desc = "Diff: repo file [H]istory" },
		{ "<leader>vf", "<cmd>DiffviewFileHistory %<cr>", desc = "Diff: current [F]ile history" },
	},
	opts = {
		enhanced_diff_hl = true,
	},
}

return config
