-- inline-diff.nvim — word-level diff rendered directly in the buffer, no
-- separate tabpage (roadmap 9f-6). Fills the gap diffview.nvim (full
-- tabpage, <leader>v*) and gitsigns (per-hunk sign column, <leader>h*)
-- both leave open: a live, in-place view of exactly what changed, word by
-- word, while still editing.
--
-- Naming note: the roadmap called this "vscode-diff.nvim", but that name
-- is genuinely ambiguous in the ecosystem -- sharpchen/vscode-diff.nvim and
-- esmuellert/codediff.nvim (a rename of esmuellert/vscode-diff.nvim) both
-- render VSCode-style diffs, but their actual niche is side-by-side
-- rendering via a compiled/FFI diff algorithm -- closer to diffview.nvim's
-- already-covered case than the single-buffer inline niche 9f-6 asked for.
-- cvlmtg/inline-diff.nvim matches that niche exactly (pure Lua, zero
-- dependencies beyond git, live word-level highlighting in place) --
-- picked this one instead.
local config = {
	"cvlmtg/inline-diff.nvim",
	opts = {},
	keys = {
		{ "<leader>vi", "<cmd>InlineDiff<cr>", desc = "Diff: toggle [I]nline (word-level, in-buffer)" },
	},
}

return config
