-- codediff.nvim — VSCode-style diff rendering, side-by-side or inline, with
-- two-tier (line + character) highlighting (roadmap 9f-6). Owner pick,
-- 2026-07-08 -- overrides an earlier substitution (cvlmtg/inline-diff.nvim)
-- that was chosen for a narrower "just show me word-level changes in this
-- buffer" niche. codediff.nvim is a much bigger tool than that: a full
-- explorer/history/conflict-resolution UI comparable in scope to
-- diffview.nvim, not just an inline overlay -- see
-- docs/9f-ergonomics-recap.md's comparison guide for how the two actually
-- differ day to day.
--
-- Downloads a prebuilt C library (FFI, OpenMP) on first `:CodeDiff` use --
-- no build step, but does need network access that one time.
local config = {
	"esmuellert/codediff.nvim",
	cmd = "CodeDiff",
	opts = {},
	keys = {
		{ "<leader>vi", "<cmd>CodeDiff --inline<cr>", desc = "Diff: [C]odeDiff explorer, inline layout" },
		{ "<leader>vI", "<cmd>CodeDiff file HEAD --inline<cr>", desc = "Diff: [C]odeDiff current file vs HEAD, inline" },
	},
}

return config
